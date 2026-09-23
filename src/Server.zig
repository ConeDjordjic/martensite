//! One connection, read as a series of requests.
//!
//! Everything under this works on byte slices, so you can skip it and
//! drive the bytes yourself.

const std = @import("std");
const Io = std.Io;

const scan = @import("scan.zig");
const body = @import("body.zig");
const target_mod = @import("target.zig");
const DateHeader = @import("Date.zig");
const HeadWindow = @import("HeadWindow.zig");
const FailureSource = @import("FailureSource.zig");
const Response = @import("Response.zig");
const Message = @import("Message.zig");
const field = @import("field.zig");
const BodyWriter = @import("BodyWriter.zig");
const serve_mod = @import("serve.zig");

const Server = @This();

io: Io,
writer: *Io.Writer,
/// Owns where the reader is: head, body, drain.
window: HeadWindow,
date: ?DateHeader,
/// What `max_drain` goes back to for each new request.
max_drain: u64,

keep_alive: bool = true,
phase: Phase = .ready,
/// The method we have in hand, parsed. Together with the status it
/// decides what comes after the response head. See `body.answer`.
method: ?scan.Method = null,
/// We still owe the peer a 100 Continue.
expect_continue: bool = false,
/// The last final response, for an access log. It includes the ones
/// `serve` writes for you. `receive` clears it.
last: ?Sent = null,

pub const Sent = struct {
    status: Response.Status,
    /// Body bytes, not counting chunk framing. Zero for a HEAD.
    body_bytes: u64 = 0,
    /// False while a streamed body is still open, and for good if a
    /// write failed or the body was never ended.
    complete: bool = false,
};

/// Where the connection is in the request/response cycle.
///
/// A single value answers both "can I read another head" and "can I
/// write a response", so there are no two flags to drift apart. It does
/// not answer "will the connection outlive this message". That is
/// `keep_alive`, which either side's `Connection` header can clear, and
/// so can a failed write. `alive()` checks both.
///
/// `Client.Phase` is the mirror of this, with the two middle states in
/// the opposite order.
pub const Phase = enum {
    /// No request in hand, either before the first one or after the
    /// last one was answered. Responding here gives you a standalone
    /// final response, which is what an error path wants.
    ready,
    /// A request came in and hasn't been answered yet.
    unanswered,
    /// A streamed response is open, so the head is on the wire and the
    /// body is unfinished. Reading another request here would answer it
    /// into the middle of this body, so nothing moves until
    /// `ResponseWriter.end`.
    streaming,
    /// Already answered. A second response would be read as the answer
    /// to a request the peer hasn't sent yet.
    answered,
    /// Another protocol owns the connection.
    handed_over,
    /// Nothing more will be read or written here.
    done,
};

pub const Options = struct {
    /// Storage for the request's headers. Anything over this is
    /// HeadTooLarge.
    headers: []scan.Header,
    /// Holds the head while a body is read, because reading moves the
    /// reader past it and a later fill writes over it. Requests with no
    /// body never touch this, so it can be empty.
    head_buf: []u8 = &.{},
    /// Holds trailer lines. Leaving it empty drops them, which is
    /// usually fine.
    trailer_buf: []u8 = &.{},
    /// Adds a Date header to every response that doesn't have one. HTTP
    /// asks for it from any server with a clock. It is rendered at most
    /// once a second.
    date: bool = true,
    /// How much of an unread body we will read to keep the connection.
    /// Zero closes it instead. Answering a POST without reading it, say
    /// with a 401 or a 404, is common, and without a drain each of those
    /// costs the peer a new connection. `setMaxDrain` changes it for one
    /// request.
    max_drain: u64 = 64 * 1024,
    /// Pass one and `receive` can tell a quiet peer from a dead one.
    /// `TimedReader.failureSource()` gives you one. Always pass it with a
    /// TimedReader, or a timeout gets a 400 instead of a 408.
    failure: ?FailureSource = null,
};

/// The window's, forwarded. It owns `head_buf` and the rules about how
/// big it has to be.
pub const InitError = HeadWindow.InitError;

pub fn init(io: Io, reader: *Io.Reader, writer: *Io.Writer, options: Options) InitError!Server {
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
        .date = if (options.date) .{} else null,
        .max_drain = options.max_drain,
    };
}

/// Changes `max_drain` for the current request, for example to let an
/// upload route answer early and still keep the connection. The next
/// `receive` uses it to drain this request's body, then puts the value
/// from `Options` back.
pub fn setMaxDrain(s: *Server, n: u64) void {
    s.window.max_drain = n;
}

/// Points into the connection's buffers and is valid until the next
/// `receive`. Using it after that panics in Debug and ReleaseSafe.
pub const Request = Message.Message(.request);

pub const HeaderIterator = Message.HeaderIterator;

pub const ReceiveError = error{
    /// Not a request.
    BadRequest,
    /// A streamed response is still open. End it first.
    ResponseOpen,
    /// The request we have hasn't been answered. Answer it first.
    RequestUnanswered,
    /// No Host on an HTTP/1.1 request, more than one, or one that isn't
    /// a host and port.
    BadHost,
    /// An Expect we don't support. Answer 417.
    UnsupportedExpectation,
    /// The head didn't fit, or it had too many headers.
    HeadTooLarge,
    /// The framing rules were broken. See body.Error.
    Ambiguous,
    UnsupportedEncoding,
    ReadFailed,
    /// The peer went quiet. You only get this if `Options.failure` was
    /// set.
    Timeout,
} || Io.Cancelable;

/// Reads the next request head, or null if the peer closed cleanly. An
/// unread body left over from the last request gets dropped first.
pub fn receive(s: *Server) ReceiveError!?Request {
    switch (s.phase) {
        .handed_over, .done => return null,
        .streaming => return error.ResponseOpen,
        // Each request gets one response. Reading the next one first would
        // frame the answer from the wrong request, and the peer would
        // read it as the answer to the one still outstanding.
        .unanswered => return error.RequestUnanswered,
        .ready, .answered => {},
    }
    if (!s.keep_alive) return null;
    s.last = null;

    // Drop the request whenever something fails, so nothing about the
    // last one leaks into the response an error path is about to
    // write.
    errdefer s.forgetRequest();

    const req = (s.window.takeRequest() catch |err| return switch (err) {
        error.Invalid => error.BadRequest,
        else => |e| e,
    }) orelse {
        s.forgetRequest();
        s.phase = .done;
        return null;
    };
    // The last request's body is drained now, so its limit is done with.
    s.window.max_drain = s.max_drain;

    if (target_mod.parse(req.head.target) == null) return error.BadRequest;
    try field.checkHost(req.head.headers, req.head.minor_version >= 1);
    s.expect_continue = try Message.expectation(req.head.headers);
    s.method = scan.Method.parse(req.head.method);
    s.keep_alive = body.keepAlive(.of(req.head));
    s.phase = .unanswered;

    return req;
}

/// The request body as an `Io.Reader`, for bodies too big to hold in
/// memory.
pub const BodyReader = HeadWindow.BodyReader;

/// A reader over the request body, valid until the next `receive`.
///
/// `decode_buf` is the reader's own memory. It is what the reader
/// buffers into, and where a chunked body gets decoded on the way out.
/// It is not the size of the body and not the connection's buffer. A few
/// hundred bytes is plenty, and two is the minimum.
pub fn bodyReader(s: *Server, decode_buf: []u8) (Io.Writer.Error || HeadWindow.BodyReaderError)!BodyReader {
    try s.window.checkReader(decode_buf.len);
    try s.sendContinue();
    return s.window.bodyReader(decode_buf);
}

/// Tells a waiting peer to send its body. `readBody` and `bodyReader`
/// do this for you, once they know they are going to read it.
pub fn sendContinue(s: *Server) Io.Writer.Error!void {
    if (!s.expect_continue) return;
    s.expect_continue = false;
    errdefer s.writeFailed();
    try s.writer.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
    try s.writer.flush();
}

pub const BodyError = HeadWindow.BodyError;

/// The body's own errors, plus the 100 Continue that reading a body owes
/// a waiting peer.
pub const ReadBodyError = BodyError || Io.Writer.Error;

/// Reads the whole body into `buf`. If it doesn't fit you get an error
/// instead of a short read.
pub fn readBody(s: *Server, buf: []u8) ReadBodyError![]u8 {
    try s.window.checkRead(buf.len);
    try s.sendContinue();
    return s.window.readBody(buf);
}

pub const SendError = field.HeadError || Io.Writer.Error || error{
    /// Already answered. A second response would be read as the answer
    /// to a request the peer hasn't sent yet.
    AlreadyAnswered,
    /// This answer hands the connection over, but part of the request
    /// body is still in the reader and couldn't be drained within
    /// `max_drain`. The next protocol would read it as its own bytes.
    /// The request is still unanswered, and the connection closes after
    /// whatever you send instead.
    BodyPending,
};

pub const StreamError = SendError || error{
    /// A 1xx or a tunnel has no body to stream. Use `respond`, or
    /// `upgrade` for a 101.
    NoBodyToStream,
};

pub const UpgradeError = SendError || error{
    /// Not a 101, and not a 2xx to a CONNECT.
    NotSwitching,
};

/// A write failed. Part of a message is on the wire and the next one
/// would just carry on from there, so nothing more happens on this
/// connection. Every path that writes bytes ends up here when it fails.
fn writeFailed(s: *Server) void {
    s.keep_alive = false;
    s.phase = .done;
}

/// Forgets the last request, so nothing about it leaks into a response
/// written with no request in hand.
fn forgetRequest(s: *Server) void {
    s.method = null;
    s.expect_continue = false;
    s.keep_alive = false;
    if (s.phase == .unanswered or s.phase == .answered) s.phase = .ready;
}

/// What comes after a response with this status, given the request we
/// have.
fn answerTo(s: *const Server, status: Response.Status) body.Answer {
    return body.answer(s.method, @intFromEnum(status));
}

