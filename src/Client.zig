//! The client side. It writes requests and reads responses.
//!
//! Same rules as Server. You hand it a reader and a writer. It doesn't
//! open sockets, resolve names or follow redirects.

const std = @import("std");
const Io = std.Io;

const scan = @import("scan.zig");
const body = @import("body.zig");
const HeadWindow = @import("HeadWindow.zig");
const field = @import("field.zig");
const BodyWriter = @import("BodyWriter.zig");
const FailureSource = @import("FailureSource.zig");
const Message = @import("Message.zig");

const Client = @This();

io: Io,
writer: *Io.Writer,
/// Owns where the reader is: head, body, drain.
window: HeadWindow,
/// The method we sent, parsed, because a HEAD comes back with a length
/// and no body. We keep the enum instead of the bytes so that nothing
/// holds a slice of the caller's request after the send.
sent_method: ?scan.Method = null,
/// Whether another exchange can follow. Either side's `Connection:
/// close` clears it, and so does a failed write.
keep_alive: bool = true,
phase: Phase = .ready,

/// Where the exchange has got to.
///
/// A single value answers both "can I send another request" and "can I
/// read a response". Whether the connection outlives the exchange is a
/// separate thing, `keep_alive`.
///
/// `Server.Phase` is the mirror of this. The responder reads then
/// writes and the requester writes then reads, so the middle two states
/// are swapped.
pub const Phase = enum {
    /// Nothing outstanding, either before the first request or after
    /// the last response.
    ready,
    /// The head is out and the body is still being written. Nothing
    /// moves until `RequestWriter.end`.
    sending,
    /// The peer agreed to another protocol and we have the head that
    /// says so. `handOver` finishes the job.
    switching,
    /// A request is on the wire and there is no response yet. Sending
    /// another one is pipelining, which we don't allow. We only keep one
    /// request's framing rules at a time, so a second send would frame
    /// the first response with the wrong method.
    sent,
    /// We have the response head. Its body might still be unread, and
    /// the window drains whatever is left on the next take.
    received,
    /// Another protocol owns the connection.
    handed_over,
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
        .writer = writer,
        .window = try .init(reader, .{
            .headers = options.headers,
            .head_buf = options.head_buf,
            .trailer_buf = options.trailer_buf,
            .max_drain = options.max_drain,
            .failure = options.failure,
        }),
    };
}

pub const Header = scan.Header;

pub const Request = struct {
    method: []const u8 = "GET",
    target: []const u8 = "/",
    headers: []const Header = &.{},
    body: []const u8 = "",
};

pub const SendError = field.HeadError || Io.Writer.Error || error{
    /// The method or target doesn't fit in a request line.
    InvalidRequest,
    /// No Host, more than one, or one that isn't a host and port. A
    /// server has to refuse these, so we don't send them. See
    /// `field.checkHost`.
    BadHost,
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
    _ = try c.writeHead(r, .{ .complete = r.body });
    errdefer c.writeFailed();
    try c.writer.writeAll(r.body);
    try c.writer.flush();
    c.phase = .sent;
}

pub const StreamOptions = struct {
    /// Null means chunked.
    content_length: ?u64 = null,
};

/// Starts a request whose body gets written afterwards. Finish it with
/// `end`.
///
/// `out_buf` becomes the body writer's buffer, so its size is the
/// biggest piece that goes out in one write. With chunked encoding that
/// is the chunk size on the wire. `Request.body` is ignored here, since
/// the body is whatever you write to the returned writer.
pub fn sendStreaming(
    c: *Client,
    r: Request,
    out_buf: []u8,
    options: StreamOptions,
) SendError!RequestWriter {
    const plan = try c.writeHead(r, if (options.content_length) |n| .{ .length = n } else .chunked);
    errdefer c.writeFailed();
    // The head goes out now. A server we asked for 100-continue can't
    // answer a request it hasn't seen yet.
    try c.writer.flush();
    c.phase = .sending;
    return .init(c.writer, out_buf, plan.mode, .{ .ctx = c, .settled = settled });
}

