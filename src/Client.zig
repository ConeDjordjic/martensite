//! The other half: writes requests, reads responses.
//!
//! Same rules as Server. You hand it a reader and a writer. It doesn't
//! open sockets, resolve names or follow redirects.

const std = @import("std");
const Io = std.Io;

const scan = @import("scan.zig");
const body = @import("body.zig");
const chunked = @import("chunked.zig");

const Client = @This();

io: Io,
reader: *Io.Reader,
writer: *Io.Writer,
headers: []scan.Header,
head_buf: []u8,

head_len: usize = 0,
pending: body.Framing = .none,
/// The method we sent, which changes the framing rules.
sent_method: []const u8 = "",
generation: u32 = 0,

pub const Options = struct {
    /// Storage for the response's headers.
    headers: []scan.Header,
    /// Where the head is kept while a body is being read.
    head_buf: []u8 = &.{},
};

pub fn init(io: Io, reader: *Io.Reader, writer: *Io.Writer, options: Options) Client {
    return .{
        .io = io,
        .reader = reader,
        .writer = writer,
        .headers = options.headers,
        .head_buf = options.head_buf,
    };
}

pub const Header = scan.Header;

pub const Request = struct {
    method: []const u8 = "GET",
    target: []const u8 = "/",
    headers: []const Header = &.{},
    body: []const u8 = "",
    /// Send a Content-Length, unless `headers` already has framing in it.
    send_length: bool = true,
};

pub const SendError = Io.Writer.Error || error{
    /// A bad header name, or CR, LF or NUL in a value.
    InvalidHeader,
    /// The method or target doesn't fit in a request line.
    InvalidRequest,
};

/// Writes a request and flushes it.
pub fn send(c: *Client, r: Request) SendError!void {
    if (r.method.len == 0 or !isToken(r.method)) return error.InvalidRequest;
    if (r.target.len == 0 or hasControl(r.target) or
        std.mem.indexOfScalar(u8, r.target, ' ') != null) return error.InvalidRequest;

    const w = c.writer;
    try w.writeAll(r.method);
    try w.writeByte(' ');
    try w.writeAll(r.target);
    try w.writeAll(" HTTP/1.1\r\n");

    var framed = false;
    for (r.headers) |h| {
        if (!isToken(h.name) or h.name.len == 0 or hasControl(h.value)) return error.InvalidHeader;
        if (std.ascii.eqlIgnoreCase(h.name, "content-length") or
            std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) framed = true;
        try w.writeAll(h.name);
        try w.writeAll(": ");
        try w.writeAll(h.value);
        try w.writeAll("\r\n");
    }
    if (!framed and r.send_length and r.body.len != 0) {
        try w.print("Content-Length: {d}\r\n", .{r.body.len});
    }
    try w.writeAll("\r\n");
    try w.writeAll(r.body);
    try w.flush();

    c.sent_method = r.method;
}

pub const ReceiveError = error{
    /// Not a response.
    BadResponse,
    /// The head didn't fit, or it had too many headers.
    HeadTooLarge,
    Ambiguous,
    UnsupportedEncoding,
    ReadFailed,
} || Io.Cancelable;