/// Checks a response, then writes its head. Everything that can be
/// refused is refused before anything changes, so the caller can still
/// answer some other way.
fn writeHead(s: *Server, r: Response, out: body.Outgoing) SendError!body.Plan {
    switch (s.phase) {
        .ready, .unanswered => {},
        .streaming, .answered, .handed_over, .done => return error.AlreadyAnswered,
    }
    // Our own Scanner wants exactly three digits.
    const code = @intFromEnum(r.status);
    if (code < 100 or code > 999) return error.AmbiguousFraming;

    const answer = s.answerTo(r.status);
    var h: field.Head = .{
        .fields = r.headers,
        .content_type = r.content_type,
        .body = out,
        .answer = answer,
        .date = s.dateValue(),
    };
    const plan = try field.checkHead(h);
    // After a 101 the reader belongs to someone else, so a body still in
    // it has to go before we say yes.
    if (answer.switches()) s.window.handOver() catch {
        s.keep_alive = false;
        return error.BodyPending;
    };

    const interim = answer == .interim;
    if (interim) {
        // The real response is still to come, so the request stays
        // unanswered. A 100 sent this way is the one we owed.
        if (code == 100) s.expect_continue = false;
    } else {
        // With no request in hand there is nothing to keep the connection
        // for.
        if (s.phase == .ready) s.keep_alive = false;
        if (!r.keep_alive or !body.keepAlive(.ours(r.headers))) s.keep_alive = false;
        // A body left in the reader that the drain won't take ends the
        // connection. The peer should hear that from the head instead of
        // from a closed socket.
        if (s.window.endsHere()) s.keep_alive = false;
        s.phase = .answered;
        s.last = .{ .status = r.status };
        // Once an answer is on the wire, a 100 would be a second response.
        s.expect_continue = false;
    }

    errdefer s.writeFailed();
    try s.writer.print("HTTP/1.1 {d} {s}\r\n", .{ code, r.status.phrase() });
    // A connection that switches protocols isn't closing, and a 1xx
    // doesn't decide anything about it.
    h.close = !s.keep_alive and !answer.switches() and !interim;
    try field.writeHead(s.writer, h, plan);
    return plan;
}

/// Writes a response and flushes it. A 101, or a 2xx to a CONNECT, hands
/// the connection over like `upgrade` does. Any other 1xx, like 103
/// Early Hints, leaves the request unanswered so the real response can
/// follow.
///
/// If the request has a body you haven't read and `max_drain` won't
/// cover it, the response says `Connection: close`. Read the body first
/// if you want to keep the connection.
pub fn respond(s: *Server, r: Response) SendError!void {
    const plan = try s.writeHead(r, .{ .complete = r.body });
    errdefer s.writeFailed();
    if (plan.mode != .discard) try s.writer.writeAll(r.body);
    try s.writer.flush();
    const answer = s.answerTo(r.status);
    if (answer != .interim) s.last = .{
        .status = r.status,
        .body_bytes = if (plan.mode == .discard) 0 else r.body.len,
        .complete = true,
    };
    if (answer.switches()) {
        s.phase = .handed_over;
    } else if (answer != .interim and !s.keep_alive) {
        s.phase = .done;
    }
}

pub const StreamOptions = struct {
    /// Null means chunked.
    content_length: ?u64 = null,
};

/// Starts a response whose body gets written afterwards. Finish it with
/// `end`. `out_buf` becomes the writer's buffer, so its size is the
/// biggest piece that goes out in one write. With chunked encoding that
/// is the chunk size on the wire. This is not the same kind of buffer as
/// `bodyReader`'s, even though it sits in the same place.
pub fn respondStreaming(
    s: *Server,
    r: Response,
    out_buf: []u8,
    options: StreamOptions,
) StreamError!ResponseWriter {
    const answer = s.answerTo(r.status);
    if (answer.switches() or answer == .interim) return error.NoBodyToStream;
    const plan = try s.writeHead(r, if (options.content_length) |n| .{ .length = n } else .chunked);
    // There is no `ResponseWriter` yet, so nothing else would settle the
    // connection if the head doesn't go out.
    errdefer s.writeFailed();
    // The head goes out now instead of when the body ends, because the
    // peer might be waiting for it before it sends anything else.
    try s.writer.flush();
    s.phase = .streaming;
    return .init(s.writer, out_buf, plan.mode, .{ .ctx = s, .settled = settled });
}

/// Writes the response body a piece at a time. See `BodyWriter`.
pub const ResponseWriter = BodyWriter;

/// An unfinished body ends the connection. A finished one means the
/// request is answered.
fn settled(ctx: *anyopaque, state: BodyWriter.State, written: u64) void {
    const s: *Server = @ptrCast(@alignCast(ctx));
    if (s.last) |*l| {
        l.body_bytes = written;
        l.complete = state == .finished;
    }
    switch (state) {
        .broken => s.writeFailed(),
        .finished => s.phase = if (s.keep_alive) .answered else .done,
        .open => unreachable,
    }
}

/// Today's date, unless it was turned off. It is left out if the
/// response already has a Date.
fn dateValue(s: *Server) ?[]const u8 {
    const d = if (s.date) |*d| d else return null;
    return d.value(s.io);
}

/// Trailers from the request body, scanned into `storage`. Chunked
/// bodies only, and only after the body has been read. They arrive after
/// the body, so don't use them for framing or routing.
pub fn trailers(s: *Server, storage: []scan.Header) scan.Error![]const scan.Header {
    return s.window.trailers(storage);
}

/// Can the connection carry another request? False while a streamed
/// response is still open.
pub fn alive(s: *const Server) bool {
    switch (s.phase) {
        .streaming, .handed_over, .done => return false,
        .ready, .unanswered, .answered => {},
    }
    return s.keep_alive and s.window.usable();
}

/// Runs the request loop for this connection. See `serve.zig`.
pub const serve = serve_mod.serve;
pub const ServeOptions = serve_mod.Options;

/// Answers the handshake and stops speaking HTTP. The reader and writer
/// are yours after this. It is `respond` with a check that the status
/// really does switch.
///
/// Anything the peer sent after the request is still in the reader,
/// since clients often send their first frame without waiting for the
/// 101. A request body that hasn't been read gets drained first, and if
/// it can't be you get `BodyPending`.
pub fn upgrade(s: *Server, r: Response) UpgradeError!void {
    if (!s.answerTo(r.status).switches()) return error.NotSwitching;
    return s.respond(r);
}

/// Has it been handed to another protocol?
pub fn handedOver(s: *const Server) bool {
    return s.phase == .handed_over;
}

const testing = std.testing;

const arrival = @import("arrival.zig");
const Shape = arrival.Shape;
const shapes = arrival.shapes;

const Harness = struct {
    source: arrival.Source(1024, 512),
    writer: Io.Writer,
    headers: [16]scan.Header,
    head_buf: [16 * 1024]u8,
    trailer_buf: [512]u8,
    out: [8192]u8,
    tight: [16]u8,

    /// Test knobs. All of these go through `Options`, so a test can't
    /// reach a setting a caller can't.
    const Setup = struct {
        /// Read a body the handler ignored. Off by default.
        max_drain: u64 = 0,
        /// Off by default, so tests can compare whole responses.
        date: bool = false,
        /// Somewhere to keep a head while its body is read.
        keep_head: bool = true,
        /// Somewhere to keep the peer's trailers. Off by default.
        keep_trailers: bool = true,
        /// Almost nowhere for the response to go. A `fixed` writer with
        /// plenty of room never fails partway through a head, so nothing
        /// built on one ever hits a write failure mid-response.
        tight_writer: bool = false,
    };

    fn init(h: *Harness, shape: Shape, input: []const u8) Server {
        return h.initWith(shape, input, .{});
    }

    fn initDraining(h: *Harness, shape: Shape, input: []const u8) Server {
        return h.initWith(shape, input, .{ .max_drain = 64 * 1024 });
    }

    fn initTight(h: *Harness, shape: Shape, input: []const u8) Server {
        return h.initWith(shape, input, .{ .tight_writer = true });
    }

    fn initWith(h: *Harness, shape: Shape, input: []const u8, setup: Setup) Server {
        h.writer = if (setup.tight_writer) .fixed(&h.tight) else .fixed(&h.out);
        const reader = h.source.reader(shape, input);
        return Server.init(testing.io, reader, &h.writer, .{
            .headers = &h.headers,
            .head_buf = if (setup.keep_head) &h.head_buf else &.{},
            .trailer_buf = if (setup.keep_trailers) &h.trailer_buf else &.{},
            .max_drain = setup.max_drain,
            .date = setup.date,
        }) catch unreachable;
    }

    fn written(h: *Harness) []const u8 {
        return h.writer.buffered();
    }
};

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
        var s = h.init(shape, "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");

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
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");

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
        var s = h.init(shape, "POST /c HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n");

        const req = (try s.receive()).?;
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("abcdefg", try s.readBody(&buf));
        try testing.expectEqualStrings("/c", req.target());
    }
}

test "an unread body is dropped before the next request" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.initDraining(shape, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhelloGET /b HTTP/1.1\r\nHost: x\r\n\r\n");

        _ = (try s.receive()).?;
        try s.respond(.{});

        const second = (try s.receive()).?;
        try testing.expectEqualStrings("/b", second.target());
    }
}

test "an unread chunked body is dropped too" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.initDraining(shape, "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");

        _ = (try s.receive()).?;
        try s.respond(.{});

        const second = (try s.receive()).?;
        try testing.expectEqualStrings("/b", second.target());
    }
}

test "connection close ends the loop" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nGET /again HTTP/1.1\r\nHost: x\r\n\r\n");

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

test "an HTTP/1.1 request needs exactly one good Host" {
    const bad = [_][]const u8{
        "GET / HTTP/1.1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nHost: a\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nhost: b\r\n\r\n",
        "GET / HTTP/1.0\r\nHost: a\r\nHost: b\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a b\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a:\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a:x1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: [::1\r\n\r\n",
    };
    for (shapes) |shape| for (bad) |input| {
        var h: Harness = undefined;
        var s = h.init(shape, input);
        try testing.expectError(error.BadHost, s.receive());
    };
    try testing.expectEqual(Response.Status.bad_request, Response.Status.forError(error.BadHost));

    const good = [_][]const u8{
        "GET / HTTP/1.0\r\n\r\n",
        "GET / HTTP/1.1\r\nHost:\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: example.com:8080\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: [::1]:80\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        // The target's authority wins, so Host doesn't have to match it.
        "GET http://a/x HTTP/1.1\r\nHost: b\r\n\r\n",
    };
    for (shapes) |shape| for (good) |input| {
        var h: Harness = undefined;
        var s = h.init(shape, input);
        _ = (try s.receive()).?;
    };
}