/// Writes the request body a piece at a time. See `BodyWriter`.
pub const RequestWriter = BodyWriter;

/// An unfinished body ends the connection. A finished one leaves the
/// request outstanding, waiting to be answered.
fn settled(ctx: *anyopaque, state: BodyWriter.State) void {
    const c: *Client = @ptrCast(@alignCast(ctx));
    switch (state) {
        .broken => c.writeFailed(),
        .finished => c.phase = .sent,
        .open => unreachable,
    }
}

/// A write failed. Part of a request is on the wire and the next one
/// would just carry on from there, so nothing more happens here.
fn writeFailed(c: *Client) void {
    c.keep_alive = false;
    c.phase = .done;
}

/// The request line and headers, up to the blank line. Everything gets
/// checked before a byte goes out, because half a request line becomes
/// the start of whatever is sent next.
fn writeHead(c: *Client, r: Request, out: body.Outgoing) SendError!body.Plan {
    switch (c.phase) {
        .ready, .received => {},
        .sent, .sending => return error.ExchangeOpen,
        .switching, .handed_over, .done => return error.Closed,
    }
    if (!c.keep_alive or !c.window.usable()) return error.Closed;
    if (!scan.validFieldName(r.method)) return error.InvalidRequest;
    if (r.target.len == 0 or hasControl(r.target) or
        std.mem.indexOfScalar(u8, r.target, ' ') != null) return error.InvalidRequest;
    try field.checkHost(r.headers, true);

    const h: field.Head = .{ .fields = r.headers, .body = out };
    const plan = try field.checkHead(h);

    // Past every check now. A write that fails from here on leaves part
    // of a request on the wire.
    errdefer c.writeFailed();
    try c.writer.print("{s} {s} HTTP/1.1\r\n", .{ r.method, r.target });
    try field.writeHead(c.writer, h, plan);

    c.sent_method = scan.Method.parse(r.method);
    // A `close` we send ends the connection just like one from the
    // server.
    if (!body.keepAlive(.ours(r.headers))) c.keep_alive = false;
    return plan;
}

pub const ReceiveError = error{
    /// Not a response.
    BadResponse,
    /// The head didn't fit, or it had too many headers.
    HeadTooLarge,
    /// Nothing outstanding to read. Send a request first.
    NothingSent,
    /// A streamed request body is still open. End it first.
    RequestOpen,
    Ambiguous,
    UnsupportedEncoding,
    ReadFailed,
    /// The peer went quiet. You only get this if `Options.failure` was
    /// set.
    Timeout,
} || Io.Cancelable;

/// Points into the connection's buffers and is valid until the next
/// `receive`. Using it after that panics in Debug and ReleaseSafe.
pub const Response = Message.Message(.response);

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
        .sending => return error.RequestOpen,
        .switching, .handed_over, .done => return null,
    }

    errdefer c.phase = .done;

    const resp = (c.window.takeResponse(c.sent_method) catch |err| return switch (err) {
        error.Invalid => error.BadResponse,
        else => |e| e,
    }) orelse {
        c.phase = .done;
        return null;
    };

    const answer = body.answer(c.sent_method, resp.head.status);
    switch (answer) {
        // The peer stopped speaking HTTP. Another head here would scan
        // the next protocol's first bytes.
        .switch_protocols, .tunnel => c.phase = .switching,
        // Frames nothing. The real response is still to come.
        .interim => c.phase = .sent,
        else => c.phase = .received,
    }
    if (answer != .interim and !body.keepAlive(.of(resp.head))) c.keep_alive = false;

    return resp;
}

/// Trailers from the response body, scanned into `storage`. Chunked
/// bodies only, and only after the body has been read. They arrive after
/// the body, so don't use them for framing.
pub fn trailers(c: *Client, storage: []scan.Header) scan.Error![]const scan.Header {
    return c.window.trailers(storage);
}

pub const BodyError = HeadWindow.BodyError;

/// Reads the whole body into `buf`. If it doesn't fit you get an error
/// instead of a short read.
pub fn readBody(c: *Client, buf: []u8) BodyError![]u8 {
    return c.window.readBody(buf);
}