/// Points into the connection's buffers and is valid until the next `receive`.
pub const Response = struct {
    head: scan.ResponseHead,
    framing: body.Framing,
    owner: *const Client,
    generation: u32,

    pub fn status(r: Response) u16 {
        r.check();
        return r.head.status;
    }

    pub fn reason(r: Response) []const u8 {
        r.check();
        return r.head.reason;
    }

    pub fn header(r: Response, name: []const u8) ?[]const u8 {
        r.check();
        for (r.head.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn headers(r: Response) []const scan.Header {
        r.check();
        return r.head.headers;
    }

    pub fn live(r: Response) bool {
        return r.generation == r.owner.generation;
    }

    fn check(r: Response) void {
        if (std.debug.runtime_safety and !r.live()) {
            @panic("response outlived the receive that produced it");
        }
    }
};

/// Reads the next response head, or null if the peer closed cleanly.
pub fn receive(c: *Client) ReceiveError!?Response {
    try c.finishPrevious();

    c.reader.toss(c.head_len);
    c.head_len = 0;

    var last_len: usize = 0;
    var filled = false;
    while (true) {
        const buffered = c.reader.buffered();
        if (buffered.len != 0) {
            if (scan.response(buffered, c.headers, last_len)) |maybe| {
                if (maybe) |scanned| {
                    const framing = try body.response(scanned.head, c.sent_method);
                    c.head_len = scanned.len;
                    c.pending = framing;
                    const head = switch (framing) {
                        .none => scanned.head,
                        else => try c.keepHead(buffered[0..scanned.len], scanned.head),
                    };
                    c.generation +%= 1;
                    return .{
                        .head = head,
                        .framing = framing,
                        .owner = c,
                        .generation = c.generation,
                    };
                }
            } else |err| return switch (err) {
                error.Invalid => error.BadResponse,
                error.TooManyHeaders => error.HeadTooLarge,
            };
            last_len = buffered.len;
            // Incomplete, with nowhere to put the rest of it. Only once a
            // fill has been tried, because a reader whose buffer is exactly
            // its data looks full from the start and has simply ended.
            //
            // This is after the scan, not after the fill: a client that
            // sends its head and a large body in one go fills the buffer
            // with a head that is perfectly fine.
            if (filled and buffered.len == c.reader.buffer.len) return error.HeadTooLarge;
        }

        c.reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => {
                if (c.reader.bufferedLen() == 0) return null;
                return error.BadResponse;
            },
            error.ReadFailed => return error.ReadFailed,
        };
        filled = true;
    }
}

pub const BodyError = error{
    /// The peer stopped before the body was complete.
    Incomplete,
    BadChunk,
    ReadFailed,
} || Io.Cancelable;

/// Reads the whole body into `buf`.
pub fn readBody(c: *Client, buf: []u8) (BodyError || error{BodyTooLarge})![]u8 {
    if (c.pending == .none) return buf[0..0];

    c.reader.toss(c.head_len);
    c.head_len = 0;

    switch (c.pending) {
        .none => unreachable,
        .length => |n| {
            if (n > buf.len) return error.BodyTooLarge;
            const want: usize = @intCast(n);
            c.reader.readSliceAll(buf[0..want]) catch |err| switch (err) {
                error.EndOfStream => return error.Incomplete,
                error.ReadFailed => return error.ReadFailed,
            };
            c.pending = .none;
            return buf[0..want];
        },
        .until_close => {
            var w: Io.Writer = .fixed(buf);
            _ = c.reader.streamRemaining(&w) catch |err| switch (err) {
                error.WriteFailed => return error.BodyTooLarge,
                error.ReadFailed => return error.ReadFailed,
            };
            c.pending = .none;
            return w.buffered();
        },
        .chunked => {
            var d: chunked.Decoder = .{ .consume_trailer = true };
            var out: usize = 0;
            while (true) {
                const buffered = c.reader.buffered();
                if (buffered.len != 0) {
                    const take = @min(buffered.len, buf.len - out);
                    if (take == 0) return error.BodyTooLarge;
                    @memcpy(buf[out..][0..take], buffered[0..take]);
                    const r = d.decode(buf[out..][0..take]) catch return error.BadChunk;
                    c.reader.toss(take - r.leftover);
                    out += r.decoded;
                    if (r.done) {
                        c.pending = .none;
                        return buf[0..out];
                    }
                    if (r.leftover != 0) continue;
                }
                c.reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return error.Incomplete,
                    error.ReadFailed => return error.ReadFailed,
                };
            }
        },
    }
}

fn keepHead(c: *Client, bytes: []const u8, head: scan.ResponseHead) error{HeadTooLarge}!scan.ResponseHead {
    if (bytes.len > c.head_buf.len) return error.HeadTooLarge;
    const dst = c.head_buf[0..bytes.len];
    @memcpy(dst, bytes);

    const base = bytes.ptr;
    const move = struct {
        fn f(from: []const u8, old: [*]const u8, new: []u8) []const u8 {
            const offset = @intFromPtr(from.ptr) - @intFromPtr(old);
            return new[offset..][0..from.len];
        }
    }.f;

    var out = head;
    out.reason = move(head.reason, base, dst);
    for (c.headers[0..head.headers.len]) |*h| {
        h.name = move(h.name, base, dst);
        h.value = move(h.value, base, dst);
    }
    out.headers = c.headers[0..head.headers.len];
    return out;
}

fn finishPrevious(c: *Client) ReceiveError!void {
    switch (c.pending) {
        .none => {},
        else => {
            var sink: [4096]u8 = undefined;
            while (true) {
                _ = c.readBody(&sink) catch |err| switch (err) {
                    error.BodyTooLarge => continue,
                    else => {
                        c.pending = .none;
                        return;
                    },
                };
                return;
            }
        },
    }
}

fn isToken(bytes: []const u8) bool {
    for (bytes) |ch| if (!token_chars[ch]) return false;
    return true;
}

fn hasControl(bytes: []const u8) bool {
    for (bytes) |ch| {
        if (ch < 0x20 or ch == 0x7f) return true;
    }
    return false;
}

const token_chars = blk: {
    var t = [_]bool{false} ** 256;
    for ("!#$%&'*+-.^_`|~") |ch| t[ch] = true;
    for ('0'..'9' + 1) |ch| t[ch] = true;
    for ('a'..'z' + 1) |ch| t[ch] = true;
    for ('A'..'Z' + 1) |ch| t[ch] = true;
    break :blk t;
};