test "ambiguous framing is refused before the handler sees it" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello");
        try testing.expectError(error.Ambiguous, s.receive());
    }
}

test "more headers than there is room for" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET / HTTP/1.1\r\nHost: x\r\n" ++ ("X: y\r\n" ** 20) ++ "\r\n");
        try testing.expectError(error.HeadTooLarge, s.receive());
    }
}

test "a body bigger than the caller's buffer" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n" ++ ("x" ** 100));
        _ = (try s.receive()).?;
        var buf: [10]u8 = undefined;
        try testing.expectError(error.BodyTooLarge, s.readBody(&buf));
    }
}

test "a truncated body" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nshort");
        _ = (try s.receive()).?;
        var buf: [64]u8 = undefined;
        try testing.expectError(error.Incomplete, s.readBody(&buf));
    }
}

test "the head survives reading the body" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST /the-target-here HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\n01234567890123456789");

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
        var s = h.init(shape, "POST /the-target-here HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nX-Tag: keepme\r\n\r\n14\r\n01234567890123456789\r\n0\r\n\r\n");

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
        var s = h.initWith(shape, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi", .{ .keep_head = false });
        try testing.expectError(error.HeadTooLarge, s.receive());
    }
}

test "no body means no copy and no head_buf needed" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.initWith(shape, "GET /plain HTTP/1.1\r\nHost: x\r\n\r\n", .{ .keep_head = false });

        const req = (try s.receive()).?;
        try testing.expectEqualStrings("/plain", req.target());
    }
}

test "a request knows when it is no longer the current one" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");

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
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world");
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
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n");
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
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n");
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
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n");
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
    calls[0] = .{ .buffer = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 200000\r\n\r\n" };
    for (calls[1..]) |*c| c.* = .{ .buffer = chunk };

    var buf: [256]u8 = undefined;
    var src: std.testing.Reader = .init(&buf, &calls);
    var out: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var headers: [8]scan.Header = undefined;
    var head_buf: [256]u8 = undefined;
    var s: Server = try .init(testing.io, &src.interface, &w, .{
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
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 50\r\n\r\nshort");
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
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\nabc\r\n0\r\n\r\n");
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
        var s = h.init(shape, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhelloGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
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
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello");

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
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello");

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
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nExpect: something-else\r\nContent-Length: 5\r\n\r\nhello");
        try testing.expectError(error.UnsupportedExpectation, s.receive());
    }
}

test "no Expect means no continue" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
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
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\nhi");
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

test "a streamed response is chunked when the length is unknown" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
        _ = (try s.receive()).?;

        var scratch: [64]u8 = undefined;
        var rw = try s.respondStreaming(.{}, &scratch, .{});
        try rw.interface.writeAll("hello ");
        try rw.interface.writeAll("world");
        try rw.end();

        const out = h.written();
        try testing.expect(std.mem.indexOf(u8, out, "Transfer-Encoding: chunked") != null);
        try testing.expect(std.mem.indexOf(u8, out, "Content-Length") == null);
        try testing.expect(std.mem.endsWith(u8, out, "b\r\nhello world\r\n0\r\n\r\n"));
    }
}

test "a streamed response with a known length is not chunked" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
        _ = (try s.receive()).?;

        var scratch: [64]u8 = undefined;
        var rw = try s.respondStreaming(.{}, &scratch, .{ .content_length = 11 });
        try rw.interface.writeAll("hello world");
        try rw.end();

        const out = h.written();
        try testing.expect(std.mem.indexOf(u8, out, "Content-Length: 11") != null);
        try testing.expect(std.mem.indexOf(u8, out, "chunked") == null);
        try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\nhello world"));
    }
}

test "writing more than the promised length is refused" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    var scratch: [4]u8 = undefined;
    var rw = try s.respondStreaming(.{}, &scratch, .{ .content_length = 4 });
    try testing.expectError(error.WriteFailed, rw.interface.writeAll("far too much"));
}

test "stopping short of the promised length is refused" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    var scratch: [64]u8 = undefined;
    var rw = try s.respondStreaming(.{}, &scratch, .{ .content_length = 100 });
    try rw.interface.writeAll("not enough");
    try testing.expectError(error.LengthMismatch, rw.end());
    try testing.expect(!s.alive());
}

test "a streamed response survives a keep-alive connection" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
        _ = (try s.receive()).?;

        var scratch: [64]u8 = undefined;
        var rw = try s.respondStreaming(.{}, &scratch, .{});
        try rw.interface.writeAll("first");
        try rw.end();

        const second = (try s.receive()).?;
        try testing.expectEqualStrings("/b", second.target());
    }
}

test "HEAD gets the headers and none of the body" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "HEAD /thing HTTP/1.1\r\nHost: x\r\n\r\n");
        _ = (try s.receive()).?;
        try s.respond(Response.text(.ok, "twelve bytes"));

        const out = h.written();
        try testing.expect(std.mem.indexOf(u8, out, "Content-Length: 12") != null);
        try testing.expect(std.mem.indexOf(u8, out, "twelve bytes") == null);
        try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n"));
    }
}

test "a streamed body is dropped for HEAD" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "HEAD / HTTP/1.1\r\nHost: x\r\n\r\n");
        _ = (try s.receive()).?;

        var scratch: [64]u8 = undefined;
        var rw = try s.respondStreaming(.{}, &scratch, .{});
        try rw.interface.writeAll("should not appear");
        try rw.end();

        const out = h.written();
        try testing.expect(std.mem.indexOf(u8, out, "should not appear") == null);
    }
}

test "many small writes become many chunks" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    // No buffer, so every write becomes its own chunk.
    var rw = try s.respondStreaming(.{}, &.{}, .{});
    for (0..3) |_| try rw.interface.writeAll("ab");
    try rw.end();

    try testing.expect(std.mem.endsWith(u8, h.written(), "2\r\nab\r\n2\r\nab\r\n2\r\nab\r\n0\r\n\r\n"));
}

test "an upgrade request is recognised" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET /ws HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n");
        const req = (try s.receive()).?;
        try testing.expectEqualStrings("websocket", req.upgradeTo().?);
    }
}

test "Upgrade without Connection: upgrade is not one" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\n");
        const req = (try s.receive()).?;
        try testing.expectEqual(@as(?[]const u8, null), req.upgradeTo());
    }
}

test "Connection: keep-alive, Upgrade counts" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive, Upgrade\r\nUpgrade: h2c\r\n\r\n");
        const req = (try s.receive()).?;
        try testing.expectEqualStrings("h2c", req.upgradeTo().?);
    }
}

test "upgrading hands the connection over" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET /ws HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nFRAMEBYTES");

        const req = (try s.receive()).?;
        try testing.expectEqualStrings("websocket", req.upgradeTo().?);

        try s.upgrade(.{
            .status = .switching_protocols,
            .headers = &.{
                .{ .name = "Upgrade", .value = "websocket" },
                .{ .name = "Connection", .value = "Upgrade" },
            },
        });

        const out = h.written();
        try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 101 Switching Protocols\r\n"));
        try testing.expect(std.mem.indexOf(u8, out, "Content-Length") == null);
        try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n"));

        try testing.expect(s.handedOver());
        try testing.expect(!s.alive());
        try testing.expectEqual(@as(?Request, null), try s.receive());

        // Bytes sent before the 101 are still there for the new owner.
        var rest: [32]u8 = undefined;
        const n = try s.window.reader.readSliceShort(&rest);
        try testing.expectEqualStrings("FRAMEBYTES", rest[0..n]);
    }
}

test "the target comes apart" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET /users/7?tab=posts&page=2 HTTP/1.1\r\nHost: x\r\n\r\n");
        const req = (try s.receive()).?;
        const t = req.parsedTarget();
        try testing.expectEqualStrings("/users/7", t.path);
        try testing.expectEqualStrings("tab=posts&page=2", t.query);

        var pairs: target_mod.Pairs = .init(t.query);
        try testing.expectEqualStrings("tab", pairs.next().?.name);
        try testing.expectEqualStrings("2", pairs.next().?.value);
    }
}

test "repeated headers all come back" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET / HTTP/1.1\r\nHost: x\r\nAccept: a\r\nX: 1\r\nAccept: b\r\n\r\n");
        const req = (try s.receive()).?;

        var it = req.headerIter("accept");
        try testing.expectEqualStrings("a", it.next().?);
        try testing.expectEqualStrings("b", it.next().?);
        try testing.expectEqual(@as(?[]const u8, null), it.next());
    }
}

test "the method comes back as an enum when it is one we name" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "PROPFIND / HTTP/1.1\r\nHost: x\r\n\r\n");
        const req = (try s.receive()).?;
        try testing.expectEqual(@as(?scan.Method, null), req.knownMethod());
        try testing.expectEqualStrings("PROPFIND", req.method());
    }
}

test "request trailers" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(
            shape,
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTrailer: X-Sum\r\n\r\n" ++
                "5\r\nhello\r\n0\r\nX-Sum: 42\r\nX-Other: y\r\n\r\n",
        );
        _ = (try s.receive()).?;

        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("hello", try s.readBody(&buf));

        var storage: [8]scan.Header = undefined;
        const t = try s.trailers(&storage);
        try testing.expectEqual(@as(usize, 2), t.len);
        try testing.expectEqualStrings("X-Sum", t[0].name);
        try testing.expectEqualStrings("42", t[0].value);
        try testing.expectEqualStrings("y", t[1].value);
    }
}

