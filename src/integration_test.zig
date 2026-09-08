//! Tests over a real socket.
//!
//! The buffer-backed tests are fast, and they have still let four real
//! bugs through. These ones use a real socket.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const martensite = @import("root.zig");
const Server = martensite.Server;
const Response = martensite.Response;
const TimedReader = martensite.TimedReader;

const testing = std.testing;

fn seconds(n: i64) Io.Clock.Duration {
    return .{ .raw = .fromSeconds(n), .clock = .awake };
}

fn millis(n: i64) Io.Clock.Duration {
    return .{ .raw = .fromMilliseconds(n), .clock = .awake };
}

/// A free port and the address to reach it on.
const Bound = struct {
    server: net.Server,
    address: net.IpAddress,
};

fn bind(io: Io, seed: u16) !Bound {
    var port = seed;
    while (port < seed + 200) : (port += 1) {
        const address: net.IpAddress = .{ .ip4 = .loopback(port) };
        const server = address.listen(io, .{ .reuse_address = false }) catch continue;
        return .{ .server = server, .address = address };
    }
    return error.NoFreePort;
}

/// Runs `handler` on one connection while `client` talks to it.
fn exchange(
    io: Io,
    seed: u16,
    comptime handler: anytype,
    comptime client: anytype,
) !void {
    var bound = try bind(io, seed);
    defer bound.server.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);
    // Not Group.async, which might wait until await, and we await after
    // the accept below.
    try group.concurrent(io, client, .{ io, bound.address });

    const stream = try bound.server.accept(io);
    const result = handler(io, stream);
    // Closed before the await. The client reads to end of stream, so
    // waiting on it first deadlocks.
    stream.close(io);
    try group.await(io);
    try result;
}

/// The server side of most of these.
fn plainHandler(io: Io, stream: net.Stream) !void {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var headers: [32]martensite.Header = undefined;
    var head_buf: [4096]u8 = undefined;

    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var http: Server = .init(io, &reader.interface, &writer.interface, .{
        .headers = &headers,
        .head_buf = &head_buf,
    });

    while (true) {
        const req = (try http.receive()) orelse return;
        var body_buf: [8192]u8 = undefined;
        const body = try http.readBody(&body_buf);

        // Target read after the body, which is where the stale head bug
        // was.
        if (std.mem.eql(u8, req.target(), "/echo")) {
            try http.respond(.text(.ok, body));
        } else if (std.mem.eql(u8, req.target(), "/stream")) {
            var scratch: [64]u8 = undefined;
            var rw = try http.respondStreaming(.{}, &scratch, .{});
            for (0..5) |i| try rw.interface.print("{d},", .{i});
            try rw.end();
        } else {
            try http.respond(.text(.ok, req.target()));
        }
        if (!http.alive()) return;
    }
}

fn send(io: Io, address: net.IpAddress, request: []const u8, out: []u8) ![]u8 {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [4096]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    try stream.shutdown(io, .send);

    var rbuf: [64]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var w: Io.Writer = .fixed(out);
    _ = reader.interface.streamRemaining(&w) catch {};
    return w.buffered();
}

/// Like plainHandler, but through TimedReader and with a buffer smaller
/// than the bodies it reads.
fn timedHandler(io: Io, stream: net.Stream) !void {
    var read_buf: [1024]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var headers: [32]martensite.Header = undefined;
    var head_buf: [4096]u8 = undefined;

    var reader: TimedReader = .init(io, stream, &read_buf, .{ .duration = seconds(5) });
    var writer = stream.writer(io, &write_buf);
    var http: Server = .init(io, &reader.interface, &writer.interface, .{
        .headers = &headers,
        .head_buf = &head_buf,
    });

    while (true) {
        const req = (try http.receive()) orelse return;
        _ = req;
        var body_buf: [64 * 1024]u8 = undefined;
        const body = try http.readBody(&body_buf);
        var line: [32]u8 = undefined;
        try http.respond(.text(.ok, try std.fmt.bufPrint(&line, "{d}", .{body.len})));
        if (!http.alive()) return;
    }
}

test "a body larger than the TimedReader buffer" {
    // Regression test. readVec handed writableVector a one-slot array,
    // and writableVector appends the reader's own buffer without
    // checking. Once the buffer drained it wrote index 1 of a length-1
    // array and panicked. Anything posting more than the read buffer hit
    // this.
    const io = testing.io;
    try exchange(io, 39600, timedHandler, struct {
        fn f(inner: Io, address: net.IpAddress) Io.Cancelable!void {
            const size = 8000;
            var request: [size + 128]u8 = undefined;
            const head = std.fmt.bufPrint(
                &request,
                "POST /big HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n",
                .{size},
            ) catch return;
            @memset(request[head.len..][0..size], 'x');

            var out: [4096]u8 = undefined;
            const reply = send(inner, address, request[0 .. head.len + size], &out) catch return;
            std.debug.assert(std.mem.endsWith(u8, reply, "8000"));
        }
    }.f);
}

