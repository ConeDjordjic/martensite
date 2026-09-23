//! An HTTPS request.
//!
//!     zig build && ./zig-out/bin/tls-client example.com /

const std = @import("std");
const Io = std.Io;
const martensite = @import("martensite");

const record_len = std.crypto.tls.max_ciphertext_record_len;

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = try std.process.Args.Iterator.initAllocator(init.args, gpa);
    defer args.deinit();
    _ = args.next();
    const host = args.next() orelse "example.com";
    const path = args.next() orelse "/";

    const host_name = try Io.net.HostName.init(host);
    const stream = try host_name.connect(io, 443, .{ .mode = .stream });
    defer stream.close(io);

    var sock_rbuf: [record_len]u8 = undefined;
    var sock_wbuf: [record_len]u8 = undefined;
    var sock_reader = stream.reader(io, &sock_rbuf);
    var sock_writer = stream.writer(io, &sock_wbuf);

    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(gpa);
    try bundle.rescan(gpa, io, Io.Clock.now(.real, io));
    var lock: Io.RwLock = .init;

    var tls_rbuf: [record_len]u8 = undefined;
    var tls_wbuf: [record_len]u8 = undefined;
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);

    var tls: std.crypto.tls.Client = try .init(&sock_reader.interface, &sock_writer.interface, .{
        .host = .{ .explicit = host },
        .ca = .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &lock, .bundle = &bundle } },
        .read_buffer = &tls_rbuf,
        .write_buffer = &tls_wbuf,
        .entropy = &entropy,
        .realtime_now = Io.Clock.now(.real, io),
    });

    var headers: [64]martensite.Header = undefined;
    // Has to be at least as big as the reader's buffer. Here that is the
    // TLS reader, and its buffer is a record, not a round 16K.
    var head_buf: [record_len]u8 = undefined;
    var http: martensite.Client = try .init(io, &tls.reader, &tls.writer, .{
        .headers = &headers,
        .head_buf = &head_buf,
    });

    try http.send(.{
        .method = "GET",
        .target = path,
        .headers = &.{.{ .name = "Host", .value = host }},
    });
    // send flushed the TLS writer, but that only moved the bytes into
    // the socket writer's buffer. Flushing that one is up to us.
    try sock_writer.interface.flush();

    const res = (try http.receive()) orelse return error.ClosedBeforeResponse;
    std.debug.print("{d} {s}\n", .{ res.status(), res.reason() });

    // Big enough for the pages this gets pointed at, but not for any
    // page at all. See the README on `contentLength`.
    var body_buf: [256 * 1024]u8 = undefined;
    const body = try http.readBody(&body_buf);
    std.debug.print("{d} bytes\n", .{body.len});

    // Without close_notify the peer can't tell whether the session
    // finished or got cut off.
    try tls.end();
    try sock_writer.interface.flush();
}