test "trailers are borrowed from the caller's trailer_buf" {
    var h: Harness = undefined;
    var s = h.init(
        .whole,
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n0\r\nX-Sum: 42\r\n\r\n",
    );
    _ = (try s.receive()).?;
    var buf: [64]u8 = undefined;
    _ = try s.readBody(&buf);

    var storage: [8]scan.Header = undefined;
    const t = try s.trailers(&storage);
    // These live in the caller's Options buffer, not in a returned
    // frame.
    const base = @intFromPtr(&h.trailer_buf);
    try testing.expect(@intFromPtr(t[0].value.ptr) >= base);
    try testing.expect(@intFromPtr(t[0].value.ptr) < base + h.trailer_buf.len);

    try s.respond(.text(.ok, "done"));
    try testing.expectEqualStrings("42", t[0].value);
}

test "a trailer block bigger than storage is TooManyHeaders" {
    var h: Harness = undefined;
    var s = h.init(
        .whole,
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "0\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n",
    );
    _ = (try s.receive()).?;
    var buf: [64]u8 = undefined;
    _ = try s.readBody(&buf);

    var storage: [2]scan.Header = undefined;
    try testing.expectError(error.TooManyHeaders, s.trailers(&storage));
}

test "a refused Expect does not carry the last request's HEAD over" {
    var h: Harness = undefined;
    var s = h.init(
        .whole,
        "HEAD /a HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "POST /b HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\nExpect: something-else\r\n\r\nhi",
    );
    _ = (try s.receive()).?;
    try s.respond(.text(.ok, "twelve bytes"));

    try testing.expectError(error.UnsupportedExpectation, s.receive());

    // The 417 describes the rejected request, not the HEAD before it.
    try s.respond(.text(.expectation_failed, "no"));
    try testing.expect(std.mem.endsWith(u8, h.written(), "\r\n\r\nno"));
}

test "a second request before the first is answered is refused" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    const first = (try s.receive()).?;
    try testing.expectEqualStrings("/a", first.target());

    // Answering now would frame the response from /b, and the peer would
    // read it as the answer to /a.
    try testing.expectError(error.RequestUnanswered, s.receive());

    try s.respond(.{});
    const second = (try s.receive()).?;
    try testing.expectEqualStrings("/b", second.target());
}

test "what the request asked for outlives the 100 we sent" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\nhi");
        const req = (try s.receive()).?;
        try testing.expect(req.expectsContinue());

        var buf: [8]u8 = undefined;
        _ = try s.readBody(&buf);
        try testing.expect(std.mem.indexOf(u8, h.written(), "100 Continue") != null);

        try testing.expect(req.expectsContinue());
    }
}

test "a body can only be handed out once" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhelloGET /next HTTP/1.1\r\nHost: x\r\n\r\n");
        _ = (try s.receive()).?;

        var scratch: [16]u8 = undefined;
        var b = try s.bodyReader(&scratch);

        // The stream owns the body. A second way in would pick up where
        // the first one left off and read the next head as body.
        var buf: [64]u8 = undefined;
        try testing.expectError(error.BodyTaken, s.readBody(&buf));
        try testing.expectError(error.BodyTaken, s.bodyReader(&scratch));

        var sink: Io.Writer = .fixed(&buf);
        _ = try b.interface.streamRemaining(&sink);
        try testing.expectEqualStrings("hello", sink.buffered());

        try s.respond(.{});
        const next = (try s.receive()).?;
        try testing.expectEqualStrings("/next", next.target());
    }
}

test "reading the body twice is refused" {
    var h: Harness = undefined;
    var s = h.init(.whole, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    _ = (try s.receive()).?;

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hello", try s.readBody(&buf));
    try testing.expectError(error.BodyTaken, s.readBody(&buf));
}

test "a streamed body reaches the peer before it ends" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    var scratch: [64]u8 = undefined;
    var rw = try s.respondStreaming(.{}, &scratch, .{});

    try testing.expect(std.mem.endsWith(u8, h.written(), "\r\n\r\n"));

    try rw.interface.writeAll("event one");
    try rw.flush();
    try testing.expect(std.mem.endsWith(u8, h.written(), "9\r\nevent one\r\n"));

    try rw.interface.writeAll("event two");
    try rw.end();
    try testing.expect(std.mem.endsWith(u8, h.written(), "9\r\nevent two\r\n0\r\n\r\n"));
}

test "what a connection costs, apart from its buffers" {
    // Pinned, so if it grows you see it in a diff. Everything else a
    // connection uses is a buffer the caller sized.
    try testing.expectEqual(@as(usize, 248), @sizeOf(Server));
    try testing.expectEqual(@as(usize, 136), @sizeOf(HeadWindow));
    try testing.expectEqual(@as(usize, 88), @sizeOf(Request));
}

test "a splat through a streamed body" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    var scratch: [64]u8 = undefined;
    var rw = try s.respondStreaming(.{}, &scratch, .{});
    // Buffer something, then splat. `drain` reports what it took from
    // `data`, not what it flushed out of the buffer.
    try rw.interface.writeAll("hi");
    try rw.interface.splatByteAll('x', 100);
    try rw.end();

    const out = h.written();
    try testing.expect(std.mem.indexOf(u8, out, "2\r\nhi\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, out, "0\r\n\r\n"));
    var xs: usize = 0;
    for (out) |c| {
        if (c == 'x') xs += 1;
    }
    try testing.expectEqual(@as(usize, 100), xs);
}

test "a chunked body that does not fit ends the connection" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        // 16 bytes of body with a valid request behind it. Nothing should
        // be read from a position nobody can account for.
        var s = h.initDraining(
            shape,
            "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
                "10\r\nAAAAAAAAAAAAAAAA\r\n0\r\n\r\nGET /evil HTTP/1.1\r\nHost: x\r\n\r\n",
        );
        _ = (try s.receive()).?;

        var small: [4]u8 = undefined;
        try testing.expectError(error.BodyTooLarge, s.readBody(&small));

        // Nobody can say where that body ended, so we don't read any
        // further. A drain here could be talked into finding /evil.
        try testing.expect(!s.alive());
        try s.respond(.{ .status = .forError(error.BodyTooLarge), .keep_alive = false });
        try testing.expectEqual(@as(?Request, null), try s.receive());
    }
}

test "a HEAD drops trailers with the body it describes" {
    var h: Harness = undefined;
    var s = h.init(.whole, "HEAD / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    var scratch: [64]u8 = undefined;
    var rw = try s.respondStreaming(.{
        .headers = &.{.{ .name = "Trailer", .value = "X-Sum" }},
    }, &scratch, .{});
    try rw.interface.writeAll("not sent");
    try rw.endWithTrailers(&.{.{ .name = "X-Sum", .value = "42" }});
    try testing.expect(s.alive());

    const out = h.written();
    try testing.expect(std.mem.indexOf(u8, out, "not sent") == null);
    try testing.expect(std.mem.indexOf(u8, out, "X-Sum: 42") == null);
}

test "trailers on a counted body have nowhere to go" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    var scratch: [64]u8 = undefined;
    var rw = try s.respondStreaming(.{}, &scratch, .{ .content_length = 4 });
    try rw.interface.writeAll("body");
    try testing.expectError(error.InvalidTrailer, rw.endWithTrailers(&.{.{ .name = "X-Sum", .value = "42" }}));
}

test "a chunked body that exactly fits is not too large" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");
        _ = (try s.receive()).?;

        // 5 bytes of body, 5 bytes of buffer. The terminator is still
        // in the reader and is not body.
        var buf: [5]u8 = undefined;
        try testing.expectEqualStrings("hello", try s.readBody(&buf));
        try testing.expect(s.alive());
    }
}

test "a body left unfinished ends the connection, whatever stopped it" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.initDraining(
            shape,
            "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
                "10\r\nAAAAAAAAAAAAAAAA\r\n0\r\n\r\nGET /evil HTTP/1.1\r\nHost: x\r\n\r\n",
        );
        _ = (try s.receive()).?;

        var small: [4]u8 = undefined;
        var sink: Io.Writer = .fixed(&small);
        var scratch: [8]u8 = undefined;
        var b = try s.bodyReader(&scratch);

        try testing.expectError(error.WriteFailed, b.interface.streamRemaining(&sink));

        // The sink kept part of it and then failed, so the body is
        // broken and the request-shaped bytes behind it must not be
        // read.
        try testing.expectEqual(BodyError.SinkFailed, b.failure().?);
        try testing.expect(!s.alive());

        try s.respond(.{ .status = .forError(error.BodyTooLarge), .keep_alive = false });
        try testing.expectEqual(@as(?Request, null), try s.receive());
    }
}

test "every body reader needs somewhere to buffer" {
    // This is not only about chunked. The reader buffers into it
    // whatever the framing is, and an unbuffered `Io.Reader` panics
    // inside std on the first take.
    for ([_][]const u8{
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello",
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\n\r\n",
    }) |input| {
        var h: Harness = undefined;
        var s = h.init(.whole, input);
        _ = (try s.receive()).?;

        var one: [1]u8 = undefined;
        try testing.expectError(error.NoDecodeBuffer, s.bodyReader(&.{}));
        try testing.expectError(error.NoDecodeBuffer, s.bodyReader(&one));
    }
}

