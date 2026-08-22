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
head_buf: []u8,

/// Bytes of the current head still sitting at the front of the reader.
head_len: usize = 0,
/// Framing of the body nobody has read yet.
pending: body.Framing = .none,
keep_alive: bool = true,
/// Set once a response has gone out for the current request.
answered: bool = true,
/// The peer said Expect: 100-continue and is waiting to be told to go
/// ahead. Cleared once it has been.
expect_continue: bool = false,
/// Bumped by every receive. A Request carries the value it was made with,
/// so using a stale one is caught instead of reading whatever is there now.
generation: u32 = 0,

pub const Options = struct {
    /// Storage for the request's headers. Anything over this is
    /// HeadTooLarge.
    headers: []scan.Header,
    /// Holds the head while a body is read, because reading moves the
    /// reader past it and a later fill writes over it. Requests with no
    /// body never touch this, so it can be empty.
    head_buf: []u8 = &.{},
};

pub fn init(io: Io, reader: *Io.Reader, writer: *Io.Writer, options: Options) Server {
    return .{
        .io = io,
        .reader = reader,
        .writer = writer,
        .headers = options.headers,
        .head_buf = options.head_buf,
    };
}

/// Everything here borrows the connection's buffers and is good until the
/// next `receive`. Reading past that is checked in Debug and ReleaseSafe and
/// unchecked in ReleaseFast, the same deal as an index out of range.
pub const Request = struct {
    head: scan.Head,
    framing: body.Framing,
    owner: *const Server,
    generation: u32,

    /// The peer is holding the body back until it hears 100 Continue.
    /// Reading the body sends it. Answering without reading does not, which
    /// is how you turn a big upload away before it is sent.
    pub fn expectsContinue(r: Request) bool {
        r.check();
        return r.owner.expect_continue;
    }

    pub fn method(r: Request) []const u8 {
        r.check();
        return r.head.method;
    }

    pub fn target(r: Request) []const u8 {
        r.check();
        return r.head.target;
    }

    pub fn headers(r: Request) []const scan.Header {
        r.check();
        return r.head.headers;
    }

    pub fn header(r: Request, name: []const u8) ?[]const u8 {
        r.check();
        for (r.head.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Whether this request is still the one the connection is on.
    pub fn live(r: Request) bool {
        return r.generation == r.owner.generation;
    }

    fn check(r: Request) void {
        if (std.debug.runtime_safety and !r.live()) {
            @panic("request outlived the receive that produced it");
        }
    }
};

pub const ReceiveError = error{
    /// Not a request.
    BadRequest,
    /// An Expect header asking for something that is not 100-continue.
    /// RFC 9110 says answer 417.
    UnsupportedExpectation,
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
                    s.expect_continue = try expectsContinue(scanned.head);
                    s.head_len = scanned.len;
                    s.pending = framing;
                    s.keep_alive = body.keepAlive(scanned.head);
                    s.answered = false;
                    const head = switch (framing) {
                        .none => scanned.head,
                        else => try s.keepHead(buffered[0..scanned.len], scanned.head),
                    };
                    s.generation +%= 1;
                    return .{
                        .head = head,
                        .framing = framing,
                        .owner = s,
                        .generation = s.generation,
                    };
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

/// The request body as an `Io.Reader`, so a body larger than memory can be
/// streamed somewhere instead of landing in a buffer.
///
/// Decoding happens in the connection's read buffer, so this needs no buffer
/// of its own and copies nothing that `readBody` would not have copied.
pub const BodyReader = struct {
    server: *Server,
    interface: Io.Reader,
    /// Where chunked bytes get decoded. Ours, because the destination may
    /// not have a buffer to lend and the source's may be read-only.
    scratch: []u8,
    left: u64,
    decoder: chunked.Decoder,
    finished: bool,
    err: ?BodyError,

    fn stream(io_r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const b: *BodyReader = @alignCast(@fieldParentPtr("interface", io_r));
        const s = b.server;
        if (b.finished) return error.EndOfStream;

        while (true) {
            const buffered = s.reader.buffered();
            if (buffered.len != 0) switch (s.pending) {
                .none => unreachable,
                .length => {
                    const take = @min(@as(u64, limit.minInt(buffered.len)), b.left);
                    const n: usize = @intCast(take);
                    try w.writeAll(buffered[0..n]);
                    s.reader.toss(n);
                    b.left -= take;
                    if (b.left == 0) b.complete();
                    return n;
                },
                .chunked => {
                    const take = @min(limit.minInt(buffered.len), b.scratch.len);
                    @memcpy(b.scratch[0..take], buffered[0..take]);
                    const r = b.decoder.decode(b.scratch[0..take]) catch {
                        b.fail(error.BadChunk);
                        return error.ReadFailed;
                    };
                    // Whatever the decoder did not consume stays in the
                    // source and comes round again.
                    s.reader.toss(take - r.leftover);
                    if (r.done) b.complete();
                    if (r.decoded != 0) {
                        try w.writeAll(b.scratch[0..r.decoded]);
                        return r.decoded;
                    }
                    if (b.finished) return error.EndOfStream;
                    // No output and nothing consumed means the decoder is
                    // mid-header and needs bytes it has not seen.
                    if (r.leftover == take) break;
                    continue;
                },
            };
            break;
        }

        s.reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => {
                b.fail(error.Incomplete);
                return error.ReadFailed;
            },
            error.ReadFailed => {
                b.fail(error.ReadFailed);
                return error.ReadFailed;
            },
        };
        return 0;
    }

    fn complete(b: *BodyReader) void {
        b.finished = true;
        b.server.pending = .none;
    }

    fn fail(b: *BodyReader, e: BodyError) void {
        b.err = e;
        b.finished = true;
        b.server.keep_alive = false;
    }

    /// What actually went wrong, once the interface says ReadFailed.
    pub fn failure(b: *const BodyReader) ?BodyError {
        return b.err;
    }
};

/// A reader over the current request's body. Valid until the next `receive`,
/// like everything else here.
///
/// `scratch` is only used for chunked bodies and wants to be big enough to
/// hold a chunk header plus some payload; a few hundred bytes is plenty.
pub fn bodyReader(s: *Server, scratch: []u8) Io.Writer.Error!BodyReader {
    if (s.pending != .none) {
        try s.sendContinue();
        s.reader.toss(s.head_len);
        s.head_len = 0;
    }
    return .{
        .server = s,
        .interface = .{
            .vtable = &.{ .stream = BodyReader.stream },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        },
        .scratch = scratch,
        .left = switch (s.pending) {
            .length => |n| n,
            else => 0,
        },
        .decoder = .{ .consume_trailer = true },
        .finished = s.pending == .none,
        .err = null,
    };
}

/// Tells a waiting peer to send its body. `readBody` and `bodyReader`
/// do this for you.
pub fn sendContinue(s: *Server) Io.Writer.Error!void {
    if (!s.expect_continue) return;
    s.expect_continue = false;
    try s.writer.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
    try s.writer.flush();
}

/// 100-continue is the only one we take. Anything else gets a 417.
fn expectsContinue(head: scan.Head) error{UnsupportedExpectation}!bool {
    var found = false;
    for (head.headers) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "expect")) continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, h.value, " \t"), "100-continue")) {
            return error.UnsupportedExpectation;
        }
        found = true;
    }
    return found;
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
pub fn readBody(s: *Server, buf: []u8) (BodyError || Io.Writer.Error || error{BodyTooLarge})![]u8 {
    // Nothing to get past for a request with no body, so the head is left
    // where it is and stays readable without having been copied.
    if (s.pending == .none) return buf[0..0];

    try s.sendContinue();

    s.reader.toss(s.head_len);
    s.head_len = 0;

    switch (s.pending) {
        .none => unreachable,
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

pub const SendError = Response.WriteError;

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

/// Copies the head out of the reader's buffer and re-points every slice in
/// it at the copy, so it stays readable once the body has moved things.
fn keepHead(s: *Server, bytes: []const u8, head: scan.Head) error{HeadTooLarge}!scan.Head {
    if (bytes.len > s.head_buf.len) return error.HeadTooLarge;
    const dst = s.head_buf[0..bytes.len];
    @memcpy(dst, bytes);

    const base = bytes.ptr;
    const move = struct {
        fn f(from: []const u8, old: [*]const u8, new: []u8) []const u8 {
            const offset = @intFromPtr(from.ptr) - @intFromPtr(old);
            return new[offset..][0..from.len];
        }
    }.f;

    var out = head;
    out.method = move(head.method, base, dst);
    out.target = move(head.target, base, dst);
    for (s.headers[0..head.headers.len]) |*h| {
        h.name = move(h.name, base, dst);
        h.value = move(h.value, base, dst);
    }
    out.headers = s.headers[0..head.headers.len];
    return out;
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

/// How the bytes arrive. `whole` is one buffer already in memory, which is
/// convenient and nothing like a socket. `split` hands over one byte per
/// read, so the reader refills and rebases constantly, which is the shape
/// that has caught every real bug in this file.
const Shape = enum { whole, split };

const Harness = struct {
    fixed: Io.Reader,
    trickle: std.testing.Reader,
    calls: [1024]std.testing.Reader.Call,
    small: [512]u8,
    writer: Io.Writer,
    headers: [16]scan.Header,
    head_buf: [1024]u8,
    out: [8192]u8,

    fn init(h: *Harness, shape: Shape, input: []const u8) Server {
        h.writer = .fixed(&h.out);
        const reader = switch (shape) {
            .whole => blk: {
                h.fixed = .fixed(input);
                break :blk &h.fixed;
            },
            .split => blk: {
                std.debug.assert(input.len <= h.calls.len);
                for (h.calls[0..input.len], 0..) |*c, i| c.* = .{ .buffer = input[i..][0..1] };
                h.trickle = .init(&h.small, h.calls[0..input.len]);
                break :blk &h.trickle.interface;
            },
        };
        return .init(testing.io, reader, &h.writer, .{
            .headers = &h.headers,
            .head_buf = &h.head_buf,
        });
    }

    fn written(h: *Harness) []const u8 {
        return h.writer.buffered();
    }
};

const shapes = [_]Shape{ .whole, .split };

test "one request and one response" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET /hi HTTP/1.1\r\nHost: x\r\n\r\n");

        const req = (try s.receive()).?;
        try testing.expectEqualStrings("GET", req.method());
        try testing.expectEqualStrings("/hi", req.target());
        try testing.expectEqualStrings("x", req.header("host").?);
        try testing.expectEqual(body.Framing.none, req.framing);

        try s.respond(Response.text(.ok, "yes"));
        try testing.expect(std.mem.endsWith(u8, h.written(), "\r\n\r\nyes"));
        try testing.expect(s.alive());
    }
}

test "two requests on one connection" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n");

        const first = (try s.receive()).?;
        try testing.expectEqualStrings("/a", first.target());
        try s.respond(.{});

        const second = (try s.receive()).?;
        try testing.expectEqualStrings("/b", second.target());
        try s.respond(.{});

        try testing.expectEqual(@as(?Request, null), try s.receive());
    }
}

