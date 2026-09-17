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
const FailureSource = @import("FailureSource.zig");
const Message = @import("Message.zig");

const Client = @This();

io: Io,
reader: *Io.Reader,
writer: *Io.Writer,
/// Owns where the reader is: head, body, drain.
window: HeadWindow,
/// The method we sent, parsed, because a HEAD comes back with a length
/// and no body. We keep the enum instead of the bytes so that nothing
/// holds a slice of the caller's request after the send.
sent_method: ?scan.Method = null,
/// What the last response said about doing another exchange. A server
/// saying `close` is just as final as a client saying it.
keep_alive: bool = true,
/// Where to ask why a read failed, if the reader keeps track of that.
failure: ?FailureSource = null,
phase: Phase = .ready,

/// Where the exchange has got to.
///
/// A single value answers both "can I send another request" and "can I
/// read a response". Whether the connection outlives the exchange is a
/// separate thing, `keep_alive`, which the other end's `Connection`
/// header decides.
///
/// `Server.Phase` is the mirror of this. The responder reads then
/// writes and the requester writes then reads, so the middle two states
/// are swapped.
pub const Phase = enum {
    /// Nothing outstanding, either before the first request or after
    /// the last response.
    ready,
    /// A request is on the wire and there is no response yet. Sending
    /// another one is pipelining, which we don't allow. We only keep one
    /// request's framing rules at a time, so a second send would frame
    /// the first response with the wrong method.
    sent,
    /// We have the response head. Its body might still be unread, and
    /// the window drains whatever is left on the next take.
    received,
    /// Nothing more will be read or written here.
    done,
};

pub const Options = struct {
    /// Storage for the response's headers.
    headers: []scan.Header,
    /// Where the head is kept while a body is being read.
    head_buf: []u8 = &.{},
    /// Holds trailer lines. Leaving it empty drops them, which is
    /// usually fine.
    trailer_buf: []u8 = &.{},
    /// How much of an unread body we will read to keep the connection.
    /// Zero, which is the default, closes it instead.
    max_drain: u64 = 0,
    /// Pass one and `receive` can tell a quiet peer from a dead one.
    /// `TimedReader.failureSource()` gives you one.
    failure: ?FailureSource = null,
};

/// The window's, forwarded. It owns `head_buf` and the rules about how
/// big it has to be.
pub const InitError = HeadWindow.InitError;

