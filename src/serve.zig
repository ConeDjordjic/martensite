//! The loop for one connection: receive, hand the request over, repeat.
//!
//! It only does the protocol part that every server repeats. There is
//! no routing. The handler has `handle`, and optionally `onError` and
//! `onReceiveError` for the responses the loop would otherwise write
//! itself. Anything more belongs in whatever you build on top. If you
//! need something it doesn't do, write the loop yourself. You lose
//! nothing but the convenience.

const std = @import("std");
const Io = std.Io;

const Server = @import("Server.zig");
const Response = @import("Response.zig");

/// Sets a read deadline on whatever reader the Server was given.
/// `TimedReader.deadlines()` gives you one.
///
/// This exists so the loop can time things without the Server knowing
/// what kind of reader it has, the same as `FailureSource`.
pub const Deadline = struct {
    ctx: *anyopaque,
    start: *const fn (*anyopaque, Io.Timeout) void,
};

pub const Options = struct {
    /// Without one nothing is timed, and a quiet peer holds the
    /// connection for as long as it likes.
    deadline: ?Deadline = null,
    /// Waiting for the next request and reading its head.
    head: Io.Timeout = .none,
    /// The handler's time, once the head is in. Reading the body counts.
    body: Io.Timeout = .none,
};

pub const Error = error{
    /// The handler returned without answering. The peer got a 500.
    NoResponse,
    /// The handler returned with a streamed response still open. The
    /// connection ends, because the body can't be finished for it.
    ResponseOpen,
};

/// Everything `serve` can return: what `receive` can fail with, the
/// errors of `handle`, `onError` and `onReceiveError`, and `Error`.
pub fn ServeError(comptime Handler: type) type {
    const T = Child(Handler);
    checkHooks(T);
    comptime var E = Server.ReceiveError || Error || ErrorSet(T.handle);
    if (@hasDecl(T, "onError")) E = E || ErrorSet(T.onError);
    if (@hasDecl(T, "onReceiveError")) E = E || ErrorSet(T.onReceiveError);
    return E;
}

/// Hooks are found by name, so a misspelled one would be skipped without
/// a word. Anything public named like a hook has to be one.
fn checkHooks(comptime T: type) void {
    if (!@hasDecl(T, "handle")) @compileError(@typeName(T) ++ " has no handle");
    const decls = switch (@typeInfo(T)) {
        inline .@"struct", .@"union", .@"enum", .@"opaque" => |info| info.decls,
        else => return,
    };
    for (decls) |d| {
        const hook = d.name.len > 2 and std.mem.startsWith(u8, d.name, "on") and std.ascii.isUpper(d.name[2]);
        if (!hook) continue;
        if (std.mem.eql(u8, d.name, "onError") or std.mem.eql(u8, d.name, "onReceiveError")) continue;
        @compileError(@typeName(T) ++ "." ++ d.name ++ " is not a serve hook. They are onError and onReceiveError.");
    }
}

fn Child(comptime Handler: type) type {
    return switch (@typeInfo(Handler)) {
        .pointer => |p| p.child,
        else => Handler,
    };
}

fn ErrorSet(comptime f: anytype) type {
    const returns = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    return @typeInfo(returns).error_union.error_set;
}

