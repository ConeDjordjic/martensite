//! The other half: writes requests, reads responses.
//!
//! Same rules as Server. You hand it a reader and a writer. It doesn't
//! open sockets, resolve names or follow redirects.

const std = @import("std");
const Io = std.Io;

const scan = @import("scan.zig");
const body = @import("body.zig");
const chunked = @import("chunked.zig");
const HeadWindow = @import("HeadWindow.zig");

const Client = @This();

io: Io,
reader: *Io.Reader,
writer: *Io.Writer,
/// Owns where the reader is: head, body, drain.
window: HeadWindow,
/// The method we sent, which changes the framing rules.
sent_method: []const u8 = "",

pub const Options = struct {
    /// Storage for the response's headers.
    headers: []scan.Header,
    /// Where the head is kept while a body is being read.
    head_buf: []u8 = &.{},
    /// How much of an unread body we will read to keep the connection.
    /// Zero, which is the default, closes it instead.
    max_drain: u64 = 0,
};

pub const InitError = error{
    /// `head_buf` is smaller than the reader's buffer, so a head the
    /// reader can hold has nowhere to be kept while its body is read.
    HeadBufferTooSmall,
};

pub fn init(io: Io, reader: *Io.Reader, writer: *Io.Writer, options: Options) InitError!Client {
    // An empty head_buf is a choice: responses with no body never need one.
    if (options.head_buf.len != 0 and options.head_buf.len < reader.buffer.len)
        return error.HeadBufferTooSmall;
    return .{
        .io = io,
        .reader = reader,
        .writer = writer,
        .window = .init(reader, .{
            .headers = options.headers,
            .head_buf = options.head_buf,
            .max_drain = options.max_drain,
        }),
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

    /// How many bytes the body has, when `Content-Length` said so.
    ///
    /// Null means the length is not knowable in advance: a chunked body,
    /// one that runs until the connection closes, or no body at all.
    pub fn contentLength(r: Response) ?u64 {
        r.check();
        return switch (r.framing) {
            .length => |n| n,
            else => null,
        };
    }

    /// Whether there is a body to read at all.
    pub fn hasBody(r: Response) bool {
        r.check();
        return r.framing != .none;
    }

    pub fn live(r: Response) bool {
        return r.generation == r.owner.window.generation;
    }

    fn check(r: Response) void {
        if (std.debug.runtime_safety and !r.live()) {
            @panic("response outlived the receive that produced it");
        }
    }
};

/// Reads the next response head, or null if the peer closed cleanly.
pub fn receive(c: *Client) ReceiveError!?Response {
    const taken = (c.window.takeResponse(c.sent_method) catch |err| return switch (err) {
        error.Invalid => error.BadResponse,
        else => |e| e,
    }) orelse return null;

    return .{
        .head = taken.head,
        .framing = taken.framing,
        .owner = c,
        .generation = c.window.generation,
    };
}

pub const BodyError = HeadWindow.BodyError;

/// Reads the whole body into `buf`. If it doesn't fit you get an error,
/// not a short read.
pub fn readBody(c: *Client, buf: []u8) (BodyError || error{BodyTooLarge})![]u8 {
    const got = try c.window.readBody(buf);
    return got.bytes;
}

/// The response body as an `Io.Reader`, for bodies too big to hold in
/// memory.
pub const BodyReader = HeadWindow.BodyReader;

/// A reader over the response body, valid until the next `receive`.
///
/// `decode_buf` is the reader's own memory. It is what the reader
/// buffers into, and where a chunked body decodes on the way out. A few
/// hundred bytes is plenty, and two is the minimum.
pub fn bodyReader(c: *Client, decode_buf: []u8) BodyReader {
    return c.window.bodyReader(decode_buf);
}

/// Whether the connection may carry another exchange.
pub fn alive(c: *const Client) bool {
    return c.window.usable();
}

fn isToken(bytes: []const u8) bool {
    for (bytes) |ch| if (!scan.isTokenChar(ch)) return false;
    return true;
}

fn hasControl(bytes: []const u8) bool {
    for (bytes) |ch| {
        if (ch < 0x20 or ch == 0x7f) return true;
    }
    return false;
}


const testing = std.testing;

const Harness = struct {
    reader: Io.Reader,
    writer: Io.Writer,
    headers: [16]scan.Header,
    head_buf: [16 * 1024]u8,
    out: [4096]u8,

    fn init(h: *Harness, input: []const u8) Client {
        h.reader = .fixed(input);
        h.writer = .fixed(&h.out);
        return Client.init(testing.io, &h.reader, &h.writer, .{
            .headers = &h.headers,
            .head_buf = &h.head_buf,
        }) catch unreachable;
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
    // Reading a body the caller skipped is opt-in now.
    c.window.max_drain = 64 * 1024;
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

test "a response says how long its body is" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
    try c.send(.{});
    const res = (try c.receive()).?;
    try testing.expectEqual(@as(?u64, 5), res.contentLength());
    try testing.expect(res.hasBody());
}

test "a chunked response has no length to report" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");
    try c.send(.{});
    const res = (try c.receive()).?;
    try testing.expectEqual(@as(?u64, null), res.contentLength());
    try testing.expect(res.hasBody());
}
