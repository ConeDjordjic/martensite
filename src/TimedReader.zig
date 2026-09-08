//! A socket reader that gives up when the peer goes quiet.
//!
//! Server has no clock of its own. Without this a peer can open a
//! connection, send one byte and then hold a fiber forever.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const TimedReader = @This();

io: Io,
socket: net.Socket,
interface: Io.Reader,
/// How long a single read is allowed to wait.
timeout: Io.Timeout,
/// Upper bound for a whole message, set by `startDeadline`.
deadline: Io.Timeout = .none,
err: ?Error = null,

pub const Error = error{
    /// The peer stayed quiet for too long.
    Timeout,
    SystemResources,
    ConnectionResetByPeer,
    SocketUnconnected,
    NetworkDown,
} || Io.Cancelable || Io.UnexpectedError;

pub fn init(io: Io, stream: net.Stream, buffer: []u8, timeout: Io.Timeout) TimedReader {
    return .{
        .io = io,
        .socket = stream.socket,
        .timeout = timeout,
        .interface = .{
            .vtable = &.{ .stream = streamFn, .readVec = readVec },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
    };
}

/// Bounds a whole message instead of a single read, so a peer can't
/// stall by sending one byte at a time. `.none` clears it.
pub fn startDeadline(r: *TimedReader, total: Io.Timeout) void {
    r.deadline = total.toDeadline(r.io);
}

/// Why the last read failed.
pub fn failure(r: *const TimedReader) ?Error {
    return r.err;
}

fn effective(r: *TimedReader) Io.Timeout {
    const per_read = r.timeout.toTimestamp(r.io) orelse return r.deadline;
    const whole = r.deadline.toTimestamp(r.io) orelse return .{ .deadline = per_read };
    return .{ .deadline = if (whole.compare(.lt, per_read)) whole else per_read };
}

fn receive(r: *TimedReader, dest: []u8) Io.Reader.Error!usize {
    var message: [1]net.IncomingMessage = .{.init};
    const result = r.io.operateTimeout(.{ .net_receive = .{
        .socket_handle = r.socket.handle,
        .message_buffer = &message,
        .data_buffer = dest,
        .flags = .{},
    } }, r.effective()) catch |err| {
        r.err = switch (err) {
            error.Timeout => error.Timeout,
            error.Canceled => error.Canceled,
            // An Io with no concurrency can't time anything out.
            error.ConcurrencyUnavailable => error.SystemResources,
        };
        return error.ReadFailed;
    };
    // This counts messages, not bytes. The bytes are in message[0].
    const maybe_err, const messages = result.net_receive;
    if (maybe_err) |e| {
        r.err = switch (e) {
            error.ConnectionResetByPeer => error.ConnectionResetByPeer,
            error.SocketUnconnected => error.SocketUnconnected,
            error.NetworkDown => error.NetworkDown,
            error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => error.SystemResources,
            else => error.Unexpected,
        };
        return error.ReadFailed;
    }
    if (messages == 0) return error.EndOfStream;
    const n = message[0].data.len;
    if (n == 0) return error.EndOfStream;
    return n;
}

fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    const r: *TimedReader = @alignCast(@fieldParentPtr("interface", io_r));
    // writableVector appends our own buffer after the caller's vectors
    // and doesn't check capacity, so it needs one slot more than it is
    // given. With a one-slot array here it wrote past the end on every
    // read of a body bigger than the buffer.
    var buffers: [2][]u8 = undefined;
    const first = if (data.len == 0) data[0..0] else data[0..1];
    const count, const size = try io_r.writableVector(&buffers, first);
    _ = count;
    const dest = buffers[0];
    std.debug.assert(dest.len > 0);
    const n = try r.receive(dest);
    if (n > size) {
        io_r.end += n - size;
        return size;
    }
    return n;
}

fn streamFn(io_r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const r: *TimedReader = @alignCast(@fieldParentPtr("interface", io_r));
    const dest = limit.slice(try w.writableSliceGreedy(1));
    const n = try r.receive(dest);
    w.advance(n);
    return n;
}