test "a body with a length" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello");

        const req = (try s.receive()).?;
        try testing.expectEqual(@as(u64, 5), req.framing.length);

        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("hello", try s.readBody(&buf));
        try testing.expectEqualStrings("/", req.target());
    }
}

test "a chunked body" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST /c HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n");

        const req = (try s.receive()).?;
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("abcdefg", try s.readBody(&buf));
        try testing.expectEqualStrings("/c", req.target());
    }
}

test "an unread body is dropped before the next request" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST /a HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloGET /b HTTP/1.1\r\n\r\n");

        _ = (try s.receive()).?;
        try s.respond(.{});

        const second = (try s.receive()).?;
        try testing.expectEqualStrings("/b", second.target());
    }
}

test "an unread chunked body is dropped too" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\nGET /b HTTP/1.1\r\n\r\n");

        _ = (try s.receive()).?;
        try s.respond(.{});

        const second = (try s.receive()).?;
        try testing.expectEqualStrings("/b", second.target());
    }
}

test "connection close ends the loop" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET / HTTP/1.1\r\nConnection: close\r\n\r\nGET /again HTTP/1.1\r\n\r\n");

        _ = (try s.receive()).?;
        try testing.expect(!s.alive());
        try s.respond(.{});
        try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") != null);
        try testing.expectEqual(@as(?Request, null), try s.receive());
    }
}

