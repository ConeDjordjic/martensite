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
    var head_buf: [16 * 1024]u8 = undefined;

    // A plain stream.reader works too, but then a silent peer ties this
    // fiber up forever.
    var reader: martensite.TimedReader = .init(io, stream, &read_buf, .{
        .duration = seconds(5),
    });
    var writer = stream.writer(io, &write_buf);
    var http: martensite.Server = martensite.Server.init(io, &reader.interface, &writer.interface, .{
        .headers = &headers,
        .head_buf = &head_buf,
        .failure = reader.failureSource(),
    }) catch return;

    var app: App = .{ .reader = &reader };
    http.serve(&app, .{
        .deadline = reader.deadlines(),
        // For the whole head, not for a single read.
        .head = .{ .duration = seconds(10) },
        .body = .{ .duration = seconds(30) },
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        // The peer already got whatever it was owed, so all that is
        // left is closing the connection.
        else => return,
    };
}

const App = struct {
    reader: *martensite.TimedReader,

    pub fn handle(app: *App, http: *martensite.Server, req: martensite.Server.Request) !void {
        // Any size of body, without holding it in memory.
        if (std.mem.eql(u8, req.target(), "/drain")) {
            app.reader.startDeadline(.{ .duration = seconds(60) });
            var counter: Io.Writer.Discarding = .init(&.{});
            var scratch: [4096]u8 = undefined;
            var b = try http.bodyReader(&scratch);
            _ = b.interface.streamRemaining(&counter.writer) catch return error.BadRequest;
            var line: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "{d} bytes\n", .{counter.count}) catch "counted\n";
            return http.respond(.text(.ok, text));
        }

        // A body that doesn't fit is a 413 without anything more here.
        var body_buf: [64 * 1024]u8 = undefined;
        const body = try http.readBody(&body_buf);

        const res: martensite.Response = if (std.mem.eql(u8, req.target(), "/echo"))
            .text(.ok, body)
        else
            .text(.ok, "hello\n");
        try http.respond(res);
    }
};

fn seconds(n: i64) Io.Clock.Duration {
    return .{ .raw = .fromSeconds(n), .clock = .awake };
}
