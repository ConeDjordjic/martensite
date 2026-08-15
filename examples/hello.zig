//! A server. martensite does the HTTP, and the loop and the sockets are
//! yours.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const martensite = @import("martensite");

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    // Any std.Io implementation works here.
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr: net.IpAddress = .{ .ip4 = .unspecified(8080) };
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("listening on :8080\n", .{});

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
    var head_buf: [8 * 1024]u8 = undefined;

    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var http: martensite.Server = .init(io, &reader.interface, &writer.interface, .{
        .headers = &headers,
        .head_buf = &head_buf,
    });

    while (true) {
        const req = http.receive() catch |err| {
            _ = http.respond(errorResponse(err)) catch {};
            return;
        } orelse return;

        var body_buf: [64 * 1024]u8 = undefined;
        const body = http.readBody(&body_buf) catch |err| {
            _ = http.respond(errorResponse(err)) catch {};
            return;
        };

        const res: martensite.Response = if (std.mem.eql(u8, req.target(), "/echo"))
            .text(.ok, body)
        else
            .text(.ok, "hello\n");

        http.respond(res) catch return;
        if (!http.alive()) return;
    }
}

fn errorResponse(err: anyerror) martensite.Response {
    return switch (err) {
        error.HeadTooLarge => .{ .status = .request_header_fields_too_large, .keep_alive = false },
        error.BodyTooLarge => .{ .status = .payload_too_large, .keep_alive = false },
        else => .{ .status = .bad_request, .keep_alive = false },
    };
}