/// Receives requests and calls `handler.handle(server, request)` for
/// each one, until the connection ends. A clean close returns nothing.
/// `handler` can be a value or a pointer, and `handle` has to be `pub`
/// and return an error union.
///
/// The first error ends the loop, and you get it back to log. Before
/// that the peer gets whatever it is still owed. A request that couldn't
/// be read, or a handler error with nothing sent yet, is answered with
/// `Status.forError` and `Connection: close`. So a handler that just does
/// `try server.readBody(buf)` gets a 413 for a body that is too large.
/// If the handler fails after `respondStreaming`, the head is already on
/// the wire and the body can't be fixed, so nothing more is written.
/// `Canceled` never gets a response.
///
/// If you want to answer handler errors yourself, give the handler
/// `pub fn onError(handler, server, request, err) !void`. It is called
/// for any error but `Canceled` while nothing has been sent, and it
/// should respond. An error it answers doesn't come back from here, so
/// log it there, and the loop carries on if the connection can. The
/// connection closes anyway after an error from the Server itself, like
/// a bad chunk or a body too large, because the reader may not be on a
/// message boundary. The same goes for a body you started reading and
/// didn't finish. If `onError` doesn't respond, or fails, you get the
/// default above.
///
/// `pub fn onReceiveError(handler, server, err) !void` does the same for
/// a request that couldn't be read. There is no request to pass, and the
/// connection always closes after it, because we don't know where the
/// next request would start. The error still comes back from here.
///
/// `server.last` says what went out for each request, including what
/// `serve` sent for you, so an access log can read it after `handle`,
/// in `onError`, and after `serve` returns.
///
/// Close the stream once this returns, whatever it returns. After an
/// upgrade the connection belongs to the handler, which should have
/// finished with it before returning.
pub fn serve(s: *Server, handler: anytype, options: Options) ServeError(@TypeOf(handler))!void {
    while (true) {
        setDeadline(options, options.head);
        const req = s.receive() catch |err| {
            // `receive` cleared `last`, so it is only set if the hook
            // answered.
            if (@hasDecl(Child(@TypeOf(handler)), "onReceiveError") and err != error.Canceled) {
                handler.onReceiveError(s, err) catch |hook_err| {
                    if (s.last == null) refuse(s, err);
                    return hook_err;
                };
            }
            if (s.last == null) refuse(s, err);
            return err;
        } orelse return;

        setDeadline(options, options.body);
        handler.handle(s, req) catch |err| {
            if (s.phase != .unanswered) return err;
            if (!@hasDecl(Child(@TypeOf(handler)), "onError") or err == error.Canceled) {
                refuse(s, err);
                return err;
            }
            if (Response.Status.named(err) != null or !s.alive()) s.keep_alive = false;
            handler.onError(s, req, err) catch |hook_err| {
                if (s.phase == .unanswered) refuse(s, err);
                return hook_err;
            };
            if (s.phase == .unanswered) {
                refuse(s, err);
                return err;
            }
        };

        switch (s.phase) {
            .unanswered => {
                refuse(s, error.NoResponse);
                return error.NoResponse;
            },
            .streaming => return error.ResponseOpen,
            .handed_over, .done => return,
            .ready, .answered => {},
        }
        if (!s.alive()) return;
    }
}

fn setDeadline(options: Options, timeout: Io.Timeout) void {
    const d = options.deadline orelse return;
    d.start(d.ctx, timeout);
}

/// The last response on this connection. If it can't be written the
/// connection is going anyway.
fn refuse(s: *Server, err: anyerror) void {
    if (err == error.Canceled) return;
    s.respond(.{ .status = .forError(err), .keep_alive = false }) catch {};
}

const testing = std.testing;
const scan = @import("scan.zig");
const arrival = @import("arrival.zig");

const Harness = struct {
    source: arrival.Source(1024, 512),
    writer: Io.Writer,
    headers: [16]scan.Header,
    head_buf: [4096]u8,
    out: [4096]u8,
    /// Every deadline the loop set, in order.
    set: [16]Io.Timeout,
    set_len: usize,

    fn init(h: *Harness, shape: arrival.Shape, input: []const u8) Server {
        h.writer = .fixed(&h.out);
        h.set_len = 0;
        return Server.init(testing.io, h.source.reader(shape, input), &h.writer, .{
            .headers = &h.headers,
            .head_buf = &h.head_buf,
        }) catch unreachable;
    }

    fn options(h: *Harness) Options {
        return .{
            .deadline = .{ .ctx = h, .start = record },
            .head = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } },
            .body = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
        };
    }

    fn record(ctx: *anyopaque, t: Io.Timeout) void {
        const h: *Harness = @ptrCast(@alignCast(ctx));
        h.set[h.set_len] = t;
        h.set_len += 1;
    }

    /// 1 for head, 2 for body, in the order they were set.
    fn deadlines(h: *Harness, buf: []u8) []const u8 {
        for (h.set[0..h.set_len], 0..) |t, i| buf[i] = '0' + @as(u8, @intCast(t.duration.raw.toSeconds()));
        return buf[0..h.set_len];
    }

    fn written(h: *Harness) []const u8 {
        return h.writer.buffered();
    }

    fn statusLines(h: *Harness) usize {
        return std.mem.count(u8, h.written(), "HTTP/1.1 ");
    }
};