/// The response body as an `Io.Reader`, for bodies too big to hold in
/// memory.
pub const BodyReader = HeadWindow.BodyReader;

/// A reader over the response body, valid until the next `receive`.
///
/// `decode_buf` is the reader's own memory. It is what the reader
/// buffers into, and where a chunked body decodes on the way out. A few
/// hundred bytes is plenty, and two is the minimum.
pub fn bodyReader(c: *Client, decode_buf: []u8) HeadWindow.BodyReaderError!BodyReader {
    return c.window.bodyReader(decode_buf);
}

/// Stops speaking HTTP after a 101 or a 2xx answer to a CONNECT. We are
/// done with the head by then, so its bytes go and the reader ends up at
/// whatever the other protocol sent first.
///
/// This is only valid after `receive` returned one of those two, and
/// anything else asserts in Debug and ReleaseSafe. The reader and writer
/// are yours after this.
pub fn handOver(c: *Client) void {
    // This returns nothing, so it has no way to say no. Handing over a
    // connection nobody switched would give the caller the rest of a
    // response as another protocol's first bytes.
    std.debug.assert(c.phase == .switching);
    // A switching response has no body, so there is nothing to drain.
    c.window.handOver() catch unreachable;
    c.phase = .handed_over;
}

/// Has it been handed to another protocol?
pub fn handedOver(c: *const Client) bool {
    return c.phase == .handed_over;
}

/// Can the connection carry another exchange? False while one is still
/// outstanding.
pub fn alive(c: *const Client) bool {
    switch (c.phase) {
        .sent, .sending, .switching, .handed_over, .done => return false,
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

const host: []const Header = &.{.{ .name = "Host", .value = "x" }};

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
    tight: [16]u8,

    /// Test knobs. All of them go through `Options`.
    const Setup = struct {
        /// Read a body the caller ignored. Off by default.
        max_drain: u64 = 0,
        /// Almost nowhere for the request to go. A `fixed` writer with
        /// plenty of room never fails partway through a head.
        tight_writer: bool = false,
    };

    fn init(h: *Harness, shape: Shape, input: []const u8) Client {
        return h.initWith(shape, input, .{});
    }

    fn initWith(h: *Harness, shape: Shape, input: []const u8, setup: Setup) Client {
        const reader = h.source.reader(shape, input);
        h.writer = if (setup.tight_writer) .fixed(&h.tight) else .fixed(&h.out);
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
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "");
        try c.send(.{ .target = "/things", .headers = &.{.{ .name = "Host", .value = "example.com" }} });
        try testing.expectEqualStrings(
            "GET /things HTTP/1.1\r\nHost: example.com\r\n\r\n",
            h.sent(),
        );
    }
}

test "a body gets a length" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "");
        try c.send(.{ .method = "POST", .target = "/x", .body = "hello", .headers = host });
        try testing.expectEqualStrings("POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello", h.sent());
    }
}

test "a caller's own framing is left alone" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "");
        try c.send(.{
            .method = "POST",
            .headers = &.{ .{ .name = "Host", .value = "x" }, .{ .name = "Transfer-Encoding", .value = "chunked" } },
            .body = "5\r\nhello\r\n0\r\n\r\n",
        });
        try testing.expect(std.mem.indexOf(u8, h.sent(), "Content-Length") == null);
    }
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
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nContent-Length: 2\r\nSet-Cookie: b=2\r\n\r\nhi");
        try c.send(.{ .headers = host });
        const res = (try c.receive()).?;

        try testing.expectEqual(@as(?u64, 2), res.contentLength());
        try testing.expect(res.hasBody());
        try testing.expectEqual(@as(usize, 3), res.headers().len);

        var it = res.headerIter("set-cookie");
        try testing.expectEqualStrings("a=1", it.next().?);
        try testing.expectEqualStrings("b=2", it.next().?);
        try testing.expectEqual(@as(?[]const u8, null), it.next());
    }
}