const testing = std.testing;

const Harness = struct {
    reader: Io.Reader,
    writer: Io.Writer,
    headers: [16]scan.Header,
    head_buf: [2048]u8,
    out: [4096]u8,

    fn init(h: *Harness, input: []const u8) Client {
        h.reader = .fixed(input);
        h.writer = .fixed(&h.out);
        return .init(testing.io, &h.reader, &h.writer, .{
            .headers = &h.headers,
            .head_buf = &h.head_buf,
        });
    }

    fn sent(h: *Harness) []const u8 {
        return h.writer.buffered();
    }
};

test "a request goes out looking like one" {
    var h: Harness = undefined;
    var c = h.init("");
    try c.send(.{ .target = "/things", .headers = &.{.{ .name = "Host", .value = "example.com" }} });
    try testing.expectEqualStrings(
        "GET /things HTTP/1.1\r\nHost: example.com\r\n\r\n",
        h.sent(),
    );
}

test "a body gets a length" {
    var h: Harness = undefined;
    var c = h.init("");
    try c.send(.{ .method = "POST", .target = "/x", .body = "hello" });
    try testing.expectEqualStrings("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello", h.sent());
}

test "a caller's own framing is left alone" {
    var h: Harness = undefined;
    var c = h.init("");
    try c.send(.{
        .method = "POST",
        .headers = &.{.{ .name = "Transfer-Encoding", .value = "chunked" }},
        .body = "5\r\nhello\r\n0\r\n\r\n",
    });
    try testing.expect(std.mem.indexOf(u8, h.sent(), "Content-Length") == null);
}

test "a request line that cannot be written" {
    var h: Harness = undefined;
    var c = h.init("");
    try testing.expectError(error.InvalidRequest, c.send(.{ .method = "GE T" }));
    try testing.expectError(error.InvalidRequest, c.send(.{ .target = "/a b" }));
    try testing.expectError(error.InvalidRequest, c.send(.{ .target = "/a\r\nX: 1" }));
    try testing.expectError(error.InvalidHeader, c.send(.{
        .headers = &.{.{ .name = "X", .value = "a\r\nY: 2" }},
    }));
}

test "a response with a length" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
    try c.send(.{});

    const res = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 200), res.status());
    try testing.expectEqualStrings("OK", res.reason());

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hello", try c.readBody(&buf));
    try testing.expectEqualStrings("5", res.header("content-length").?);
}

test "a chunked response" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n");
    try c.send(.{});
    _ = (try c.receive()).?;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abcdefg", try c.readBody(&buf));
}

test "a response that runs until the connection closes" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.0 200 OK\r\n\r\neverything after the head");
    try c.send(.{});
    const res = (try c.receive()).?;
    try testing.expectEqual(body.Framing.until_close, res.framing);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("everything after the head", try c.readBody(&buf));
}

test "204 has no body even when it claims one" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi");
    try c.send(.{});
    const first = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 204), first.status());
    try testing.expectEqual(body.Framing.none, first.framing);

    // The bytes after it are the next response, not this one's body.
    const second = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 200), second.status());
}

test "a HEAD response is not read as having a body" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi");
    try c.send(.{ .method = "HEAD" });
    const first = (try c.receive()).?;
    try testing.expectEqual(body.Framing.none, first.framing);
    const second = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 200), second.status());
}

test "two responses on one connection" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\naHTTP/1.1 404 Not Found\r\nContent-Length: 1\r\n\r\nb");
    try c.send(.{});

    const first = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 200), first.status());
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("a", try c.readBody(&buf));

    const second = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 404), second.status());
    try testing.expectEqualStrings("b", try c.readBody(&buf));
}

test "an unread body is dropped before the next response" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloHTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
    try c.send(.{});
    _ = (try c.receive()).?;
    const second = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 404), second.status());
}

test "a stale response is caught" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n");
    try c.send(.{});
    const first = (try c.receive()).?;
    try testing.expect(first.live());
    _ = (try c.receive()).?;
    try testing.expect(!first.live());
}

test "garbage is not a response" {
    var h: Harness = undefined;
    var c = h.init("this is not http\r\n\r\n");
    try c.send(.{});
    try testing.expectError(error.BadResponse, c.receive());
}

test "a clean close before any response" {
    var h: Harness = undefined;
    var c = h.init("");
    try c.send(.{});
    try testing.expectEqual(@as(?Response, null), try c.receive());
}

test "a smuggling response is refused" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello");
    try c.send(.{});
    try testing.expectError(error.Ambiguous, c.receive());
}