const Echo = struct {
    fn handle(_: Echo, s: *Server, req: Server.Request) !void {
        var buf: [64]u8 = undefined;
        const body = try s.readBody(&buf);
        try s.respond(.text(.ok, if (body.len != 0) body else req.target()));
    }
};

test "each request gets the handler and the right deadline" {
    for (arrival.shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET /a HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "POST /b HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc");
        try serve(&s, Echo{}, h.options());

        try testing.expectEqual(@as(usize, 2), h.statusLines());
        try testing.expect(std.mem.indexOf(u8, h.written(), "\r\n\r\n/a") != null);
        try testing.expect(std.mem.endsWith(u8, h.written(), "\r\n\r\nabc"));
        var buf: [16]u8 = undefined;
        // The last head deadline is the wait that found the close.
        try testing.expectEqualStrings("12121", h.deadlines(&buf));
    }
}

test "no deadline means nothing is timed" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET /a HTTP/1.1\r\nHost: x\r\n\r\n");
    try serve(&s, Echo{}, .{});
    try testing.expectEqual(@as(usize, 1), h.statusLines());
}

test "a request that can't be read gets its status and ends the loop" {
    for (arrival.shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET / HTTP/1.1\r\n\r\nGET /never HTTP/1.1\r\nHost: x\r\n\r\n");
        try testing.expectError(error.BadHost, serve(&s, Echo{}, h.options()));
        try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 400 "));
        try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") != null);
        try testing.expectEqual(@as(usize, 1), h.statusLines());
    }
}

test "a handler error with nothing sent gets the status for it" {
    for (arrival.shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n" ++ "x" ** 100);
        try testing.expectError(error.BodyTooLarge, serve(&s, Echo{}, h.options()));
        try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 413 "));
        try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") != null);
        try testing.expect(!s.alive());
    }
}

test "a handler error of its own is a 500" {
    const Fails = struct {
        fn handle(_: @This(), _: *Server, _: Server.Request) !void {
            return error.DatabaseDown;
        }
    };
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expectError(error.DatabaseDown, serve(&s, Fails{}, h.options()));
    try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 500 "));
    try testing.expectEqual(@as(usize, 1), h.statusLines());
}

const Json = struct {
    seen: usize = 0,
    last: ?anyerror = null,
    answer: bool = true,

    fn handle(_: *Json, s: *Server, req: Server.Request) !void {
        if (std.mem.eql(u8, req.target(), "/fail")) return error.DatabaseDown;
        if (std.mem.eql(u8, req.target(), "/partial")) {
            var scratch: [16]u8 = undefined;
            var b = try s.bodyReader(&scratch);
            var one: [1]u8 = undefined;
            _ = try b.interface.readSliceShort(&one);
            return error.DatabaseDown;
        }
        var buf: [4]u8 = undefined;
        const body = try s.readBody(&buf);
        try s.respond(.text(.ok, if (body.len != 0) body else req.target()));
    }

    fn onError(j: *Json, s: *Server, _: Server.Request, err: anyerror) !void {
        j.seen += 1;
        j.last = err;
        if (!j.answer) return;
        try s.respond(.json(.forError(err), "{\"error\":true}"));
    }
};