test "a counted body takes what it is given as buffer" {
    var h: Harness = undefined;
    var s = h.init(.whole, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    _ = (try s.receive()).?;

    var tiny: [2]u8 = undefined;
    var b = try s.bodyReader(&tiny);
    try testing.expectEqual(@as(u8, 'h'), try b.interface.takeByte());
    var out: [8]u8 = undefined;
    var sink: Io.Writer = .fixed(&out);
    _ = try b.interface.streamRemaining(&sink);
    try testing.expectEqualStrings("ello", sink.buffered());
}

test "an upgrade the writer cannot hold ends the connection" {
    var h: Harness = undefined;
    var s = h.initTight(
        .whole,
        "GET /ws HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nEARLYFRAME",
    );
    const req = (try s.receive()).?;
    try testing.expectEqualStrings("websocket", req.upgradeTo().?);

    // Half a 101 on the wire with the peer's first frame behind it.
    // Those bytes are not a request.
    try testing.expectError(error.WriteFailed, s.upgrade(.{ .status = .switching_protocols }));
    try testing.expect(!s.alive());
    try testing.expectEqual(@as(?Request, null), try s.receive());
}

test "answering settles the continue we owed" {
    var h: Harness = undefined;
    var s = h.init(.whole, "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\nhi");
    _ = (try s.receive()).?;

    try s.respond(.{ .status = .payload_too_large, .keep_alive = false });
    const after_answer = h.written().len;

    // A 100 now would be a second response after the first one.
    var buf: [8]u8 = undefined;
    _ = s.readBody(&buf) catch {};
    try testing.expectEqual(after_answer, h.written().len);
    try testing.expect(std.mem.indexOf(u8, h.written(), "100 Continue") == null);
}

test "no trailer_buf drops trailers rather than failing" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        // Nobody asked for room, so the trailers get dropped.
        var s = h.initWith(
            shape,
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\nX: y\r\n\r\n",
            .{ .keep_trailers = false },
        );
        _ = (try s.receive()).?;

        var buf: [8]u8 = undefined;
        try testing.expectEqualStrings("a", try s.readBody(&buf));

        var storage: [4]scan.Header = undefined;
        try testing.expectEqual(@as(usize, 0), (try s.trailers(&storage)).len);
        try testing.expect(s.alive());
    }
}

test "a body too large for the buffer may be asked for again" {
    var h: Harness = undefined;
    var s = h.init(.whole, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    _ = (try s.receive()).?;

    var small: [2]u8 = undefined;
    try testing.expectError(error.BodyTooLarge, s.readBody(&small));
    var big: [8]u8 = undefined;
    try testing.expectEqualStrings("hello", try s.readBody(&big));
}

test "a sink that kept some of it and then gave out breaks the body" {
    var h: Harness = undefined;
    var s = h.init(.whole, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n8\r\nabcdefgh\r\n0\r\n\r\n");
    _ = (try s.receive()).?;

    var small: [2]u8 = undefined;
    var sink: Io.Writer = .fixed(&small);
    var scratch: [8]u8 = undefined;
    var b = try s.bodyReader(&scratch);
    try testing.expectError(error.WriteFailed, b.interface.streamRemaining(&sink));

    // It kept "ab" and won't tell us, so the rest can't go anywhere
    // without sending those bytes twice.
    try testing.expectEqualStrings("ab", sink.buffered());
    try testing.expectEqual(BodyError.SinkFailed, b.failure().?);
    try testing.expect(!s.alive());
}

test "a counted body into a sink that gave out partway" {
    var h: Harness = undefined;
    var s = h.init(.whole, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\nabcdefgh");
    _ = (try s.receive()).?;

    var small: [2]u8 = undefined;
    var sink: Io.Writer = .fixed(&small);
    var scratch: [8]u8 = undefined;
    var b = try s.bodyReader(&scratch);
    try testing.expectError(error.WriteFailed, b.interface.streamRemaining(&sink));

    try testing.expectEqual(BodyError.SinkFailed, b.failure().?);
    try testing.expect(!s.alive());
}

/// An unbuffered destination that takes half of what it is offered and
/// then fails, like a socket that short-writes and then resets.
const HalfThenBroken = struct {
    interface: Io.Writer,
    kept: usize = 0,
    calls: usize = 0,

    fn init(p: *HalfThenBroken) void {
        p.* = .{ .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} } };
    }

    fn drain(io_w: *Io.Writer, data: []const []const u8, _: usize) Io.Writer.Error!usize {
        const p: *HalfThenBroken = @alignCast(@fieldParentPtr("interface", io_w));
        p.calls += 1;
        if (p.calls > 1) return error.WriteFailed;
        p.kept = data[0].len / 2;
        return p.kept;
    }
};

test "a sink with no buffer can still have kept a prefix" {
    for ([_][]const u8{
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\nabcdefgh",
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n8\r\nabcdefgh\r\n0\r\n\r\n",
    }) |input| {
        var h: Harness = undefined;
        var s = h.init(.whole, input);
        _ = (try s.receive()).?;

        var p: HalfThenBroken = undefined;
        p.init();
        var scratch: [16]u8 = undefined;
        var b = try s.bodyReader(&scratch);

        try testing.expectError(error.WriteFailed, b.interface.streamRemaining(&p.interface));

        // No buffer, but it took bytes on the write before the one that
        // failed. Those can't be sent twice.
        try testing.expect(p.kept != 0);
        try testing.expectEqual(BodyError.SinkFailed, b.failure().?);
        try testing.expect(!s.alive());
    }
}

test "a counted body into a sink that takes nothing" {
    var h: Harness = undefined;
    var s = h.init(.whole, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\nabcdefgh");
    _ = (try s.receive()).?;

    var scratch: [8]u8 = undefined;
    var b = try s.bodyReader(&scratch);

    var refuses: Io.Writer = .fixed(&.{});
    try testing.expectError(error.WriteFailed, b.interface.stream(&refuses, .unlimited));
    try testing.expectEqual(@as(?BodyError, null), b.failure());

    var out: [16]u8 = undefined;
    var sink: Io.Writer = .fixed(&out);
    _ = try b.interface.streamRemaining(&sink);
    try testing.expectEqualStrings("abcdefgh", sink.buffered());
}

test "a sink that takes nothing leaves the body where it was" {
    var h: Harness = undefined;
    var s = h.init(.whole, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n8\r\nAAAAAAAA\r\n0\r\n\r\n");
    _ = (try s.receive()).?;

    var scratch: [16]u8 = undefined;
    var b = try s.bodyReader(&scratch);

    // A writer that rejects everything, which is how std probes for a
    // delimiter. That call is supposed to leave no trace.
    var refuses: Io.Writer = .fixed(&.{});
    try testing.expectError(error.WriteFailed, b.interface.stream(&refuses, .unlimited));
    try testing.expectEqual(@as(?BodyError, null), b.failure());

    var out: [16]u8 = undefined;
    var sink: Io.Writer = .fixed(&out);
    _ = try b.interface.streamRemaining(&sink);
    try testing.expectEqualStrings("AAAAAAAA", sink.buffered());
    try testing.expect(s.alive());
}

test "looking for a delimiter that is not there leaves the body readable" {
    var h: Harness = undefined;
    var s = h.init(
        .whole,
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nc\r\nline one two\r\n0\r\n\r\n",
    );
    _ = (try s.receive()).?;

    var scratch: [16]u8 = undefined;
    var b = try s.bodyReader(&scratch);
    // No newline and no room to keep looking. std says StreamTooLong and
    // promises nothing was consumed.
    try testing.expectError(error.StreamTooLong, b.interface.takeDelimiterInclusive('\n'));

    var out: [16]u8 = undefined;
    var sink: Io.Writer = .fixed(&out);
    _ = try b.interface.streamRemaining(&sink);
    try testing.expectEqualStrings("line one two", sink.buffered());
}

test "a body read partway cannot be drained past" {
    var h: Harness = undefined;
    // A 0x20-byte chunk whose contents look like the end of a body
    // followed by another request.
    var s = h.initDraining(.whole, "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "20\r\nAAAA0\r\n\r\nGET /evil HTTP/1.1\r\nHost: x\r\n\r\nA\r\n0\r\n\r\n");
    _ = (try s.receive()).?;

    var out: [64]u8 = undefined;
    var sink: Io.Writer = .fixed(&out);
    var scratch: [4]u8 = undefined;
    var b = try s.bodyReader(&scratch);
    // The caller reads a few bytes and stops, the way a handler deciding
    // whether to carry on would.
    _ = try b.interface.stream(&sink, .unlimited);

    try s.respond(.{});
    // Nobody can say where that body ends. The reader is in the middle
    // of a chunk and the decoder belongs to `b`.
    try testing.expect(!s.alive());
    try testing.expectEqual(@as(?Request, null), try s.receive());
}

test "a counted body read partway is not discarded by its old length" {
    var h: Harness = undefined;
    var s = h.initDraining(
        .whole,
        "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n0123456789GET /b HTTP/1.1\r\nHost: x\r\n\r\n",
    );
    _ = (try s.receive()).?;

    var out: [4]u8 = undefined;
    var sink: Io.Writer = .fixed(&out);
    var decode: [16]u8 = undefined;
    var b = try s.bodyReader(&decode);
    _ = try b.interface.stream(&sink, .limited(4));

    try s.respond(.{});
    // Discarding all ten would eat 6 bytes of body and 4 bytes of the
    // next request.
    try testing.expect(!s.alive());
    try testing.expectEqual(@as(?Request, null), try s.receive());
}

test "a body read to its end still leaves the connection usable" {
    var h: Harness = undefined;
    var s = h.init(.whole, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhelloGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    var out: [8]u8 = undefined;
    var sink: Io.Writer = .fixed(&out);
    var decode: [16]u8 = undefined;
    var b = try s.bodyReader(&decode);
    _ = try b.interface.streamRemaining(&sink);
    try testing.expectEqualStrings("hello", sink.buffered());

    try s.respond(.{});
    try testing.expect(s.alive());
    const second = (try s.receive()).?;
    try testing.expectEqualStrings("/b", second.target());
}

test "the body reader works with buffered reader calls" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nc\r\nline\none\ntwo\r\n0\r\n\r\n");
        _ = (try s.receive()).?;

        var scratch: [64]u8 = undefined;
        var b = try s.bodyReader(&scratch);
        try testing.expectEqual(@as(u8, 'l'), try b.interface.takeByte());
        try testing.expectEqualStrings("ine\n", try b.interface.takeDelimiterInclusive('\n'));

        var rest: [16]u8 = undefined;
        var sink: Io.Writer = .fixed(&rest);
        _ = try b.interface.streamRemaining(&sink);
        try testing.expectEqualStrings("one\ntwo", sink.buffered());
    }
}

test "a chunked body streamed in small bites" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
        _ = (try s.receive()).?;

        var scratch: [8]u8 = undefined;
        var b = try s.bodyReader(&scratch);

        // One byte per call still gets somewhere, because the decoder
        // consumes source even when the destination takes almost
        // nothing.
        var out: [32]u8 = undefined;
        var sink: Io.Writer = .fixed(&out);
        while (true) {
            const n = b.interface.stream(&sink, .limited(1)) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            _ = n;
        }
        try testing.expectEqualStrings("hello world", sink.buffered());
    }
}

test "a streamed response cannot contradict its own head" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    // A caller-supplied length with a chunked writer. The peer would
    // read 5 bytes of chunk header as the whole body.
    var scratch: [64]u8 = undefined;
    try testing.expectError(error.AmbiguousFraming, s.respondStreaming(.{
        .headers = &.{.{ .name = "Content-Length", .value = "5" }},
    }, &scratch, .{}));

    // Rejected before any byte went out and before the request counts as
    // answered, so the handler can still answer properly.
    try testing.expectEqualStrings("", h.written());
    try s.respond(.text(.internal_server_error, "sorry"));
    try testing.expect(std.mem.endsWith(u8, h.written(), "sorry"));
}