test "a server that says close ends the connection" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.initWith(
            shape,
            "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nhi",
            .{},
        );
        try c.send(.{ .headers = host });
        _ = (try c.receive()).?;
        var buf: [8]u8 = undefined;
        try testing.expectEqualStrings("hi", try c.readBody(&buf));

        try testing.expect(!c.alive());
        try testing.expectError(error.Closed, c.send(.{ .headers = host }));
    }
}

test "an HTTP/1.0 response without keep-alive ends the connection" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n");
        try c.send(.{ .headers = host });
        _ = (try c.receive()).?;
        try testing.expect(!c.alive());
    }
}

test "a body that ran to the close leaves nothing to send on" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.0 200 OK\r\n\r\neverything after the head");
        try c.send(.{ .headers = host });
        _ = (try c.receive()).?;
        var buf: [64]u8 = undefined;
        _ = try c.readBody(&buf);
        try testing.expect(!c.alive());
    }
}

test "an interim response does not decide the connection" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
        try c.send(.{ .headers = host });
        _ = (try c.receive()).?;
        _ = (try c.receive()).?;
        try testing.expect(c.alive());
    }
}

test "a streamed request body is chunked when the length is unknown" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");

        var scratch: [64]u8 = undefined;
        var rw = try c.sendStreaming(.{ .method = "POST", .target = "/up", .headers = host }, &scratch, .{});
        try rw.interface.writeAll("hello ");
        try rw.interface.writeAll("world");
        try rw.end();

        const out = h.sent();
        try testing.expect(std.mem.indexOf(u8, out, "Transfer-Encoding: chunked") != null);
        try testing.expect(std.mem.endsWith(u8, out, "b\r\nhello world\r\n0\r\n\r\n"));

        const res = (try c.receive()).?;
        try testing.expectEqual(@as(u16, 200), res.status());
    }
}