test "onError answers a handler error and the connection carries on" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET /fail HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    var json: Json = .{};
    try serve(&s, &json, h.options());
    try testing.expectEqual(@as(usize, 1), json.seen);
    try testing.expectEqual(error.DatabaseDown, json.last.?);
    try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 500 "));
    try testing.expect(std.mem.indexOf(u8, h.written(), "{\"error\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") == null);
    try testing.expect(std.mem.endsWith(u8, h.written(), "\r\n\r\n/b"));
}

test "onError can't keep the connection after a Server error" {
    for (arrival.shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n" ++ "x" ** 10 ++
            "GET /never HTTP/1.1\r\nHost: x\r\n\r\n");
        var json: Json = .{};
        try serve(&s, &json, h.options());
        try testing.expectEqual(error.BodyTooLarge, json.last.?);
        try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 413 "));
        try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") != null);
        try testing.expectEqual(@as(usize, 1), h.statusLines());
    }
}

test "onError can't keep the connection after a body read halfway" {
    for (arrival.shapes) |shape| {
        var h: Harness = undefined;
        // Longer than the handler's scratch, so the body is really unfinished.
        var s = h.init(shape, "POST /partial HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n" ++ "x" ** 100 ++
            "GET /never HTTP/1.1\r\nHost: x\r\n\r\n");
        var json: Json = .{};
        try serve(&s, &json, h.options());
        try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 500 "));
        try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") != null);
        try testing.expectEqual(@as(usize, 1), h.statusLines());
    }
}

test "onError that doesn't answer gets the default" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET /fail HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    var json: Json = .{ .answer = false };
    try testing.expectError(error.DatabaseDown, serve(&s, &json, h.options()));
    try testing.expectEqual(@as(usize, 1), json.seen);
    try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 500 "));
    try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") != null);
    try testing.expectEqual(@as(usize, 1), h.statusLines());
}

test "onError is not called for Canceled" {
    const Canceled = struct {
        called: bool = false,
        fn handle(_: *@This(), _: *Server, _: Server.Request) !void {
            return error.Canceled;
        }
        fn onError(c: *@This(), _: *Server, _: Server.Request, _: anyerror) !void {
            c.called = true;
        }
    };
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    var c: Canceled = .{};
    try testing.expectError(error.Canceled, serve(&s, &c, h.options()));
    try testing.expect(!c.called);
    try testing.expectEqualStrings("", h.written());
}

const JsonReceive = struct {
    seen: ?anyerror = null,
    answer: bool = true,

    fn handle(_: *JsonReceive, s: *Server, _: Server.Request) !void {
        try s.respond(.{});
    }

    fn onReceiveError(j: *JsonReceive, s: *Server, err: anyerror) !void {
        j.seen = err;
        if (!j.answer) return;
        try s.respond(.json(.forError(err), "{\"error\":true}"));
    }
};

test "onReceiveError answers a request that couldn't be read" {
    for (arrival.shapes) |shape| {
        var h: Harness = undefined;
        var s = h.init(shape, "GET / HTTP/1.1\r\n\r\n");
        var j: JsonReceive = .{};
        try testing.expectError(error.BadHost, serve(&s, &j, h.options()));
        try testing.expectEqual(error.BadHost, j.seen.?);
        try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 400 "));
        try testing.expect(std.mem.indexOf(u8, h.written(), "Connection: close") != null);
        try testing.expect(std.mem.endsWith(u8, h.written(), "{\"error\":true}"));
        try testing.expectEqual(@as(usize, 1), h.statusLines());
        try testing.expectEqual(Response.Status.bad_request, s.last.?.status);
    }
}

test "onReceiveError that doesn't answer gets the default" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\n\r\n");
    var j: JsonReceive = .{ .answer = false };
    try testing.expectError(error.BadHost, serve(&s, &j, h.options()));
    try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 400 "));
    try testing.expect(std.mem.indexOf(u8, h.written(), "{\"error\":true}") == null);
    try testing.expectEqual(@as(usize, 1), h.statusLines());
}