test "a response refused before it is written leaves the request answerable" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    try testing.expectError(error.InvalidHeader, s.respond(.{
        .headers = &.{.{ .name = "X", .value = "a\r\nY: 2" }},
    }));
    try testing.expectEqualStrings("", h.written());
    try testing.expect(s.alive());

    try s.respond(.text(.ok, "second thoughts"));
    try testing.expect(std.mem.endsWith(u8, h.written(), "second thoughts"));
}

test "a 101 refused before the handover leaves the request answerable" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET /ws HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n");
    _ = (try s.receive()).?;

    try testing.expectError(error.InvalidHeader, s.upgrade(.{
        .status = .switching_protocols,
        .headers = &.{.{ .name = "X", .value = "a\r\nY: 2" }},
    }));
    try testing.expectEqualStrings("", h.written());
    try testing.expect(!s.handedOver());

    try s.respond(.text(.bad_request, "no"));
    try testing.expect(std.mem.endsWith(u8, h.written(), "no"));
}

test "a response with no request in hand says the connection is over" {
    for ([_]bool{ false, true }) |streamed| {
        var h: Harness = undefined;
        // Nothing received. This is the accept loop answering 503 before
        // it reads anything.
        var s = h.init(.whole, "");

        if (streamed) {
            var scratch: [64]u8 = undefined;
            var rw = try s.respondStreaming(.{ .status = .service_unavailable }, &scratch, .{});
            try rw.interface.writeAll("busy");
            try rw.end();
        } else {
            try s.respond(.text(.service_unavailable, "busy"));
        }

        // Nothing left to keep the connection for, and the head has to
        // say so instead of leaving the peer waiting.
        try testing.expect(!s.alive());
        try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") != null);
    }
}

test "a successful CONNECT gets no body and is handed over" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "CONNECT example.com:443 HTTP/1.1\r\nHost: x\r\n\r\n");
        _ = (try s.receive()).?;

        try s.respond(.text(.ok, "not a body"));
        const out = h.written();

        // No body and no framing headers. An intermediary that honours
        // a Content-Length here would read tunnel bytes as message
        // bytes.
        try testing.expect(std.mem.indexOf(u8, out, "not a body") == null);
        try testing.expect(std.mem.indexOf(u8, out, "Content-Length") == null);
        try testing.expect(std.mem.indexOf(u8, out, "Transfer-Encoding") == null);
        try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n"));

        try testing.expect(s.handedOver());
        try testing.expect(!s.alive());
        try testing.expectEqual(@as(?Request, null), try s.receive());
    }
}

test "a HEAD still describes the body it does not send" {
    var h: Harness = undefined;
    var s = h.init(.whole, "HEAD / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    try s.respond(.text(.ok, "twelve bytes"));
    const out = h.written();
    try testing.expect(std.mem.indexOf(u8, out, "Content-Length: 12") != null);
    try testing.expect(std.mem.indexOf(u8, out, "twelve bytes") == null);
}

test "a tunnel has no body to stream" {
    var h: Harness = undefined;
    var s = h.init(.whole, "CONNECT example.com:443 HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    // A tunnel has no body to stream. The answer goes out in one piece.
    var scratch: [64]u8 = undefined;
    try testing.expectError(error.NoBodyToStream, s.respondStreaming(.{ .status = .ok }, &scratch, .{}));
    try testing.expectEqualStrings("", h.written());

    try s.respond(.{ .status = .ok });
    try testing.expect(s.handedOver());
}

test "the handover follows the same rule" {
    var h: Harness = undefined;
    var s = h.init(.whole, "CONNECT example.com:443 HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    try s.upgrade(.{ .status = .ok, .body = "not a body" });
    const out = h.written();
    try testing.expect(std.mem.indexOf(u8, out, "not a body") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Content-Length") == null);
    try testing.expect(s.handedOver());
}

test "a CONNECT that failed answers like anything else" {
    var h: Harness = undefined;
    var s = h.init(.whole, "CONNECT example.com:443 HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    try s.respond(.text(.forbidden, "no tunnels here"));
    try testing.expect(std.mem.endsWith(u8, h.written(), "no tunnels here"));
}

test "a status the Scanner could not read back is not written" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    // Three digits and a space is what `scan.response` accepts.
    try testing.expectError(error.AmbiguousFraming, s.respond(.{ .status = @enumFromInt(7) }));
    try testing.expectError(error.AmbiguousFraming, s.respond(.{ .status = @enumFromInt(1000) }));
    try testing.expectEqualStrings("", h.written());

    try s.respond(.{ .status = @enumFromInt(599) });
    try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 599 "));
}

test "no trailers is an empty slice" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\n\r\n");
        _ = (try s.receive()).?;
        var buf: [64]u8 = undefined;
        _ = try s.readBody(&buf);
        var storage: [8]scan.Header = undefined;
        try testing.expectEqual(@as(usize, 0), (try s.trailers(&storage)).len);
    }
}

test "writing trailers on a streamed response" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    var scratch: [64]u8 = undefined;
    var rw = try s.respondStreaming(.{
        .headers = &.{.{ .name = "Trailer", .value = "X-Sum" }},
    }, &scratch, .{});
    try rw.interface.writeAll("body");
    try rw.endWithTrailers(&.{.{ .name = "X-Sum", .value = "42" }});

    try testing.expect(std.mem.endsWith(u8, h.written(), "4\r\nbody\r\n0\r\nX-Sum: 42\r\n\r\n"));
}

test "a trailer that would change the framing is refused" {
    for ([_][]const u8{ "Content-Length", "Transfer-Encoding", "Connection", "Host" }) |name| {
        var h: Harness = undefined;
        var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
        _ = (try s.receive()).?;

        var scratch: [64]u8 = undefined;
        var rw = try s.respondStreaming(.{}, &scratch, .{});
        try rw.interface.writeAll("body");
        try testing.expectError(
            error.InvalidTrailer,
            rw.endWithTrailers(&.{.{ .name = name, .value = "1" }}),
        );

        // Rejected before the terminator, so the body is unfinished and
        // the connection goes.
        try testing.expect(!std.mem.endsWith(u8, h.written(), "0\r\n\r\n"));
        try testing.expect(!s.alive());
    }
}

test "a refused trailer leaves the writer finished" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    var scratch: [64]u8 = undefined;
    var rw = try s.respondStreaming(.{}, &scratch, .{});
    try rw.interface.writeAll("body");
    try testing.expectError(error.InvalidTrailer, rw.endWithTrailers(&.{.{ .name = "Host", .value = "1" }}));

    const after_first = h.written().len;
    try testing.expectError(error.Finished, rw.end());
    try testing.expectEqual(after_first, h.written().len);
}

test "a second request is refused while a streamed response is open" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    var scratch: [64]u8 = undefined;
    var rw = try s.respondStreaming(.{}, &scratch, .{});
    try rw.interface.writeAll("first");

    try testing.expectError(error.ResponseOpen, s.receive());
    try testing.expectError(error.AlreadyAnswered, s.respond(.text(.ok, "second")));
    try testing.expect(!s.alive());

    try rw.end();
    const second = (try s.receive()).?;
    try testing.expectEqualStrings("/b", second.target());
}

test "end after an overrun is refused" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    var scratch: [4]u8 = undefined;
    var rw = try s.respondStreaming(.{}, &scratch, .{ .content_length = 4 });
    // Going past the end comes back as WriteFailed, the only error an
    // `Io.Writer` has.
    try testing.expectError(error.WriteFailed, rw.interface.writeAll("far too much"));
    try testing.expect(!s.alive());
    try testing.expectError(error.Finished, rw.end());
}

test "a Date header by default" {
    var h: Harness = undefined;
    h.writer = .fixed(&h.out);
    var s = try Server.init(testing.io, h.source.reader(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n"), &h.writer, .{
        .headers = &h.headers,
    });
    _ = (try s.receive()).?;
    try s.respond(.text(.ok, "hi"));

    const out = h.written();
    const at = std.mem.indexOf(u8, out, "Date: ").?;
    try testing.expectEqualStrings(" GMT\r\n", out[at + 6 + 25 ..][0..6]);
}

test "no Date when it is turned off" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;
    try s.respond(.text(.ok, "hi"));
    try testing.expect(std.mem.indexOf(u8, h.written(), "Date:") == null);
}

test "a caller's own Date is left alone" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    s.date = .{};
    _ = (try s.receive()).?;
    try s.respond(.{
        .headers = &.{.{ .name = "Date", .value = "Sun, 06 Nov 1994 08:49:37 GMT" }},
    });
    const out = h.written();
    try testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", out[std.mem.indexOf(u8, out, "Date: ").? + 6 ..][0..29]);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOfPos(u8, out, std.mem.indexOf(u8, out, "Date:").? + 1, "Date:"));
}

test "a streamed response gets a Date too" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    s.date = .{};
    _ = (try s.receive()).?;

    var scratch: [64]u8 = undefined;
    var rw = try s.respondStreaming(.{}, &scratch, .{});
    try rw.interface.writeAll("x");
    try rw.end();

    const out = h.written();
    try testing.expect(std.mem.indexOf(u8, out, "Date: ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Transfer-Encoding: chunked") != null);
}