test "a clean close between requests is not an error" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "");
        try testing.expectEqual(@as(?Request, null), try s.receive());
    }
}

test "a head cut off halfway is not a clean close" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET / HTTP/1.1\r\nHost: x\r\n");
        try testing.expectError(error.BadRequest, s.receive());
    }
}

test "garbage is a bad request" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "not a request at all\r\n\r\n");
        try testing.expectError(error.BadRequest, s.receive());
    }
}

test "ambiguous framing is refused before the handler sees it" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello");
        try testing.expectError(error.Ambiguous, s.receive());
    }
}

test "more headers than there is room for" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET / HTTP/1.1\r\n" ++ ("X: y\r\n" ** 20) ++ "\r\n");
        try testing.expectError(error.HeadTooLarge, s.receive());
    }
}

test "a body bigger than the caller's buffer" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\n" ++ ("x" ** 100));
        _ = (try s.receive()).?;
        var buf: [10]u8 = undefined;
        try testing.expectError(error.BodyTooLarge, s.readBody(&buf));
    }
}

test "a truncated body" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort");
        _ = (try s.receive()).?;
        var buf: [64]u8 = undefined;
        try testing.expectError(error.Incomplete, s.readBody(&buf));
    }
}

test "the head survives reading the body" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST /the-target-here HTTP/1.1\r\nContent-Length: 20\r\n\r\n01234567890123456789");

        const req = (try s.receive()).?;
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("01234567890123456789", try s.readBody(&buf));
        try testing.expectEqualStrings("/the-target-here", req.target());
        try testing.expectEqualStrings("POST", req.method());
    }
}

