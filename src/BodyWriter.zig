//! Writes a body a piece at a time, on either side of a connection.
//!
//! Chunked, unless the head promised a length, in which case we check
//! what was written against it. Request and response bodies are framed
//! the same way. The only difference is what an unfinished body means
//! for the connection, and the owner decides that.
//!
//! Any error out of a write, `end` or `endWithTrailers` means the body
//! on the wire is incomplete. The connection gets told, and every call
//! after that returns `Finished` without writing. There is nothing to
//! retry and nothing to clean up.

const std = @import("std");
const Io = std.Io;

const field = @import("field.zig");

const BodyWriter = @This();

/// Where the bytes go once they are framed.
out: *Io.Writer,
/// What the caller writes to.
interface: Io.Writer,
mode: Mode,
owner: Owner,
state: State = .open,

pub const Mode = union(enum) {
    chunked,
    /// Exactly this many bytes.
    length: u64,
    /// No body allowed, so writes get dropped. This is a HEAD response.
    discard,
};

pub const State = enum { open, finished, broken };

/// How the writer reports back. Server and Client both close on
/// `broken`, but they move to different phases on `finished`.
pub const Owner = struct {
    ctx: *anyopaque,
    settled: *const fn (*anyopaque, State) void,
};

pub const EndError = Io.Writer.Error || error{
    /// A trailer we can't write, or one that would change framing we
    /// already acted on.
    InvalidTrailer,
    /// Fewer bytes than the length we promised. The peer would sit
    /// there waiting for the rest.
    LengthMismatch,
    /// Already ended, or a write failed and took the framing with it.
    Finished,
};

/// `scratch` becomes the writer's buffer, so its size is the biggest
/// piece that goes out in one write. With chunked encoding that is the
/// chunk size on the wire.
pub fn init(out: *Io.Writer, scratch: []u8, mode: Mode, owner: Owner) BodyWriter {
    return .{
        .out = out,
        .mode = mode,
        .owner = owner,
        .interface = .{
            .vtable = &.{ .drain = drain },
            .buffer = scratch,
        },
    };
}

/// Sends what has been written so far without breaking the framing. The
/// buffered bytes go out as their own chunk, then the connection's
/// writer is flushed.
///
/// Nothing reaches the peer without this or `end`. Flushing `interface`
/// only gets the bytes as far as the connection's writer, which matters
/// if you are streaming events rather than a file.
pub fn flush(b: *BodyWriter) Io.Writer.Error!void {
    if (b.state != .open) return error.WriteFailed;
    b.interface.flush() catch |err| return b.fail(err);
    b.out.flush() catch |err| return b.fail(err);
}

/// Ends the body and flushes. You have to call this.
pub fn end(b: *BodyWriter) EndError!void {
    return b.endWithTrailers(&.{});
}

/// Ends the body with trailers. A counted body has nowhere to put them
/// and says so, and a discarded one drops them along with the body. The
/// peer ignores them unless the head announced them.
///
/// Writing past the promised length comes back as `WriteFailed`, since
/// that is the only error an `Io.Writer` has.
pub fn endWithTrailers(b: *BodyWriter, fields: []const field.Header) EndError!void {
    if (b.state != .open) return error.Finished;
    // A counted body has nowhere to put them, and dropping them quietly
    // could lose a checksum the peer never sees. `discard` is different:
    // the head promised chunked and this is a HEAD, so the trailers go
    // the same way the body went.
    if (fields.len != 0 and b.mode == .length) return b.fail(error.InvalidTrailer);
    // Check first. Rejecting a trailer halfway through leaves the
    // terminator unwritten and the body unfinished.
    field.check(fields, .trailer) catch return b.fail(error.InvalidTrailer);

    b.interface.flush() catch |err| return b.fail(err);
    switch (b.mode) {
        .discard => {},
        .chunked => b.terminate(fields) catch |err| return b.fail(err),
        .length => |left| if (left != 0) return b.fail(error.LengthMismatch),
    }
    b.out.flush() catch |err| return b.fail(err);

    b.state = .finished;
    b.owner.settled(b.owner.ctx, .finished);
}

fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const b: *BodyWriter = @alignCast(@fieldParentPtr("interface", io_w));

    // Buffered bytes first, then the vectors. Bytes out of the buffer
    // don't count here: `drain` reports what it took from `data`.
    const buffered = io_w.buffered();
    try b.emit(buffered);
    io_w.end = 0;

    var total: usize = 0;

    for (data[0 .. data.len - 1]) |slice| {
        try b.emit(slice);
        total += slice.len;
    }
    const last = data[data.len - 1];
    for (0..splat) |_| {
        try b.emit(last);
        total += last.len;
    }
    return total;
}

fn emit(b: *BodyWriter, bytes: []const u8) Io.Writer.Error!void {
    if (bytes.len == 0) return;
    if (b.state != .open) return error.WriteFailed;
    switch (b.mode) {
        .discard => {},
        .length => |*left| {
            // Anything past the end reads as the next message.
            if (bytes.len > left.*) return b.fail(error.WriteFailed);
            left.* -= bytes.len;
            b.out.writeAll(bytes) catch |err| return b.fail(err);
        },
        .chunked => b.chunk(bytes) catch |err| return b.fail(err),
    }
}

fn chunk(b: *BodyWriter, bytes: []const u8) Io.Writer.Error!void {
    try b.out.print("{x}\r\n", .{bytes.len});
    try b.out.writeAll(bytes);
    try b.out.writeAll("\r\n");
}

fn terminate(b: *BodyWriter, fields: []const field.Header) Io.Writer.Error!void {
    try b.out.writeAll("0\r\n");
    try field.write(b.out, fields);
    try b.out.writeAll("\r\n");
}

/// Every error path ends up here. Half a body is on the wire and no
/// later write can fix that, so tell the connection and reject
/// everything after it.
fn fail(b: *BodyWriter, err: anytype) @TypeOf(err) {
    if (b.state == .open) {
        b.state = .broken;
        b.owner.settled(b.owner.ctx, .broken);
    }
    return err;
}