test "a head sent together with a body that fills the buffer" {
    // No Expect, so the client sends it all at once and the read buffer
    // fills up with a head that is perfectly fine.
    const body_len = 4000;
    var input: [4200]u8 = undefined;
    var w: Io.Writer = .fixed(&input);
    try w.print("POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n", .{body_len});
    try w.splatByteAll('x', body_len);

    var buf: [512]u8 = undefined;
    var src: std.testing.Reader = .init(&buf, &.{.{ .buffer = w.buffered() }});
    var out: [512]u8 = undefined;
    var ow: Io.Writer = .fixed(&out);
    var headers: [8]scan.Header = undefined;
    var head_buf: [512]u8 = undefined;
    var s: Server = try .init(testing.io, &src.interface, &ow, .{
        .headers = &headers,
        .head_buf = &head_buf,
    });

    const req = (try s.receive()).?;
    try testing.expectEqualStrings("/upload", req.target());

    var sink: [64]u8 = undefined;
    var scratch: [64]u8 = undefined;
    var counter: Io.Writer.Discarding = .init(&sink);
    var b = try s.bodyReader(&scratch);
    _ = try b.interface.streamRemaining(&counter.writer);
    try testing.expectEqual(@as(u64, body_len), counter.count + counter.writer.end);
}

test "a head that genuinely does not fit is still refused" {
    const long = "GET / HTTP/1.1\r\nHost: x\r\n" ++ ("X-Padding-Header: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n" ** 40) ++ "\r\n";
    var buf: [256]u8 = undefined;
    var src: std.testing.Reader = .init(&buf, &.{.{ .buffer = long }});
    var out: [256]u8 = undefined;
    var ow: Io.Writer = .fixed(&out);
    var headers: [64]scan.Header = undefined;
    var s: Server = try .init(testing.io, &src.interface, &ow, .{ .headers = &headers });
    try testing.expectError(error.HeadTooLarge, s.receive());
}

test "an unread body is never scanned as the next request" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        // Bigger than any sink the drain might use, and made of token
        // characters so a scanner reading it finds a request line.
        const stuffing = "x" ** 600;
        var s = h.init(shape, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 600\r\n\r\n" ++
            stuffing ++ "GET /b HTTP/1.1\r\nHost: x\r\n\r\n");

        const first = (try s.receive()).?;
        try testing.expectEqualStrings("/a", first.target());

        try s.respond(.{ .status = .unauthorized });

        // The harness turns draining off, so there is a body here nobody
        // will read, and the window says so before anyone asks it to
        // scan.
        try testing.expect(!s.alive());
        try testing.expectEqual(@as(?Request, null), try s.receive());
    }
}

test "a response the writer cannot hold ends the connection" {
    var h: Harness = undefined;
    var s = h.initTight(.whole, "GET /hi HTTP/1.1\r\nHost: x\r\n\r\nGET /next HTTP/1.1\r\nHost: x\r\n\r\n");

    const req = (try s.receive()).?;
    try testing.expectEqualStrings("/hi", req.target());

    // 16 bytes of room and a longer status line. Part of a head is on
    // the wire and can't be taken back.
    try testing.expectError(error.WriteFailed, s.respond(Response.text(.ok, "yes")));
    try testing.expect(!s.alive());
    try testing.expectError(error.AlreadyAnswered, s.respond(.{}));
    try testing.expectEqual(@as(?Request, null), try s.receive());
}

test "a streamed head the writer cannot hold ends the connection" {
    var h: Harness = undefined;
    var s = h.initTight(.whole, "GET /hi HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    var scratch: [32]u8 = undefined;
    try testing.expectError(error.WriteFailed, s.respondStreaming(.{}, &scratch, .{}));
    try testing.expect(!s.alive());
}

test "a 100 Continue that cannot be written ends the connection" {
    var h: Harness = undefined;
    var s = h.initTight(
        .whole,
        "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\nhi",
    );
    _ = (try s.receive()).?;

    var buf: [8]u8 = undefined;
    try testing.expectError(error.WriteFailed, s.readBody(&buf));
    try testing.expect(!s.alive());
}

test "a response with more headers than the old splice buffer held" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    s.date = .{};

    var many: [40]Response.Header = undefined;
    for (&many, 0..) |*f, i| {
        _ = i;
        f.* = .{ .name = "X-Pad", .value = "1" };
    }

    _ = (try s.receive()).?;
    // This used to be error.WriteFailed at 32 or more.
    try s.respond(.{ .status = .ok, .headers = &many, .body = "hi" });

    const out = h.written();
    try testing.expect(std.mem.indexOf(u8, out, "Date: ") != null);
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, "X-Pad: 1")) |at| : (i = at + 1) count += 1;
    try testing.expectEqual(@as(usize, 40), count);
}

test "one request gets one response" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");

    _ = (try s.receive()).?;
    try s.respond(.text(.ok, "first"));
    // A second response gets read as the answer to a request the peer
    // never sent, and then the connection is out of step.
    try testing.expectError(error.AlreadyAnswered, s.respond(.text(.ok, "second")));
    try testing.expect(std.mem.indexOf(u8, h.written(), "second") == null);
}

test "a response written with no request in hand forgets the last one" {
    var h: Harness = undefined;
    var s = h.init(.whole, "HEAD / HTTP/1.1\r\nHost: x\r\n\r\n" ++ "!!! bad\r\n\r\n");

    _ = (try s.receive()).?;
    try s.respond(.text(.ok, "dropped for HEAD"));
    try testing.expect(std.mem.indexOf(u8, h.written(), "dropped for HEAD") == null);

    try testing.expectError(error.BadRequest, s.receive());

    // This is not the answer to a HEAD, so it keeps its body, and it
    // closes because there is nothing left to keep the connection for.
    try s.respond(.text(.bad_request, "explanation"));
    const out = h.written();
    try testing.expect(std.mem.indexOf(u8, out, "explanation") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Connection: close") != null);
    try testing.expect(!s.alive());
}

test "a head_buf that cannot hold what the reader can is refused at init" {
    var read_buf: [4096]u8 = undefined;
    var src: std.testing.Reader = .init(&read_buf, &.{});
    var out: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var headers: [8]scan.Header = undefined;
    var head_buf: [128]u8 = undefined;

    // A head between 128 and 4096 bytes scans fine and then has nowhere
    // to live once a body turns up behind it.
    try testing.expectError(error.HeadBufferTooSmall, Server.init(testing.io, &src.interface, &w, .{
        .headers = &headers,
        .head_buf = &head_buf,
    }));

    _ = try Server.init(testing.io, &src.interface, &w, .{ .headers = &headers });
}

test "a peer that went quiet is told apart from one that went away" {
    var out: [64]u8 = undefined;
    var headers: [8]scan.Header = undefined;

    for ([_]anyerror{ error.Timeout, error.ConnectionResetByPeer, error.Canceled }) |why| {
        var f: arrival.Failing = .{ .why = why };
        f.init();
        var w: Io.Writer = .fixed(&out);
        var s = try Server.init(testing.io, &f.interface, &w, .{
            .headers = &headers,
            .failure = f.source(),
        });
        try testing.expectError(switch (why) {
            error.Timeout => error.Timeout,
            error.Canceled => error.Canceled,
            else => error.ReadFailed,
        }, s.receive());
    }

    // With no failure source there is nobody to ask, so it stays a read
    // that didn't say why.
    var f: arrival.Failing = .{};
    f.init();
    var w: Io.Writer = .fixed(&out);
    var s = try Server.init(testing.io, &f.interface, &w, .{ .headers = &headers });
    try testing.expectError(error.ReadFailed, s.receive());
}

test "a body read that was canceled says so" {
    var out: [64]u8 = undefined;
    var headers: [8]scan.Header = undefined;
    var head_buf: [64]u8 = undefined;

    for ([_]bool{ false, true }) |stream| {
        var f: arrival.Failing = .{
            .why = error.Canceled,
            .first = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nabc",
        };
        f.init();
        var w: Io.Writer = .fixed(&out);
        var s = try Server.init(testing.io, &f.interface, &w, .{
            .headers = &headers,
            .head_buf = &head_buf,
            .failure = f.source(),
        });
        _ = (try s.receive()).?;
        var buf: [16]u8 = undefined;
        if (stream) {
            var b = try s.bodyReader(&buf);
            var sink: [16]u8 = undefined;
            try testing.expectError(error.ReadFailed, b.interface.readSliceAll(&sink));
            try testing.expectEqual(@as(?BodyError, error.Canceled), b.failure());
        } else {
            try testing.expectError(error.Canceled, s.readBody(&buf));
        }
    }
}

test "the body's length is knowable before reading it" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");

        const req = (try s.receive()).?;
        try testing.expectEqual(@as(?u64, 5), req.contentLength());
        try testing.expect(req.hasBody());

        // Knowing the length lets you size the buffer for this body
        // instead of the biggest one you would accept.
        var exact: [5]u8 = undefined;
        const n: usize = @intCast(req.contentLength().?);
        try testing.expectEqualStrings("hello", try s.readBody(exact[0..n]));
    }
}

test "a chunked body has no length to report" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n0\r\n\r\n");

        const req = (try s.receive()).?;
        try testing.expectEqual(@as(?u64, null), req.contentLength());
        try testing.expect(req.hasBody());
    }
}

test "a request with no body reports neither" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET /a HTTP/1.1\r\nHost: x\r\n\r\n");

        const req = (try s.receive()).?;
        try testing.expectEqual(@as(?u64, null), req.contentLength());
        try testing.expect(!req.hasBody());
    }
}

test "an upgrade with the request body still in the way" {
    const input = "POST /ws HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: h2c\r\nContent-Length: 5\r\n\r\nhelloFRAME";
    const switching: Response = .{
        .status = .switching_protocols,
        .headers = &.{ .{ .name = "Upgrade", .value = "h2c" }, .{ .name = "Connection", .value = "Upgrade" } },
    };
    for (shapes) |shape| {
        // Nothing to drain with. The 101 doesn't go out, and the request
        // can still be answered, on a connection that then closes.
        var h: Harness = undefined;
        var s = h.init(shape, input);
        _ = (try s.receive()).?;
        try testing.expectError(error.BodyPending, s.upgrade(switching));
        try testing.expectEqualStrings("", h.written());
        try testing.expect(!s.handedOver());
        try s.respond(.text(.bad_request, "no"));
        try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") != null);
        try testing.expect(!s.alive());

        // With a budget the body is drained, and the next protocol
        // starts after it.
        s = h.initDraining(shape, input);
        _ = (try s.receive()).?;
        try s.upgrade(switching);
        var rest: [16]u8 = undefined;
        const n = try s.window.reader.readSliceShort(&rest);
        try testing.expectEqualStrings("FRAME", rest[0..n]);
    }
}