pub fn init(io: Io, reader: *Io.Reader, writer: *Io.Writer, options: Options) InitError!Client {
    return .{
        .io = io,
        .reader = reader,
        .writer = writer,
        .window = try .init(reader, .{
            .headers = options.headers,
            .head_buf = options.head_buf,
            .trailer_buf = options.trailer_buf,
            .max_drain = options.max_drain,
        }),
        .failure = options.failure,
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
    /// The last request hasn't been answered yet. Receive first.
    ExchangeOpen,
    /// Finished. Either a response ran to close, or we couldn't read
    /// one.
    Closed,
};

/// Writes a request and flushes it.
///
/// Every header gets checked before a byte is written. A rejected
/// request leaves the writer untouched, because half a request line
/// becomes the start of whatever gets sent next, and then you have split
/// one request into two.
pub fn send(c: *Client, r: Request) SendError!void {
    switch (c.phase) {
        .ready, .received => {},
        .sent => return error.ExchangeOpen,
        .done => return error.Closed,
    }
    if (!c.keep_alive or !c.window.usable()) return error.Closed;
    if (!scan.validFieldName(r.method)) return error.InvalidRequest;
    if (r.target.len == 0 or hasControl(r.target) or
        std.mem.indexOfScalar(u8, r.target, ' ') != null) return error.InvalidRequest;

    var framed = false;
    for (r.headers) |h| {
        if (!scan.validFieldName(h.name) or !scan.validFieldValue(h.value)) return error.InvalidHeader;
        if (std.ascii.eqlIgnoreCase(h.name, "content-length") or
            std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) framed = true;
    }

    const w = c.writer;
    try w.writeAll(r.method);
    try w.writeByte(' ');
    try w.writeAll(r.target);
    try w.writeAll(" HTTP/1.1\r\n");

    for (r.headers) |h| {
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

    c.sent_method = scan.Method.parse(r.method);
    c.phase = .sent;
}

pub const ReceiveError = error{
    /// Not a response.
    BadResponse,
    /// The head didn't fit, or it had too many headers.
    HeadTooLarge,
    /// Nothing outstanding to read. Send a request first.
    NothingSent,
    Ambiguous,
    UnsupportedEncoding,
    ReadFailed,
    /// The peer went quiet. You only get this if `Options.failure` was
    /// set.
    Timeout,
} || Io.Cancelable;

/// Points into the connection's buffers and is valid until the next
/// `receive`. Using it after that panics in Debug and ReleaseSafe.
pub const Response = Message.Message(.response, Client);

pub const HeaderIterator = Message.HeaderIterator;

/// Reads the next response head, or null if the peer closed cleanly.
///
/// An interim response, meaning a 1xx that isn't a 101, leaves the
/// exchange open, so the next `receive` reads the real one.
///
/// A 101, or a 2xx answer to a CONNECT, means the peer agreed to stop
/// speaking HTTP. The response still comes back so you can read its
/// head, but nothing more gets sent or received. Call `handOver` when
/// you are done with the head and the reader and writer are yours.
pub fn receive(c: *Client) ReceiveError!?Response {
    switch (c.phase) {
        .sent => {},
        .ready, .received => return error.NothingSent,
        .done => return null,
    }

    errdefer c.phase = .done;

    const taken = (c.window.takeResponse(c.sent_method) catch |err| return switch (err) {
        error.Invalid => error.BadResponse,
        error.ReadFailed => c.readFailure(),
        error.HeadTooLarge => error.HeadTooLarge,
        error.Ambiguous => error.Ambiguous,
        error.UnsupportedEncoding => error.UnsupportedEncoding,
        error.Canceled => error.Canceled,
    }) orelse {
        c.phase = .done;
        return null;
    };

    const interim = taken.head.status >= 100 and taken.head.status < 200;
    // An interim response frames nothing. The real one is still coming.
    if (!interim) c.keep_alive = body.keepAlive(.of(taken.head));
    c.phase = if (interim) .sent else .received;

    return .{
        .head = taken.head,
        .framing = taken.framing,
        .owner = c,
        .generation = c.window.generation,
    };
}

/// Why the read failed, if the reader keeps that and the caller said
/// where to ask. The same reasoning as Server's: only `Timeout` is
/// named, because every other cause ends the connection the same way.
fn readFailure(c: *Client) ReceiveError {
    const f = c.failure orelse return error.ReadFailed;
    const cause = f.last() orelse return error.ReadFailed;
    return switch (cause) {
        error.Timeout => error.Timeout,
        else => error.ReadFailed,
    };
}

/// Trailers from the response body, scanned into `storage`. Chunked
/// bodies only, and only after the body has been read. They arrive after
/// the body, so don't use them for framing.
pub fn trailers(c: *Client, storage: []scan.Header) scan.Error![]const scan.Header {
    return c.window.trailers(storage);
}

pub const BodyError = HeadWindow.BodyError;

/// Reads the whole body into `buf`. If it doesn't fit you get an error,
/// not a short read.
pub fn readBody(c: *Client, buf: []u8) BodyError![]u8 {
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

/// Can the connection carry another exchange? False while one is still
/// outstanding.
pub fn alive(c: *const Client) bool {
    switch (c.phase) {
        .sent, .done => return false,
        .ready, .received => {},
    }
    return c.keep_alive and c.window.usable();
}

fn hasControl(bytes: []const u8) bool {
    for (bytes) |ch| {
        if (ch < 0x20 or ch == 0x7f) return true;
    }
    return false;
}


const testing = std.testing;

const arrival = @import("arrival.zig");
const Shape = arrival.Shape;
const shapes = arrival.shapes;

const Harness = struct {
    source: arrival.Source(4096, 512),
    writer: Io.Writer,
    headers: [16]scan.Header,
    head_buf: [16 * 1024]u8,
    trailer_buf: [512]u8,
    out: [4096]u8,

    /// Test knobs. All of them go through `Options`.
    const Setup = struct {
        /// Read a body the caller ignored. Off by default.
        max_drain: u64 = 0,
    };

    fn init(h: *Harness, input: []const u8) Client {
        return h.initShaped(.whole, input, .{});
    }

    fn initWith(h: *Harness, input: []const u8, setup: Setup) Client {
        return h.initShaped(.whole, input, setup);
    }

    fn initShaped(h: *Harness, shape: Shape, input: []const u8, setup: Setup) Client {
        const reader = h.source.reader(shape, input);
        h.writer = .fixed(&h.out);
        return Client.init(testing.io, reader, &h.writer, .{
            .headers = &h.headers,
            .head_buf = &h.head_buf,
            .trailer_buf = &h.trailer_buf,
            .max_drain = setup.max_drain,
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

test "the head_buf rule reaches the Client too" {
    var read_buf: [4096]u8 = undefined;
    var src: std.testing.Reader = .init(&read_buf, &.{});
    var out: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var headers: [8]scan.Header = undefined;
    var head_buf: [128]u8 = undefined;

    try testing.expectError(error.HeadBufferTooSmall, Client.init(testing.io, &src.interface, &w, .{
        .headers = &headers,
        .head_buf = &head_buf,
    }));
}

test "a response answers the questions a request does" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nContent-Length: 2\r\nSet-Cookie: b=2\r\n\r\nhi");
    try c.send(.{});
    const res = (try c.receive()).?;

    try testing.expectEqual(@as(?u64, 2), res.contentLength());
    try testing.expect(res.hasBody());
    try testing.expectEqual(@as(usize, 3), res.headers().len);

    // Both of them, which the Client had no way to ask before.
    var it = res.headerIter("set-cookie");
    try testing.expectEqualStrings("a=1", it.next().?);
    try testing.expectEqualStrings("b=2", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "a server that says close ends the connection" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.initShaped(
            shape,
            "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nhi",
            .{},
        );
        try c.send(.{});
        _ = (try c.receive()).?;
        var buf: [8]u8 = undefined;
        try testing.expectEqualStrings("hi", try c.readBody(&buf));

        try testing.expect(!c.alive());
        try testing.expectError(error.Closed, c.send(.{}));
    }
}

test "an HTTP/1.0 response without keep-alive ends the connection" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n");
    try c.send(.{});
    _ = (try c.receive()).?;
    try testing.expect(!c.alive());
}

test "a body that ran to the close leaves nothing to send on" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.0 200 OK\r\n\r\neverything after the head");
    try c.send(.{});
    _ = (try c.receive()).?;
    var buf: [64]u8 = undefined;
    _ = try c.readBody(&buf);
    try testing.expect(!c.alive());
}

test "an interim response does not decide the connection" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
    try c.send(.{});
    _ = (try c.receive()).?;
    _ = (try c.receive()).?;
    try testing.expect(c.alive());
}

test "one exchange at a time" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");

    // Nothing sent, so there is nothing to read.
    try testing.expectError(error.NothingSent, c.receive());

    try c.send(.{ .target = "/a" });
    try testing.expect(!c.alive());
    // Pipelining would decide the first response's body with the second
    // request's method.
    try testing.expectError(error.ExchangeOpen, c.send(.{ .target = "/b" }));

    _ = (try c.receive()).?;
    try testing.expect(c.alive());
    try testing.expectError(error.NothingSent, c.receive());
}

test "an interim response leaves the exchange open" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi");
    try c.send(.{ .method = "POST", .headers = &.{.{ .name = "Expect", .value = "100-continue" }} });

    const interim = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 100), interim.status());

    // No second send: the request is still outstanding.
    const final = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 200), final.status());
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("hi", try c.readBody(&buf));
}

