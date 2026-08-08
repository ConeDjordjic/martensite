//! One connection, read as a series of requests.
//!
//! This is the only file here that needs an Io. Everything under it
//! works on byte slices, so you can skip it and drive the bytes
//! yourself.

const std = @import("std");
const Io = std.Io;

const scan = @import("scan.zig");
const body = @import("body.zig");
const chunked = @import("chunked.zig");
const Response = @import("Response.zig");

const Server = @This();

io: Io,
reader: *Io.Reader,
writer: *Io.Writer,
headers: []scan.Header,

/// Bytes of the current head still sitting at the front of the reader.
head_len: usize = 0,
/// Framing of the body nobody has read yet.
pending: body.Framing = .none,
keep_alive: bool = true,
/// Set once a response has gone out for the current request.
answered: bool = true,

pub const Options = struct {
    /// Storage for the request's headers. Anything over this is
    /// HeadTooLarge.
    headers: []scan.Header,
};

pub fn init(io: Io, reader: *Io.Reader, writer: *Io.Writer, options: Options) Server {
    return .{
        .io = io,
        .reader = reader,
        .writer = writer,
        .headers = options.headers,
    };
}

pub const Request = struct {
    head: scan.Head,
    framing: body.Framing,

    pub fn method(r: Request) []const u8 {
        return r.head.method;
    }

    pub fn target(r: Request) []const u8 {
        return r.head.target;
    }

    pub fn header(r: Request, name: []const u8) ?[]const u8 {
        for (r.head.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

pub const ReceiveError = error{
    /// Not a request.
    BadRequest,
    /// The head didn't fit, or it had too many headers.
    HeadTooLarge,
    /// The framing rules were broken. See body.Error.
    Ambiguous,
    UnsupportedEncoding,
    ReadFailed,
} || Io.Cancelable;

/// Reads the next request head, or null if the peer closed cleanly. An
/// unread body left over from the last request gets dropped first.
pub fn receive(s: *Server) ReceiveError!?Request {
    if (!s.keep_alive) return null;
    try s.finishPrevious();

    s.reader.toss(s.head_len);
    s.head_len = 0;

    var last_len: usize = 0;
    while (true) {
        const buffered = s.reader.buffered();
        if (buffered.len != 0) {
            if (scan.request(buffered, s.headers, last_len)) |maybe| {
                if (maybe) |scanned| {
                    const framing = try body.request(scanned.head);
                    s.head_len = scanned.len;
                    s.pending = framing;
                    s.keep_alive = body.keepAlive(scanned.head);
                    s.answered = false;
                    return .{ .head = scanned.head, .framing = framing };
                }
            } else |err| return switch (err) {
                error.Invalid => error.BadRequest,
                error.TooManyHeaders => error.HeadTooLarge,
            };
            last_len = buffered.len;
        }

        s.reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => {
                // Clean close between requests is not an error.
                if (s.reader.bufferedLen() == 0) return null;
                return error.BadRequest;
            },
            error.ReadFailed => return error.ReadFailed,
        };

        if (s.reader.bufferedLen() == s.reader.buffer.len) return error.HeadTooLarge;
    }
}

pub const BodyError = error{
    /// The peer stopped sending halfway through the body.
    Incomplete,
    /// The chunked encoding is malformed.
    BadChunk,
    ReadFailed,
} || Io.Cancelable;

/// Reads the whole body into `buf`. Returns the part of `buf` it filled.
/// Bodies larger than `buf` are an error rather than a truncation.
pub fn readBody(s: *Server, buf: []u8) (BodyError || error{BodyTooLarge})![]u8 {
    s.reader.toss(s.head_len);
    s.head_len = 0;

    switch (s.pending) {
        .none => {
            s.pending = .none;
            return buf[0..0];
        },
        .length => |n| {
            if (n > buf.len) return error.BodyTooLarge;
            const want: usize = @intCast(n);
            s.reader.readSliceAll(buf[0..want]) catch |err| switch (err) {
                error.EndOfStream => return error.Incomplete,
                error.ReadFailed => return error.ReadFailed,
            };
            s.pending = .none;
            return buf[0..want];
        },
        .chunked => {
            var d: chunked.Decoder = .{ .consume_trailer = true };
            var out: usize = 0;
            while (true) {
                const buffered = s.reader.buffered();
                if (buffered.len != 0) {
                    const take = @min(buffered.len, buf.len - out);
                    if (take == 0) return error.BodyTooLarge;
                    @memcpy(buf[out..][0..take], buffered[0..take]);
                    const r = d.decode(buf[out..][0..take]) catch return error.BadChunk;
                    s.reader.toss(take - r.leftover);
                    out += r.decoded;
                    if (r.done) {
                        s.pending = .none;
                        return buf[0..out];
                    }
                    if (r.leftover != 0) continue;
                }
                s.reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return error.Incomplete,
                    error.ReadFailed => return error.ReadFailed,
                };
            }
        },
    }
}

pub const SendError = Io.Writer.Error;

/// Writes a response and flushes it.
pub fn respond(s: *Server, r: Response) SendError!void {
    try r.write(s.writer, .{ .keep_alive = s.keep_alive });
    try s.writer.flush();
    s.answered = true;
    if (!r.keep_alive) s.keep_alive = false;
}

/// Can the connection carry another request? False while a streamed
/// response is still open.
pub fn alive(s: *const Server) bool {
    return s.keep_alive;
}

/// Drops whatever the previous request left behind so the next head starts at
/// a message boundary.
fn finishPrevious(s: *Server) ReceiveError!void {
    switch (s.pending) {
        .none => {},
        else => {
            var sink: [4096]u8 = undefined;
            _ = s.readBody(&sink) catch {
                s.keep_alive = false;
                return;
            };
        },
    }
}

const testing = std.testing;

const Harness = struct {
    reader: Io.Reader,
    writer: Io.Writer,
    headers: [16]scan.Header,
    out: [4096]u8,

    fn init(h: *Harness, input: []const u8) Server {
        h.reader = .fixed(input);
        h.writer = .fixed(&h.out);
        return .init(testing.io, &h.reader, &h.writer, .{ .headers = &h.headers });
    }

    fn written(h: *Harness) []const u8 {
        return h.writer.buffered();
    }
};

test "one request and one response" {
    var h: Harness = undefined;
    var s = h.init("GET /hi HTTP/1.1\r\nHost: x\r\n\r\n");

    const req = (try s.receive()).?;
    try testing.expectEqualStrings("GET", req.method());
    try testing.expectEqualStrings("/hi", req.target());
    try testing.expectEqualStrings("x", req.header("host").?);
    try testing.expectEqual(body.Framing.none, req.framing);

    try s.respond(Response.text(.ok, "yes"));
    try testing.expect(std.mem.endsWith(u8, h.written(), "\r\n\r\nyes"));
    try testing.expect(s.alive());
}

test "two requests on one connection" {
    var h: Harness = undefined;
    var s = h.init("GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n");

    const first = (try s.receive()).?;
    try testing.expectEqualStrings("/a", first.target());
    try s.respond(.{});

    const second = (try s.receive()).?;
    try testing.expectEqualStrings("/b", second.target());
    try s.respond(.{});

    try testing.expectEqual(@as(?Request, null), try s.receive());
}

test "a body with a length" {
    var h: Harness = undefined;
    var s = h.init("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello");

    const req = (try s.receive()).?;
    try testing.expectEqual(@as(u64, 5), req.framing.length);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hello", try s.readBody(&buf));
}

test "a chunked body" {
    var h: Harness = undefined;
    var s = h.init("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n");

    _ = (try s.receive()).?;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abcdefg", try s.readBody(&buf));
}

test "an unread body is dropped before the next request" {
    var h: Harness = undefined;
    var s = h.init("POST /a HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloGET /b HTTP/1.1\r\n\r\n");

    _ = (try s.receive()).?;
    try s.respond(.{});

    const second = (try s.receive()).?;
    try testing.expectEqualStrings("/b", second.target());
}

test "connection close ends the loop" {
    var h: Harness = undefined;
    var s = h.init("GET / HTTP/1.1\r\nConnection: close\r\n\r\nGET /again HTTP/1.1\r\n\r\n");

    _ = (try s.receive()).?;
    try testing.expect(!s.alive());
    try s.respond(.{});
    try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") != null);
    try testing.expectEqual(@as(?Request, null), try s.receive());
}

test "a clean close between requests is not an error" {
    var h: Harness = undefined;
    var s = h.init("");
    try testing.expectEqual(@as(?Request, null), try s.receive());
}

test "garbage is a bad request" {
    var h: Harness = undefined;
    var s = h.init("not a request at all\r\n\r\n");
    try testing.expectError(error.BadRequest, s.receive());
}

test "ambiguous framing is refused before the handler sees it" {
    var h: Harness = undefined;
    var s = h.init("POST / HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello");
    try testing.expectError(error.Ambiguous, s.receive());
}

test "a head that does not fit" {
    var h: Harness = undefined;
    var s = h.init("GET / HTTP/1.1\r\n" ++ ("X: y\r\n" ** 20) ++ "\r\n");
    try testing.expectError(error.HeadTooLarge, s.receive());
}

test "a body bigger than the caller's buffer" {
    var h: Harness = undefined;
    var s = h.init("POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\n" ++ ("x" ** 100));
    _ = (try s.receive()).?;
    var buf: [10]u8 = undefined;
    try testing.expectError(error.BodyTooLarge, s.readBody(&buf));
}

test "a truncated body" {
    var h: Harness = undefined;
    var s = h.init("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort");
    _ = (try s.receive()).?;
    var buf: [64]u8 = undefined;
    try testing.expectError(error.Incomplete, s.readBody(&buf));
}