test "last covers what serve sends for you" {
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    const Fails = struct {
        fn handle(_: @This(), _: *Server, _: Server.Request) !void {
            return error.DatabaseDown;
        }
    };
    try testing.expectError(error.DatabaseDown, serve(&s, Fails{}, h.options()));
    try testing.expectEqual(Response.Status.internal_server_error, s.last.?.status);
    try testing.expect(s.last.?.complete);
}

test "a handler error after a streamed head writes nothing more" {
    const Breaks = struct {
        fn handle(_: @This(), s: *Server, _: Server.Request) !void {
            var buf: [16]u8 = undefined;
            var rw = try s.respondStreaming(.{}, &buf, .{});
            try rw.interface.writeAll("part");
            try rw.interface.flush();
            return error.DatabaseDown;
        }
    };
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expectError(error.DatabaseDown, serve(&s, Breaks{}, h.options()));
    try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 200 "));
    try testing.expectEqual(@as(usize, 1), h.statusLines());
    // No last chunk, so the peer can tell the body was cut short.
    try testing.expect(!std.mem.endsWith(u8, h.written(), "0\r\n\r\n"));
    try testing.expect(!s.alive());
}

test "a streamed response left open ends the connection" {
    const LeavesOpen = struct {
        fn handle(_: @This(), s: *Server, _: Server.Request) !void {
            var buf: [16]u8 = undefined;
            _ = try s.respondStreaming(.{}, &buf, .{});
        }
    };
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expectError(error.ResponseOpen, serve(&s, LeavesOpen{}, h.options()));
    try testing.expectEqual(@as(usize, 1), h.statusLines());
}

test "a handler that forgets to answer gets a 500 sent for it" {
    const Forgets = struct {
        fn handle(_: @This(), _: *Server, _: Server.Request) !void {}
    };
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expectError(error.NoResponse, serve(&s, Forgets{}, h.options()));
    try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 500 "));
    try testing.expectEqual(@as(usize, 1), h.statusLines());
}

test "a 103 alone is not an answer" {
    const HintsOnly = struct {
        fn handle(_: @This(), s: *Server, _: Server.Request) !void {
            try s.respond(.{ .status = .early_hints });
        }
    };
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expectError(error.NoResponse, serve(&s, HintsOnly{}, h.options()));
    try testing.expect(std.mem.startsWith(u8, h.written(), "HTTP/1.1 103 "));
    try testing.expect(std.mem.indexOf(u8, h.written(), "HTTP/1.1 500 ") != null);
}

test "canceled gets no response" {
    const Canceled = struct {
        fn handle(_: @This(), _: *Server, _: Server.Request) !void {
            return error.Canceled;
        }
    };
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expectError(error.Canceled, serve(&s, Canceled{}, h.options()));
    try testing.expectEqualStrings("", h.written());
}

test "an upgrade ends the loop without reading the next protocol" {
    const Upgrades = struct {
        fn handle(_: @This(), s: *Server, _: Server.Request) !void {
            try s.upgrade(.{ .status = .switching_protocols, .headers = &.{
                .{ .name = "Connection", .value = "Upgrade" },
                .{ .name = "Upgrade", .value = "x" },
            } });
        }
    };
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: x\r\n\r\nnot http at all");
    try serve(&s, Upgrades{}, h.options());
    try testing.expect(s.handedOver());
    try testing.expectEqual(@as(usize, 1), h.statusLines());
}

test "the handler can be a pointer with state" {
    const Counts = struct {
        n: usize = 0,
        fn handle(c: *@This(), s: *Server, _: Server.Request) !void {
            c.n += 1;
            try s.respond(.{});
        }
    };
    var h: Harness = undefined;
    var s = h.init(.whole, "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n");
    var counts: Counts = .{};
    try serve(&s, &counts, h.options());
    try testing.expectEqual(@as(usize, 2), counts.n);
}