test "a response that could not be read ends the exchange" {
    var h: Harness = undefined;
    var c = h.init("this is not http\r\n\r\n");
    try c.send(.{});
    try testing.expectError(error.BadResponse, c.receive());
    try testing.expect(!c.alive());
    try testing.expectError(error.Closed, c.send(.{}));
}

test "a peer that went quiet is told apart from one that went away" {
    var out: [64]u8 = undefined;
    var headers: [8]scan.Header = undefined;

    for ([_]anyerror{ error.Timeout, error.ConnectionResetByPeer }) |why| {
        var f: arrival.Failing = .{ .why = why };
        f.init();
        var w: Io.Writer = .fixed(&out);
        var c = try Client.init(testing.io, &f.interface, &w, .{
            .headers = &headers,
            .failure = f.source(),
        });
        try c.send(.{});
        try testing.expectError(
            if (why == error.Timeout) error.Timeout else error.ReadFailed,
            c.receive(),
        );
    }

    var f: arrival.Failing = .{};
    f.init();
    var w: Io.Writer = .fixed(&out);
    var c = try Client.init(testing.io, &f.interface, &w, .{ .headers = &headers });
    try c.send(.{});
    try testing.expectError(error.ReadFailed, c.receive());
}

test "a response arrives however the bytes do" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.initShaped(shape, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", .{});
        try c.send(.{});

        const res = (try c.receive()).?;
        try testing.expectEqual(@as(u16, 200), res.status());
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("hello", try c.readBody(&buf));
    }
}