test "a streamed request with a known length is not chunked" {
    var h: Harness = undefined;
    var c = h.init(.whole, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");

    var scratch: [64]u8 = undefined;
    var rw = try c.sendStreaming(.{ .method = "PUT", .target = "/f", .headers = host }, &scratch, .{ .content_length = 5 });
    try rw.interface.writeAll("hello");
    try rw.end();

    const out = h.sent();
    try testing.expect(std.mem.indexOf(u8, out, "Content-Length: 5") != null);
    try testing.expect(std.mem.indexOf(u8, out, "chunked") == null);
    try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\nhello"));
}

test "a streamed request body that stops short is refused" {
    var h: Harness = undefined;
    var c = h.init(.whole, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");

    var scratch: [64]u8 = undefined;
    var rw = try c.sendStreaming(.{ .method = "PUT", .target = "/f", .headers = host }, &scratch, .{ .content_length = 100 });
    try rw.interface.writeAll("not enough");
    try testing.expectError(error.LengthMismatch, rw.end());
    try testing.expect(!c.alive());
    try testing.expectError(error.Finished, rw.end());
}

test "nothing else happens while a request body is open" {
    var h: Harness = undefined;
    var c = h.init(.whole, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");

    var scratch: [64]u8 = undefined;
    var rw = try c.sendStreaming(.{ .method = "POST", .target = "/a", .headers = host }, &scratch, .{});
    try rw.interface.writeAll("part");

    try testing.expectError(error.RequestOpen, c.receive());
    try testing.expectError(error.ExchangeOpen, c.send(.{ .headers = host }));
    try testing.expect(!c.alive());

    try rw.end();
    _ = (try c.receive()).?;
}

test "a HEAD sent as a streamed request still frames its answer" {
    var h: Harness = undefined;
    var c = h.init(.whole, "HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n");

    var scratch: [64]u8 = undefined;
    var rw = try c.sendStreaming(.{ .method = "HEAD", .target = "/x", .headers = host }, &scratch, .{ .content_length = 0 });
    try rw.end();

    const res = (try c.receive()).?;
    try testing.expectEqual(body.Framing.none, res.framing);
}

test "a request the writer cannot hold ends the connection" {
    var h: Harness = undefined;
    var c = h.initWith(.whole, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", .{ .tight_writer = true });

    // 16 bytes of room, and the request line alone doesn't fit.
    try testing.expectError(error.WriteFailed, c.send(.{ .target = "/a-long-target", .headers = host }));

    try testing.expect(!c.alive());
    try testing.expectError(error.Closed, c.send(.{ .target = "/b", .headers = host }));
    try testing.expectEqual(@as(?Response, null), try c.receive());
}

test "a streamed request whose head cannot be written ends the connection" {
    var h: Harness = undefined;
    var c = h.initWith(.whole, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", .{ .tight_writer = true });

    var scratch: [32]u8 = undefined;
    try testing.expectError(
        error.WriteFailed,
        c.sendStreaming(.{ .method = "POST", .target = "/a-long-target", .headers = host }, &scratch, .{}),
    );
    try testing.expect(!c.alive());
}

test "a body the writer cannot hold ends the connection" {
    var h: Harness = undefined;
    var c = h.initWith(.whole, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", .{ .tight_writer = true });

    // The head fits in 16 bytes and the body doesn't, so the failure
    // happens after `writeHead`.
    try testing.expectError(error.WriteFailed, c.send(.{ .method = "PUT", .target = "/", .body = "hello", .headers = host }));
    try testing.expect(!c.alive());
    try testing.expectError(error.Closed, c.send(.{ .headers = host }));
}

test "a request cannot be framed two ways at once" {
    var h: Harness = undefined;
    var c = h.init(.whole, "");

    try testing.expectError(error.AmbiguousFraming, c.send(.{
        .method = "POST",
        .headers = &.{
            .{ .name = "Host", .value = "x" },                    .{ .name = "Content-Length", .value = "5" },
            .{ .name = "Transfer-Encoding", .value = "chunked" },
        },
        .body = "hello",
    }));
    try testing.expectEqualStrings("", h.sent());
    // Rejected before any byte went out, so the exchange is still open
    // for a sensible request.
    try testing.expect(c.alive());
}

test "a 101 is the peer agreeing to stop speaking HTTP" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(
            shape,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\nEARLYFRAME",
        );
        try c.send(.{ .target = "/ws", .headers = &.{
            .{ .name = "Host", .value = "x" },            .{ .name = "Connection", .value = "Upgrade" },
            .{ .name = "Upgrade", .value = "websocket" },
        } });

        const res = (try c.receive()).?;
        try testing.expectEqual(@as(u16, 101), res.status());
        try testing.expectEqualStrings("websocket", res.header("upgrade").?);

        // Not an interim response. Another receive would scan the
        // peer's first frame as a head.
        try testing.expect(!c.alive());
        try testing.expectEqual(@as(?Response, null), try c.receive());
        try testing.expectError(error.Closed, c.send(.{ .headers = host }));

        c.handOver();
        try testing.expect(c.handedOver());
    }
}

test "a 2xx answer to a CONNECT is a tunnel here too" {
    var h: Harness = undefined;
    var c = h.init(.whole, "HTTP/1.1 200 Connection Established\r\n\r\nTUNNELBYTES");
    try c.send(.{ .method = "CONNECT", .target = "example.com:443", .headers = host });

    const res = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 200), res.status());
    try testing.expectEqual(body.Framing.none, res.framing);

    try testing.expect(!c.alive());
    try testing.expectError(error.Closed, c.send(.{ .headers = host }));

    c.handOver();
    try testing.expect(c.handedOver());

    // The head is out of the way, so the reader holds tunnel bytes.
    var rest: [16]u8 = undefined;
    var sink: Io.Writer = .fixed(&rest);
    _ = try h.source.fixed.streamRemaining(&sink);
    try testing.expectEqualStrings("TUNNELBYTES", sink.buffered());
}

test "a 1xx that is not a 101 is still interim" {
    var h: Harness = undefined;
    var c = h.init(.whole, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
    try c.send(.{ .method = "POST", .headers = host });

    _ = (try c.receive()).?;
    const final = (try c.receive()).?;
    try testing.expectEqual(@as(u16, 200), final.status());
    try testing.expect(c.alive());
}

test "one exchange at a time" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");

        try testing.expectError(error.NothingSent, c.receive());

        try c.send(.{ .target = "/a", .headers = host });
        try testing.expect(!c.alive());
        // Pipelining would frame the first response with the second
        // request's method.
        try testing.expectError(error.ExchangeOpen, c.send(.{ .target = "/b", .headers = host }));

        _ = (try c.receive()).?;
        try testing.expect(c.alive());
        try testing.expectError(error.NothingSent, c.receive());
    }
}

test "an interim response leaves the exchange open" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi");
        try c.send(.{ .method = "POST", .headers = &.{ .{ .name = "Host", .value = "x" }, .{ .name = "Expect", .value = "100-continue" } } });

        const interim = (try c.receive()).?;
        try testing.expectEqual(@as(u16, 100), interim.status());

        const final = (try c.receive()).?;
        try testing.expectEqual(@as(u16, 200), final.status());
        var buf: [8]u8 = undefined;
        try testing.expectEqualStrings("hi", try c.readBody(&buf));
    }
}

