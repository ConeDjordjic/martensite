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
    var date: martensite.Date = .{};

    // A plain stream.reader works too, but then a silent peer ties this
    // fiber up forever.
    var reader: martensite.TimedReader = .init(io, stream, &read_buf, .{
        .duration = seconds(5),
    });
    var writer = stream.writer(io, &write_buf);
    var http: martensite.Server = .init(io, &reader.interface, &writer.interface, .{
        .headers = &headers,
        .head_buf = &head_buf,
        .date = &date,
    });

    while (true) {
        // This one is for the whole head, not for a single read.
        reader.startDeadline(.{ .duration = seconds(10) });

        const req = http.receive() catch |err| {
            // ReadFailed does not say why. The reader does.
            const timed_out = err == error.ReadFailed and switch (reader.failure() orelse error.Unexpected) {
                error.Timeout => true,
                else => false,
            };
            _ = http.respond(if (timed_out)
                .{ .status = .request_timeout, .keep_alive = false }
            else
                errorResponse(err)) catch {};
            return;
        } orelse return;

        // Any size of body, without holding it in memory.
        if (std.mem.eql(u8, req.target(), "/drain")) {
            reader.startDeadline(.{ .duration = seconds(60) });
            var counter: Io.Writer.Discarding = .init(&.{});
            var scratch: [4096]u8 = undefined;
            var b = http.bodyReader(&scratch) catch return;
            _ = b.interface.streamRemaining(&counter.writer) catch {
                _ = http.respond(.{ .status = .bad_request, .keep_alive = false }) catch {};
                return;
            };
            var line: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "{d} bytes\n", .{counter.count}) catch "counted\n";
            http.respond(.text(.ok, text)) catch return;
            if (!http.alive()) return;
            continue;
        }

        reader.startDeadline(.{ .duration = seconds(30) });

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

fn seconds(n: i64) Io.Clock.Duration {
    return .{ .raw = .fromSeconds(n), .clock = .awake };
}

fn errorResponse(err: anyerror) martensite.Response {
    return switch (err) {
        error.HeadTooLarge => .{ .status = .request_header_fields_too_large, .keep_alive = false },
        error.UnsupportedExpectation => .{ .status = .expectation_failed, .keep_alive = false },
        error.BodyTooLarge => .{ .status = .payload_too_large, .keep_alive = false },
        else => .{ .status = .bad_request, .keep_alive = false },
    };
}