test "a real request over a real socket" {
    const io = testing.io;
    try exchange(io, 39100, plainHandler, struct {
        fn f(inner: Io, address: net.IpAddress) Io.Cancelable!void {
            var out: [4096]u8 = undefined;
            const reply = send(inner, address, "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n", &out) catch return;
            std.debug.assert(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
            std.debug.assert(std.mem.endsWith(u8, reply, "\r\n\r\n/hello"));
        }
    }.f);
}

test "keep-alive over a real socket" {
    const io = testing.io;
    try exchange(io, 39200, plainHandler, struct {
        fn f(inner: Io, address: net.IpAddress) Io.Cancelable!void {
            var out: [4096]u8 = undefined;
            const reply = send(
                inner,
                address,
                "GET /one HTTP/1.1\r\n\r\nGET /two HTTP/1.1\r\n\r\n",
                &out,
            ) catch return;
            std.debug.assert(std.mem.indexOf(u8, reply, "/one") != null);
            std.debug.assert(std.mem.indexOf(u8, reply, "/two") != null);
        }
    }.f);
}

test "a chunked body over a real socket, arriving in pieces" {
    const io = testing.io;
    try exchange(io, 39300, plainHandler, struct {
        fn f(inner: Io, address: net.IpAddress) Io.Cancelable!void {
            const stream = address.connect(inner, .{ .mode = .stream }) catch return;
            defer stream.close(inner);
            var wbuf: [512]u8 = undefined;
            var writer = stream.writer(inner, &wbuf);

            const pieces = [_][]const u8{
                "POST /echo HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
                "5\r\nhello",
                "\r\n6\r\n world",
                "\r\n0\r\n\r\n",
            };
            for (pieces) |p| {
                writer.interface.writeAll(p) catch return;
                writer.interface.flush() catch return;
                millis(5).sleep(inner) catch {};
            }
            stream.shutdown(inner, .send) catch {};

            var rbuf: [64]u8 = undefined;
            var reader = stream.reader(inner, &rbuf);
            var out: [4096]u8 = undefined;
            var w: Io.Writer = .fixed(&out);
            _ = reader.interface.streamRemaining(&w) catch {};
            std.debug.assert(std.mem.endsWith(u8, w.buffered(), "\r\n\r\nhello world"));
        }
    }.f);
}

test "a streamed response over a real socket" {
    const io = testing.io;
    try exchange(io, 39400, plainHandler, struct {
        fn f(inner: Io, address: net.IpAddress) Io.Cancelable!void {
            var out: [4096]u8 = undefined;
            const reply = send(inner, address, "GET /stream HTTP/1.1\r\n\r\n", &out) catch return;
            std.debug.assert(std.mem.indexOf(u8, reply, "Transfer-Encoding: chunked") != null);
            std.debug.assert(std.mem.endsWith(u8, reply, "0\r\n\r\n"));
            std.debug.assert(std.mem.indexOf(u8, reply, "0,1,2,3,4,") != null or
                std.mem.indexOf(u8, reply, "2\r\n0,") != null);
        }
    }.f);
}

test "TimedReader reads a whole request, byte count and all" {
    const io = testing.io;
    try exchange(io, 39500, struct {
        fn f(inner: Io, stream: net.Stream) !void {
            var read_buf: [4096]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var headers: [32]martensite.Header = undefined;
            var head_buf: [4096]u8 = undefined;

            var reader: TimedReader = .init(inner, stream, &read_buf, .{ .duration = seconds(5) });
            var writer = stream.writer(inner, &write_buf);
            var http: Server = .init(inner, &reader.interface, &writer.interface, .{
                .headers = &headers,
                .head_buf = &head_buf,
            });

            const req = (try http.receive()) orelse return error.NoRequest;
            var body_buf: [8192]u8 = undefined;
            const body = try http.readBody(&body_buf);
            // The message-count bug made this come back short.
            try testing.expectEqual(@as(usize, 2000), body.len);
            try testing.expectEqualStrings("/upload", req.target());
            try http.respond(.text(.ok, "counted"));
        }
    }.f, struct {
        fn f(inner: Io, address: net.IpAddress) Io.Cancelable!void {
            var request: [2200]u8 = undefined;
            var w: Io.Writer = .fixed(&request);
            w.writeAll("POST /upload HTTP/1.1\r\nContent-Length: 2000\r\n\r\n") catch return;
            w.splatByteAll('z', 2000) catch return;

            var out: [1024]u8 = undefined;
            const reply = send(inner, address, w.buffered(), &out) catch return;
            std.debug.assert(std.mem.endsWith(u8, reply, "counted"));
        }
    }.f);
}

test "TimedReader gives up on a peer that says nothing" {
    const io = testing.io;
    try exchange(io, 39600, struct {
        fn f(inner: Io, stream: net.Stream) !void {
            var read_buf: [4096]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var headers: [32]martensite.Header = undefined;
            var head_buf: [4096]u8 = undefined;

            var reader: TimedReader = .init(inner, stream, &read_buf, .{ .duration = millis(150) });
            var writer = stream.writer(inner, &write_buf);
            var http: Server = .init(inner, &reader.interface, &writer.interface, .{
                .headers = &headers,
                .head_buf = &head_buf,
            });

            const started = Io.Timestamp.now(inner, .awake);
            try testing.expectError(error.ReadFailed, http.receive());
            try testing.expectEqual(TimedReader.Error.Timeout, reader.failure().?);

            // It gave up somewhere near the timeout, not straight away
            // and not never.
            const waited = Io.Timestamp.now(inner, .awake).nanoseconds - started.nanoseconds;
            try testing.expect(waited > 100 * std.time.ns_per_ms);
            try testing.expect(waited < 3 * std.time.ns_per_s);
        }
    }.f, struct {
        fn f(inner: Io, address: net.IpAddress) Io.Cancelable!void {
            const stream = address.connect(inner, .{ .mode = .stream }) catch return;
            defer stream.close(inner);
            // Connect, send nothing, wait to get dropped.
            millis(600).sleep(inner) catch {};
        }
    }.f);
}

test "TimedReader bounds a whole head, not just each read of it" {
    const io = testing.io;
    try exchange(io, 39700, struct {
        fn f(inner: Io, stream: net.Stream) !void {
            var read_buf: [4096]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var headers: [64]martensite.Header = undefined;
            var head_buf: [4096]u8 = undefined;

            var reader: TimedReader = .init(inner, stream, &read_buf, .{ .duration = seconds(5) });
            // Every single read is quick, but the head as a whole is
            // not.
            reader.startDeadline(.{ .duration = millis(300) });
            var writer = stream.writer(inner, &write_buf);
            var http: Server = .init(inner, &reader.interface, &writer.interface, .{
                .headers = &headers,
                .head_buf = &head_buf,
            });

            try testing.expectError(error.ReadFailed, http.receive());
            try testing.expectEqual(TimedReader.Error.Timeout, reader.failure().?);
        }
    }.f, struct {
        fn f(inner: Io, address: net.IpAddress) Io.Cancelable!void {
            const stream = address.connect(inner, .{ .mode = .stream }) catch return;
            defer stream.close(inner);
            var wbuf: [512]u8 = undefined;
            var writer = stream.writer(inner, &wbuf);
            writer.interface.writeAll("GET / HTTP/1.1\r\n") catch return;
            writer.interface.flush() catch return;
            // A header every 50ms, never finishing.
            for (0..20) |_| {
                millis(50).sleep(inner) catch return;
                writer.interface.writeAll("X-Pad: y\r\n") catch return;
                writer.interface.flush() catch return;
            }
        }
    }.f);
}

test "upgrade over a real socket keeps the early bytes" {
    const io = testing.io;
    try exchange(io, 39800, struct {
        fn f(inner: Io, stream: net.Stream) !void {
            var read_buf: [4096]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var headers: [32]martensite.Header = undefined;
            var head_buf: [4096]u8 = undefined;

            var reader = stream.reader(inner, &read_buf);
            var writer = stream.writer(inner, &write_buf);
            var http: Server = .init(inner, &reader.interface, &writer.interface, .{
                .headers = &headers,
                .head_buf = &head_buf,
            });

            const req = (try http.receive()) orelse return error.NoRequest;
            try testing.expectEqualStrings("websocket", req.upgradeTo().?);
            try http.upgrade(.{
                .status = .switching_protocols,
                .headers = &.{
                    .{ .name = "Upgrade", .value = "websocket" },
                    .{ .name = "Connection", .value = "Upgrade" },
                },
            });

            // Sent along with the handshake, before the 101.
            var early: [16]u8 = undefined;
            const n = try reader.interface.readSliceShort(&early);
            try testing.expectEqualStrings("EARLYFRAME", early[0..n]);

            try writer.interface.writeAll("PONG");
            try writer.interface.flush();
        }
    }.f, struct {
        fn f(inner: Io, address: net.IpAddress) Io.Cancelable!void {
            var out: [1024]u8 = undefined;
            const reply = send(
                inner,
                address,
                "GET /ws HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nEARLYFRAME",
                &out,
            ) catch return;
            std.debug.assert(std.mem.startsWith(u8, reply, "HTTP/1.1 101 "));
            std.debug.assert(std.mem.endsWith(u8, reply, "PONG"));
        }
    }.f);
}

test "100-continue over a real socket" {
    const io = testing.io;
    try exchange(io, 39900, plainHandler, struct {
        fn f(inner: Io, address: net.IpAddress) Io.Cancelable!void {
            const stream = address.connect(inner, .{ .mode = .stream }) catch return;
            defer stream.close(inner);
            var wbuf: [512]u8 = undefined;
            var writer = stream.writer(inner, &wbuf);

            writer.interface.writeAll(
                "POST /echo HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n",
            ) catch return;
            writer.interface.flush() catch return;

            // Waits to be told, the way curl does.
            var rbuf: [256]u8 = undefined;
            var reader = stream.reader(inner, &rbuf);
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            std.debug.assert(std.mem.startsWith(u8, line, "HTTP/1.1 100 Continue"));

            writer.interface.writeAll("body") catch return;
            writer.interface.flush() catch return;
            stream.shutdown(inner, .send) catch {};

            var out: [1024]u8 = undefined;
            var w: Io.Writer = .fixed(&out);
            _ = reader.interface.streamRemaining(&w) catch {};
            std.debug.assert(std.mem.endsWith(u8, w.buffered(), "body"));
        }
    }.f);
}

test "the client talks to the server over a real socket" {
    const io = testing.io;
    try exchange(io, 40100, plainHandler, struct {
        fn f(inner: Io, address: net.IpAddress) Io.Cancelable!void {
            const stream = address.connect(inner, .{ .mode = .stream }) catch return;
            defer stream.close(inner);

            var rbuf: [4096]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var headers: [32]martensite.Header = undefined;
            var head_buf: [2048]u8 = undefined;

            var reader = stream.reader(inner, &rbuf);
            var writer = stream.writer(inner, &wbuf);
            var client: martensite.Client = .init(inner, &reader.interface, &writer.interface, .{
                .headers = &headers,
                .head_buf = &head_buf,
            });

            // Two requests on one connection.
            client.send(.{ .target = "/first", .headers = &.{
                .{ .name = "Host", .value = "x" },
            } }) catch return;
            const first = (client.receive() catch return) orelse return;
            std.debug.assert(first.status() == 200);
            var buf: [256]u8 = undefined;
            const b1 = client.readBody(&buf) catch return;
            std.debug.assert(std.mem.eql(u8, b1, "/first"));

            client.send(.{
                .method = "POST",
                .target = "/echo",
                .headers = &.{.{ .name = "Host", .value = "x" }},
                .body = "round trip",
            }) catch return;
            const second = (client.receive() catch return) orelse return;
            std.debug.assert(second.status() == 200);
            const b2 = client.readBody(&buf) catch return;
            std.debug.assert(std.mem.eql(u8, b2, "round trip"));
        }
    }.f);
}

test "the client reads a chunked response from the server" {
    const io = testing.io;
    try exchange(io, 40200, plainHandler, struct {
        fn f(inner: Io, address: net.IpAddress) Io.Cancelable!void {
            const stream = address.connect(inner, .{ .mode = .stream }) catch return;
            defer stream.close(inner);

            var rbuf: [4096]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var headers: [32]martensite.Header = undefined;
            var head_buf: [2048]u8 = undefined;

            var reader = stream.reader(inner, &rbuf);
            var writer = stream.writer(inner, &wbuf);
            var client: martensite.Client = .init(inner, &reader.interface, &writer.interface, .{
                .headers = &headers,
                .head_buf = &head_buf,
            });

            client.send(.{ .target = "/stream" }) catch return;
            const res = (client.receive() catch return) orelse return;
            std.debug.assert(std.mem.eql(u8, res.header("transfer-encoding").?, "chunked"));
            var buf: [256]u8 = undefined;
            const b = client.readBody(&buf) catch return;
            std.debug.assert(std.mem.eql(u8, b, "0,1,2,3,4,"));
        }
    }.f);
}