test "the head survives reading a chunked body" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST /the-target-here HTTP/1.1\r\nTransfer-Encoding: chunked\r\nX-Tag: keepme\r\n\r\n14\r\n01234567890123456789\r\n0\r\n\r\n");

        const req = (try s.receive()).?;
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("01234567890123456789", try s.readBody(&buf));
        try testing.expectEqualStrings("/the-target-here", req.target());
        try testing.expectEqualStrings("keepme", req.header("x-tag").?);
    }
}

test "a body with nowhere to keep the head" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi");
        s.head_buf = &.{};
        try testing.expectError(error.HeadTooLarge, s.receive());
    }
}

test "no body means no copy and no head_buf needed" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET /plain HTTP/1.1\r\nHost: x\r\n\r\n");
        s.head_buf = &.{};

        const req = (try s.receive()).?;
        try testing.expectEqualStrings("/plain", req.target());
    }
}

test "a request knows when it is no longer the current one" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n");

        const first = (try s.receive()).?;
        try testing.expect(first.live());
        try testing.expectEqualStrings("/a", first.target());
        try s.respond(.{});

        const second = (try s.receive()).?;
        try testing.expect(second.live());
        try testing.expect(!first.live());
    }
}

test "streaming a body with a length" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nContent-Length: 11\r\n\r\nhello world");
        _ = (try s.receive()).?;

        var sink: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&sink);
        var scratch: [512]u8 = undefined;
        var b = try s.bodyReader(&scratch);
        _ = try b.interface.streamRemaining(&w);
        try testing.expectEqualStrings("hello world", w.buffered());
    }
}

test "streaming a chunked body" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n");
        _ = (try s.receive()).?;

        var sink: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&sink);
        var scratch: [512]u8 = undefined;
        var b = try s.bodyReader(&scratch);
        _ = try b.interface.streamRemaining(&w);
        try testing.expectEqualStrings("abcdefg", w.buffered());
    }
}

test "streaming into something with no buffer of its own" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n");
        _ = (try s.receive()).?;

        var counter: Io.Writer.Discarding = .init(&.{});
        var scratch: [512]u8 = undefined;
        var b = try s.bodyReader(&scratch);
        _ = try b.interface.streamRemaining(&counter.writer);
        try testing.expectEqual(@as(u64, 7), counter.count);
    }
}

test "a scratch barely big enough" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n");
        _ = (try s.receive()).?;

        var sink: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&sink);
        var scratch: [8]u8 = undefined;
        var b = try s.bodyReader(&scratch);
        _ = try b.interface.streamRemaining(&w);
        try testing.expectEqualStrings("abcdefg", w.buffered());
    }
}

