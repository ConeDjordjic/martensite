//! A WebSocket echo server.
//!
//! The framing is as small as it gets: no fragmentation, no close codes
//! and no UTF-8 checks.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const martensite = @import("martensite");

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr: net.IpAddress = .{ .ip4 = .unspecified(8081) };
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("ws://127.0.0.1:8081/\n", .{});

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

    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var http: martensite.Server = martensite.Server.init(io, &reader.interface, &writer.interface, .{
        .headers = &headers,
        .head_buf = &head_buf,
    }) catch return;

    const req = (http.receive() catch return) orelse return;

    const upgrade = req.upgradeTo() orelse {
        _ = http.respond(.text(.bad_request, "expected a websocket upgrade\n")) catch {};
        return;
    };
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) {
        _ = http.respond(.text(.bad_request, "only websocket here\n")) catch {};
        return;
    }
    const key = req.header("sec-websocket-key") orelse {
        _ = http.respond(.text(.bad_request, "no key\n")) catch {};
        return;
    };

    var accept_buf: [32]u8 = undefined;
    const accept = acceptFor(key, &accept_buf);

    http.upgrade(.{
        .status = .switching_protocols,
        .headers = &.{
            .{ .name = "Upgrade", .value = "websocket" },
            .{ .name = "Connection", .value = "Upgrade" },
            .{ .name = "Sec-WebSocket-Accept", .value = accept },
        },
    }) catch return;

    // The socket is ours now.
    echo(&reader.interface, &writer.interface) catch {};
}

fn acceptFor(key: []const u8, out: *[32]u8) []const u8 {
    var sha: std.crypto.hash.Sha1 = .init(.{});
    sha.update(key);
    sha.update(guid);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

const Opcode = enum(u4) { continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10, _ };

fn echo(r: *Io.Reader, w: *Io.Writer) !void {
    var staging: [8 * 1024]u8 = undefined;

    while (true) {
        const first = try r.takeArray(2);
        const opcode: Opcode = @enumFromInt(first[0] & 0x0f);
        const masked = first[1] & 0x80 != 0;
        var len: u64 = first[1] & 0x7f;
        if (len == 126) {
            len = std.mem.readInt(u16, try r.takeArray(2), .big);
        } else if (len == 127) {
            len = std.mem.readInt(u64, try r.takeArray(8), .big);
        }
        // Clients have to mask.
        if (!masked) return;
        const mask = (try r.takeArray(4)).*;

        switch (opcode) {
            .close, .ping, .pong => {
                // Control frames are never bigger than 125 bytes.
                if (len > 125) return;
                const payload = try r.take(@intCast(len));
                unmask(payload, mask, 0);
                switch (opcode) {
                    .close => {
                        try writeFrame(w, .close, "");
                        return;
                    },
                    .ping => try writeFrame(w, .pong, payload),
                    else => {},
                }
            },
            else => {
                // Frames can be bigger than anything we hold, so write
                // the header first and copy the payload through.
                try writeHeader(w, opcode, len);
                var left = len;
                var offset: usize = 0;
                while (left > 0) {
                    const want: usize = @intCast(@min(left, staging.len));
                    const n = try r.readSliceShort(staging[0..want]);
                    if (n == 0) return error.EndOfStream;
                    unmask(staging[0..n], mask, offset);
                    try w.writeAll(staging[0..n]);
                    offset += n;
                    left -= n;
                }
                try w.flush();
            },
        }
    }
}

fn unmask(bytes: []u8, mask: [4]u8, offset: usize) void {
    for (bytes, 0..) |*b, i| b.* ^= mask[(offset + i) % 4];
}

fn writeHeader(w: *Io.Writer, opcode: Opcode, len: u64) !void {
    try w.writeByte(0x80 | @as(u8, @intFromEnum(opcode)));
    if (len < 126) {
        try w.writeByte(@intCast(len));
    } else if (len <= 0xffff) {
        try w.writeByte(126);
        try w.writeInt(u16, @intCast(len), .big);
    } else {
        try w.writeByte(127);
        try w.writeInt(u64, len, .big);
    }
}

fn writeFrame(w: *Io.Writer, opcode: Opcode, payload: []const u8) !void {
    try writeHeader(w, opcode, payload.len);
    try w.writeAll(payload);
    try w.flush();
}