test "a response that could not be read ends the exchange" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "this is not http\r\n\r\n");
        try c.send(.{ .headers = host });
        try testing.expectError(error.BadResponse, c.receive());
        try testing.expect(!c.alive());
        try testing.expectError(error.Closed, c.send(.{ .headers = host }));
    }
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
        try c.send(.{ .headers = host });
        try testing.expectError(
            if (why == error.Timeout) error.Timeout else error.ReadFailed,
            c.receive(),
        );
    }

    var f: arrival.Failing = .{};
    f.init();
    var w: Io.Writer = .fixed(&out);
    var c = try Client.init(testing.io, &f.interface, &w, .{ .headers = &headers });
    try c.send(.{ .headers = host });
    try testing.expectError(error.ReadFailed, c.receive());
}

test "a response arrives however the bytes do" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.initWith(shape, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", .{});
        try c.send(.{ .headers = host });

        const res = (try c.receive()).?;
        try testing.expectEqual(@as(u16, 200), res.status());
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("hello", try c.readBody(&buf));
    }
}

test "a chunked response, and its trailers" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.initWith(
            shape,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
                "5\r\nhello\r\n0\r\nX-Sum: 42\r\n\r\n",
            .{},
        );
        try c.send(.{ .headers = host });
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
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "");
        try testing.expectError(error.InvalidHeader, c.send(.{
            .target = "/a",
            .headers = &.{ .{ .name = "Host", .value = "example.com" }, .{ .name = "X", .value = "a\r\nY: 2" } },
        }));
        // A request line already on the wire would end up in front of
        // the next send.
        try testing.expectEqualStrings("", h.sent());
    }
}

test "a request line that cannot be written" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "");
        try testing.expectError(error.InvalidRequest, c.send(.{ .method = "GE T", .headers = host }));
        try testing.expectError(error.InvalidRequest, c.send(.{ .target = "/a b", .headers = host }));
        try testing.expectError(error.InvalidRequest, c.send(.{ .target = "/a\r\nX: 1", .headers = host }));
        try testing.expectError(error.InvalidHeader, c.send(.{
            .headers = &.{ .{ .name = "Host", .value = "x" }, .{ .name = "X", .value = "a\r\nY: 2" } },
        }));
    }
}

test "a Host a server would refuse is not sent" {
    var h: Harness = undefined;
    var c = h.init(.whole, "");
    try testing.expectError(error.BadHost, c.send(.{}));
    try testing.expectError(error.BadHost, c.send(.{ .headers = &.{ .{ .name = "Host", .value = "a" }, .{ .name = "host", .value = "a" } } }));
    try testing.expectError(error.BadHost, c.send(.{ .headers = &.{.{ .name = "Host", .value = "a b" }} }));
    try testing.expectEqualStrings("", h.sent());
    try c.send(.{ .headers = &.{.{ .name = "Host", .value = "" }} });
}

test "a response with a length" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
        try c.send(.{ .headers = host });

        const res = (try c.receive()).?;
        try testing.expectEqual(@as(u16, 200), res.status());
        try testing.expectEqualStrings("OK", res.reason());

        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("hello", try c.readBody(&buf));
        try testing.expectEqualStrings("5", res.header("content-length").?);
    }
}