test "streaming a body bigger than any buffer here" {
    const chunk = "0123456789" ** 100;
    const total = 200;
    var calls: [total + 1]std.testing.Reader.Call = undefined;
    calls[0] = .{ .buffer = "POST / HTTP/1.1\r\nContent-Length: 200000\r\n\r\n" };
    for (calls[1..]) |*c| c.* = .{ .buffer = chunk };

    var buf: [256]u8 = undefined;
    var src: std.testing.Reader = .init(&buf, &calls);
    var out: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var headers: [8]scan.Header = undefined;
    var head_buf: [256]u8 = undefined;
    var s: Server = .init(testing.io, &src.interface, &w, .{
        .headers = &headers,
        .head_buf = &head_buf,
    });

    _ = (try s.receive()).?;

    var counter: Io.Writer.Discarding = .init(&.{});
    var scratch: [512]u8 = undefined;
    var b = try s.bodyReader(&scratch);
    const n = try b.interface.streamRemaining(&counter.writer);
    try testing.expectEqual(@as(usize, 200_000), n);
    try testing.expectEqual(@as(u64, 200_000), counter.count);
}

test "a truncated body reports why" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nContent-Length: 50\r\n\r\nshort");
        _ = (try s.receive()).?;

        var sink: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&sink);
        var scratch: [512]u8 = undefined;
        var b = try s.bodyReader(&scratch);
        try testing.expectError(error.ReadFailed, b.interface.streamRemaining(&w));
        try testing.expectEqual(BodyError.Incomplete, b.failure().?);
    }
}

test "a bad chunk reports why" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\nabc\r\n0\r\n\r\n");
        _ = (try s.receive()).?;

        var sink: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&sink);
        var scratch: [512]u8 = undefined;
        var b = try s.bodyReader(&scratch);
        try testing.expectError(error.ReadFailed, b.interface.streamRemaining(&w));
        try testing.expectEqual(BodyError.BadChunk, b.failure().?);
    }
}

test "streaming leaves the connection on the next request" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST /a HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloGET /b HTTP/1.1\r\n\r\n");
        _ = (try s.receive()).?;

        var sink: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&sink);
        var scratch: [512]u8 = undefined;
        var b = try s.bodyReader(&scratch);
        _ = try b.interface.streamRemaining(&w);
        try testing.expectEqualStrings("hello", w.buffered());

        try s.respond(.{});
        const second = (try s.receive()).?;
        try testing.expectEqualStrings("/b", second.target());
    }
}

test "100 Continue goes out when the body is read" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello");

        const req = (try s.receive()).?;
        try testing.expect(req.expectsContinue());

        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("hello", try s.readBody(&buf));
        try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 100 Continue\r\n\r\n"));

        try s.respond(Response.text(.ok, "got it"));
        try testing.expect(std.mem.indexOf(u8, h.written(), "HTTP/1.1 200 OK") != null);
    }
}

test "100 Continue is not sent when the body is refused" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello");

        const req = (try s.receive()).?;
        try testing.expect(req.expectsContinue());

        try s.respond(.{ .status = .payload_too_large, .keep_alive = false });
        try testing.expect(std.mem.indexOf(u8, h.written(), "100 Continue") == null);
        try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 413"));
    }
}

test "an expectation we do not know is a 417" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nExpect: something-else\r\nContent-Length: 5\r\n\r\nhello");
        try testing.expectError(error.UnsupportedExpectation, s.receive());
    }
}

test "no Expect means no continue" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello");
        const req = (try s.receive()).?;
        try testing.expect(!req.expectsContinue());
        var buf: [64]u8 = undefined;
        _ = try s.readBody(&buf);
        try testing.expect(std.mem.indexOf(u8, h.written(), "100 Continue") == null);
    }
}

test "streaming sends the continue too" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\nhi");
        _ = (try s.receive()).?;

        var sink: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&sink);
        var scratch: [64]u8 = undefined;
        var b = try s.bodyReader(&scratch);
        _ = try b.interface.streamRemaining(&w);
        try testing.expectEqualStrings("hi", w.buffered());
        try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 100 Continue\r\n\r\n"));
    }
}