test "a chunked response, and its trailers" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.initShaped(
            shape,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
                "5\r\nhello\r\n0\r\nX-Sum: 42\r\n\r\n",
            .{},
        );
        try c.send(.{});
        _ = (try c.receive()).?;

        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("hello", try c.readBody(&buf));

        var storage: [8]scan.Header = undefined;
        const t = try c.trailers(&storage);
        try testing.expectEqual(@as(usize, 1), t.len);
        try testing.expectEqualStrings("42", t[0].value);
    }
}

test "a refused header leaves the writer untouched" {
    var h: Harness = undefined;
    var c = h.init("");
    try testing.expectError(error.InvalidHeader, c.send(.{
        .target = "/a",
        .headers = &.{ .{ .name = "Host", .value = "example.com" }, .{ .name = "X", .value = "a\r\nY: 2" } },
    }));
    // A request line already on the wire would be the prefix of the next
    // send: a request split.
    try testing.expectEqualStrings("", h.sent());
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
    try c.send(.{});
    const second = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 200), second.status());
}

test "a HEAD response is not read as having a body" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi");
    try c.send(.{ .method = "HEAD" });
    const first = (try c.receive()).?;
    try testing.expectEqual(body.Framing.none, first.framing);
    try c.send(.{});
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

    try c.send(.{});
    const second = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 404), second.status());
    try testing.expectEqualStrings("b", try c.readBody(&buf));
}

test "an unread body is dropped before the next response" {
    var h: Harness = undefined;
    // Reading a body the caller skipped is opt-in.
    var c = h.initWith(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloHTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n",
        .{ .max_drain = 64 * 1024 },
    );
    try c.send(.{});
    _ = (try c.receive()).?;
    try c.send(.{});
    const second = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 404), second.status());
}

test "a stale response is caught" {
    var h: Harness = undefined;
    var c = h.init("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n");
    try c.send(.{});
    const first = (try c.receive()).?;
    try testing.expect(first.live());
    try c.send(.{});
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