test "a chunked response" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n");
        try c.send(.{ .headers = host });
        _ = (try c.receive()).?;
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("abcdefg", try c.readBody(&buf));
    }
}

test "a response that runs until the connection closes" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.0 200 OK\r\n\r\neverything after the head");
        try c.send(.{ .headers = host });
        const res = (try c.receive()).?;
        try testing.expectEqual(body.Framing.until_close, res.framing);
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("everything after the head", try c.readBody(&buf));
    }
}

test "204 has no body even when it claims one" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi");
        try c.send(.{ .headers = host });
        const first = (try c.receive()).?;
        try testing.expectEqual(@as(u16, 204), first.status());
        try testing.expectEqual(body.Framing.none, first.framing);

        try c.send(.{ .headers = host });
        const second = (try c.receive()).?;
        try testing.expectEqual(@as(u16, 200), second.status());
    }
}

test "a HEAD response is not read as having a body" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi");
        try c.send(.{ .method = "HEAD", .headers = host });
        const first = (try c.receive()).?;
        try testing.expectEqual(body.Framing.none, first.framing);
        try c.send(.{ .headers = host });
        const second = (try c.receive()).?;
        try testing.expectEqual(@as(u16, 200), second.status());
    }
}

test "two responses on one connection" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\naHTTP/1.1 404 Not Found\r\nContent-Length: 1\r\n\r\nb");
        try c.send(.{ .headers = host });

        const first = (try c.receive()).?;
        try testing.expectEqual(@as(u16, 200), first.status());
        var buf: [8]u8 = undefined;
        try testing.expectEqualStrings("a", try c.readBody(&buf));

        try c.send(.{ .headers = host });
        const second = (try c.receive()).?;
        try testing.expectEqual(@as(u16, 404), second.status());
        try testing.expectEqualStrings("b", try c.readBody(&buf));
    }
}

test "an unread body is dropped before the next response" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.initWith(
            shape,
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloHTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n",
            .{ .max_drain = 64 * 1024 },
        );
        try c.send(.{ .headers = host });
        _ = (try c.receive()).?;
        try c.send(.{ .headers = host });
        const second = (try c.receive()).?;
        try testing.expectEqual(@as(u16, 404), second.status());
    }
}

test "a stale response is caught" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n");
        try c.send(.{ .headers = host });
        const first = (try c.receive()).?;
        try testing.expect(first.live());
        try c.send(.{ .headers = host });
        _ = (try c.receive()).?;
        try testing.expect(!first.live());
    }
}

test "garbage is not a response" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "this is not http\r\n\r\n");
        try c.send(.{ .headers = host });
        try testing.expectError(error.BadResponse, c.receive());
    }
}

test "a clean close before any response" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "");
        try c.send(.{ .headers = host });
        try testing.expectEqual(@as(?Response, null), try c.receive());
    }
}

test "a smuggling response is refused" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello");
        try c.send(.{ .headers = host });
        try testing.expectError(error.Ambiguous, c.receive());
    }
}

test "a response says how long its body is" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
        try c.send(.{ .headers = host });
        const res = (try c.receive()).?;
        try testing.expectEqual(@as(?u64, 5), res.contentLength());
        try testing.expect(res.hasBody());
    }
}

test "a chunked response has no length to report" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var c = h.init(shape, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");
        try c.send(.{ .headers = host });
        const res = (try c.receive()).?;
        try testing.expectEqual(@as(?u64, null), res.contentLength());
        try testing.expect(res.hasBody());
    }
}

test "a Connection: close we sent ends the connection" {
    var h: Harness = undefined;
    // The server doesn't have to say close back.
    var c = h.init(.whole, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
    try c.send(.{ .headers = &.{ .{ .name = "Host", .value = "x" }, .{ .name = "Connection", .value = "close" } } });
    _ = (try c.receive()).?;
    try testing.expect(!c.alive());
    try testing.expectError(error.Closed, c.send(.{ .headers = host }));
}
