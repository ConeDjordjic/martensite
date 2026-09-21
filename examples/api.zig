//! Routing, plus the parts of `Server` that `hello.zig` leaves out:
//! streamed responses, a 100-continue gate and request trailers.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const martensite = @import("martensite");

/// Anything bigger than this gets answered before the body is sent.
const max_upload = 1 << 20;

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr: net.IpAddress = .{ .ip4 = .unspecified(8081) };
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("listening on :8081\n", .{});

    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = listener.accept(io) catch continue;
        group.async(io, serve, .{ io, stream });
    }
}

fn serve(io: Io, stream: net.Stream) Io.Cancelable!void {
    defer stream.close(io);

    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var headers: [64]martensite.Header = undefined;
    var head_buf: [16 * 1024]u8 = undefined;
    var date: martensite.Date = .{};
    var trailer_buf: [512]u8 = undefined;

    var reader: martensite.TimedReader = .init(io, stream, &read_buf, .{
        .duration = seconds(5),
    });
    var writer = stream.writer(io, &write_buf);
    var http: martensite.Server = martensite.Server.init(io, &reader.interface, &writer.interface, .{
        .headers = &headers,
        .head_buf = &head_buf,
        .date = &date,
        .failure = reader.failureSource(),
        // Leaving this empty drops trailers, and /upload wants them.
        .trailer_buf = &trailer_buf,
        // A rejected upload is still on the wire. Read up to this much
        // and the connection survives for the next request.
        .max_drain = 64 * 1024,
    }) catch return;

    while (true) {
        reader.startDeadline(.{ .duration = seconds(10) });

        const req = http.receive() catch |err| {
            _ = http.respond(.{ .status = .forError(err), .keep_alive = false }) catch {};
            return;
        } orelse return;

        // Match on the path, so `/events?since=3` routes the same as
        // `/events`.
        const path = if (req.parsedTarget()) |t| t.path else req.target();
        const method = req.knownMethod() orelse {
            _ = http.respond(.{ .status = .not_implemented }) catch return;
            if (!http.alive()) return;
            continue;
        };

        route(&http, &reader, req, method, path) catch return;
        if (!http.alive()) return;
    }
}

fn route(
    http: *martensite.Server,
    reader: *martensite.TimedReader,
    req: martensite.Server.Request,
    method: martensite.Method,
    path: []const u8,
) !void {
    // HEAD runs the same handler as GET. The library writes the head and
    // drops the body.
    const get = method == .GET or method == .HEAD;

    if (std.mem.eql(u8, path, "/")) {
        if (!get) return methodNotAllowed(http, "GET, HEAD");
        return http.respond(.text(.ok, index));
    }

    if (std.mem.eql(u8, path, "/events")) {
        if (!get) return methodNotAllowed(http, "GET, HEAD");
        return events(http);
    }

    if (std.mem.eql(u8, path, "/upload")) {
        if (method != .POST and method != .PUT) return methodNotAllowed(http, "POST, PUT");
        return upload(http, reader, req);
    }

    return http.respond(.text(.not_found, "no such thing\n"));
}

fn methodNotAllowed(http: *martensite.Server, allow: []const u8) !void {
    return http.respond(.{
        .status = .method_not_allowed,
        .headers = &.{.{ .name = "Allow", .value = allow }},
    });
}

/// A body written a piece at a time, with no length known up front. The
/// head goes out first, so the peer gets the status before the events.
fn events(http: *martensite.Server) !void {
    var out_buf: [1024]u8 = undefined;
    var rw = try http.respondStreaming(.{
        .headers = &.{
            .{ .name = "Content-Type", .value = "text/event-stream" },
            .{ .name = "Cache-Control", .value = "no-cache" },
        },
    }, &out_buf, .{});

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try rw.interface.print("data: {d}\n\n", .{i});
        // Each event on its own, instead of one chunk holding five.
        try rw.flush();
    }
    try rw.end();
}

/// Rejects an oversized upload before the body is sent, and reads the
/// trailers a chunked one can end with.
fn upload(
    http: *martensite.Server,
    reader: *martensite.TimedReader,
    req: martensite.Server.Request,
) !void {
    // Reading the body is what sends the 100 Continue. If we answer
    // before that, a peer which asked to wait never sends it at all.
    if (req.contentLength()) |n| {
        if (n > max_upload) return http.respond(.{ .status = .payload_too_large });
    }

    reader.startDeadline(.{ .duration = seconds(60) });

    var scratch: [4096]u8 = undefined;
    var counter: Io.Writer.Discarding = .init(&.{});
    var b = http.bodyReader(&scratch) catch |err| {
        return http.respond(.{ .status = .forError(err), .keep_alive = false });
    };
    // A chunked body has no length up front, so the cap has to limit the
    // read itself. Reading all of it and complaining afterwards means
    // reading however much they decide to send.
    var n: u64 = 0;
    while (n <= max_upload) {
        n += b.interface.stream(&counter.writer, .limited64(max_upload + 1 - n)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return http.respond(.{ .status = .bad_request, .keep_alive = false }),
        };
    } else return http.respond(.{ .status = .payload_too_large, .keep_alive = false });

    // Trailers arrive after the body, so they are no use for framing or
    // routing. Usually it's a checksum.
    var trailer_storage: [8]martensite.Header = undefined;
    const trailers = http.trailers(&trailer_storage) catch &.{};

    var line: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{d} bytes, {d} trailers\n", .{
        n, trailers.len,
    }) catch "stored\n";
    return http.respond(.text(.created, text));
}

fn seconds(n: i64) Io.Clock.Duration {
    return .{ .raw = .fromSeconds(n), .clock = .awake };
}

const index =
    \\GET  /        this
    \\GET  /events  five chunked events
    \\POST /upload  counts the body, reads its trailers
    \\
;