test "an upgrade needs a status that switches" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET /ws HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n");
    _ = (try s.receive()).?;

    try testing.expectError(error.NotSwitching, s.upgrade(.{ .status = .ok }));
    try testing.expectEqualStrings("", h.written());
    try s.respond(.text(.bad_request, "no"));
    try testing.expect(!s.handedOver());
}

test "a 101 through respond hands the connection over too" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET /ws HTTP/1.1\r\nHost: x\r\nConnection: Upgrade, close\r\nUpgrade: websocket\r\n\r\n");
    _ = (try s.receive()).?;

    try s.respond(.{ .status = .switching_protocols });
    try testing.expect(s.handedOver());
    // The connection is changing hands, so it doesn't say close.
    try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") == null);
}

test "no 100 Continue before a read that is going to be refused" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello");
        _ = (try s.receive()).?;

        var small: [2]u8 = undefined;
        try testing.expectError(error.BodyTooLarge, s.readBody(&small));
        try testing.expectError(error.NoDecodeBuffer, s.bodyReader(small[0..1]));
        try testing.expectEqualStrings("", h.written());

        var buf: [8]u8 = undefined;
        try testing.expectEqualStrings("hello", try s.readBody(&buf));
        try testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", h.written());
    }
}

test "every error a server hands you has a status on purpose" {
    // `forError` falls back to 500 for anything it doesn't know. That is
    // the right answer for most of these, but it should be a decision,
    // so a new error fails here until it gets a line in `named`.
    const sets = .{ ReceiveError, ReadBodyError, HeadWindow.BodyReaderError, UpgradeError, StreamError, BodyWriter.EndError, serve_mod.Error };
    inline for (sets) |Set| {
        inline for (@typeInfo(Set).error_set.?) |e| {
            if (Response.Status.named(@field(anyerror, e.name)) == null) {
                std.debug.print("error.{s} has no status in Status.named\n", .{e.name});
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "a Connection: close the caller wrote ends the connection and goes out once" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    try s.respond(.{ .headers = &.{.{ .name = "Connection", .value = "close" }} });
    try testing.expect(!s.alive());
    try testing.expectEqual(@as(?Request, null), try s.receive());
    const out = h.written();
    const first = std.mem.indexOf(u8, out, "Connection: close").?;
    try testing.expect(std.mem.indexOf(u8, out[first + 1 ..], "Connection: close") == null);
}

test "an unread body the drain won't take makes the response say close" {
    const input = "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhelloGET /b HTTP/1.1\r\nHost: x\r\n\r\n";
    for (shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, input);
        _ = (try s.receive()).?;
        try s.respond(.text(.payload_too_large, "no"));
        try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") != null);
        try testing.expect(!s.alive());

        // Read first, and the connection carries on.
        s = h.init(shape, input);
        _ = (try s.receive()).?;
        var buf: [8]u8 = undefined;
        _ = try s.readBody(&buf);
        try s.respond(.text(.ok, "yes"));
        try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") == null);
        try testing.expectEqualStrings("/b", (try s.receive()).?.target());

        // The same if the drain can take it.
        s = h.initDraining(shape, input);
        _ = (try s.receive()).?;
        try s.respond(.text(.ok, "yes"));
        try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") == null);
        try testing.expectEqualStrings("/b", (try s.receive()).?.target());
    }
}

test "a body being streamed back doesn't make the response say close" {
    var h: Harness = undefined;
    var s = h.init(.whole, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    _ = (try s.receive()).?;

    var decode: [64]u8 = undefined;
    var b = try s.bodyReader(&decode);
    var scratch: [64]u8 = undefined;
    var rw = try s.respondStreaming(.{}, &scratch, .{});
    _ = try b.interface.streamRemaining(&rw.interface);
    try rw.end();
    try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") == null);
    try testing.expect(s.alive());
}

test "a 103 goes out ahead of the real response" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        // Asking to close doesn't stop the real response coming after
        // the hint.
        var s = h.init(shape, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        _ = (try s.receive()).?;

        var scratch: [64]u8 = undefined;
        try testing.expectError(error.NoBodyToStream, s.respondStreaming(.{ .status = .early_hints }, &scratch, .{}));
        try s.respond(.{
            .status = .early_hints,
            .headers = &.{.{ .name = "Link", .value = "</style.css>; rel=preload" }},
        });
        try s.respond(.text(.ok, "hi"));

        try testing.expectEqualStrings(
            "HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n" ++
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi",
            h.written(),
        );
        try testing.expectError(error.AlreadyAnswered, s.respond(.{}));
    }
}

test "a 100 sent by hand is the one we owed" {
    var h: Harness = undefined;
    var s = h.init(.whole, "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\nhi");
    _ = (try s.receive()).?;

    try s.respond(.{ .status = .@"continue" });
    var buf: [8]u8 = undefined;
    _ = try s.readBody(&buf);
    try s.respond(.{});
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, h.written(), "100 Continue"));
}

test "an unread body is drained by default" {
    var h: Harness = undefined;
    h.writer = .fixed(&h.out);
    var s = try Server.init(testing.io, h.source.reader(.whole, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello" ++
        "GET /b HTTP/1.1\r\nHost: x\r\n\r\n"), &h.writer, .{
        .headers = &h.headers,
        .head_buf = &h.head_buf,
    });
    _ = (try s.receive()).?;
    try s.respond(.{ .status = .unauthorized });
    try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") == null);
    try testing.expectEqualStrings("/b", (try s.receive()).?.target());
}

test "setMaxDrain lasts for one request" {
    for (shapes) |shape| {
        var h: Harness = undefined;
        const post = "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello";
        var s = h.init(shape, post ++ post);

        _ = (try s.receive()).?;
        s.setMaxDrain(1024);
        try s.respond(.{});
        try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") == null);

        // The harness has no drain, and that is back for this one.
        _ = (try s.receive()).?;
        try s.respond(.{});
        try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") != null);
        try testing.expect(!s.alive());
    }
}

test "last says what went out" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\nHEAD / HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expectEqual(@as(?Sent, null), s.last);

    _ = (try s.receive()).?;
    try s.respond(.{ .status = .early_hints });
    try testing.expectEqual(@as(?Sent, null), s.last);
    try s.respond(.text(.not_found, "nope"));
    try testing.expectEqual(Sent{ .status = .not_found, .body_bytes = 4, .complete = true }, s.last.?);

    _ = (try s.receive()).?;
    try testing.expectEqual(@as(?Sent, null), s.last);
    try s.respond(.text(.ok, "hello"));
    try testing.expectEqual(Sent{ .status = .ok, .body_bytes = 0, .complete = true }, s.last.?);
}

test "last follows a streamed body" {
    for ([_]?u64{ null, 7 }) |length| {
        var h: Harness = undefined;
        var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
        _ = (try s.receive()).?;

        var scratch: [4]u8 = undefined;
        var rw = try s.respondStreaming(.{}, &scratch, .{ .content_length = length });
        try testing.expectEqual(Sent{ .status = .ok }, s.last.?);
        try rw.interface.writeAll("abcdefg");
        try rw.end();
        try testing.expectEqual(Sent{ .status = .ok, .body_bytes = 7, .complete = true }, s.last.?);
    }
}

test "last says a streamed body broke" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;

    var scratch: [4]u8 = undefined;
    var rw = try s.respondStreaming(.{}, &scratch, .{ .content_length = 3 });
    try testing.expectError(error.LengthMismatch, rw.end());
    try testing.expectEqual(Sent{ .status = .ok, .body_bytes = 0, .complete = false }, s.last.?);
}

test "json with headers of your own" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;
    var r: Response = .json(.ok, "{}");
    r.headers = &.{.{ .name = "Set-Cookie", .value = "a=1" }};
    try s.respond(r);
    const out = h.written();
    try testing.expect(std.mem.indexOf(u8, out, "\r\nContent-Type: application/json\r\nSet-Cookie: a=1\r\n") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "Content-Type"));
}

test "a Content-Type in both places is refused" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;
    var r: Response = .json(.ok, "{}");
    r.headers = &.{.{ .name = "content-type", .value = "text/plain" }};
    try testing.expectError(error.InvalidHeader, s.respond(r));
    try testing.expectEqualStrings("", h.written());
    // Nothing went out, so the request can still be answered.
    try s.respond(.json(.ok, "{}"));
}

test "a Content-Type the Scanner would reject is refused" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = (try s.receive()).?;
    try testing.expectError(error.InvalidHeader, s.respond(.{ .content_type = "text/plain\r\nX: y" }));
    try testing.expectEqualStrings("", h.written());
}

test "a target that doesn't parse is refused" {
    const bad = [_][]const u8{
        "GET a/b HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET ://x/ HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET http:///x HTTP/1.1\r\nHost: x\r\n\r\n",
        "CONNECT a:1/x HTTP/1.1\r\nHost: x\r\n\r\n",
    };
    for (shapes) |shape| for (bad) |input| {
        var h: Harness = undefined;
        var s = h.init(shape, input);
        try testing.expectError(error.BadRequest, s.receive());
    };

    const good = [_][]const u8{
        "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
        "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n",
        "CONNECT a:443 HTTP/1.1\r\nHost: a:443\r\n\r\n",
        "GET http://a/x?q HTTP/1.1\r\nHost: a\r\n\r\n",
    };
    for (shapes) |shape| for (good) |input| {
        var h: Harness = undefined;
        var s = h.init(shape, input);
        _ = (try s.receive()).?.parsedTarget();
    };
}
