//! Owns where the reader is.
//!
//! `head_len` is how many bytes at the front of the reader belong to
//! the current head. This used to be kept up to date by four functions
//! in two files, all repeating `toss(head_len); head_len = 0` in an
//! order nobody had written down anywhere. Get it wrong and a body gets
//! scanned as the next request line.
//!
//! Nothing outside this file moves the reader.

const std = @import("std");
const Io = std.Io;

const scan = @import("scan.zig");
const body = @import("body.zig");
const chunked = @import("chunked.zig");

const HeadWindow = @This();

reader: *Io.Reader,
headers: []scan.Header,
head_buf: []u8,
trailer_buf: []u8 = &.{},
/// How much of an unread body we will read to keep the connection
/// usable. Zero means don't bother, and an unread body then ends the
/// connection.
max_drain: u64 = 0,

/// Bytes of the current head that are still at the front of the reader.
head_len: usize = 0,
/// Framing of the body nobody has read yet.
pending: body.Framing = .none,
/// Bumped on every take, so we can catch stale heads.
generation: u32 = 0,
/// Set once we no longer know the reader is sitting on a message
/// boundary. We don't scan anything after that.
finished: bool = false,
/// The body has been handed out. Handing it out twice gives you two
/// readers that both think they own it, and the second one reads the
/// next head as body.
claimed: bool = false,
/// The last body's trailers didn't fit in `trailer_buf`, so what we
/// kept is only the start of them.
trailers_truncated: bool = false,
/// Raw trailer lines from the last chunked body. Cleared on every take.
trailers_raw: []const u8 = "",

pub const Options = struct {
    headers: []scan.Header,
    head_buf: []u8 = &.{},
    trailer_buf: []u8 = &.{},
    max_drain: u64 = 0,
};

pub const InitError = error{
    /// `head_buf` is smaller than the reader's buffer, so a head the
    /// reader can hold has nowhere to go while its body is read. The two
    /// limits have to agree, otherwise the same message passes or fails
    /// depending on whether it happens to have a body.
    HeadBufferTooSmall,
};

pub fn init(reader: *Io.Reader, options: Options) InitError!HeadWindow {
    // Empty is fine, because a message with no body never needs one.
    if (options.head_buf.len != 0 and options.head_buf.len < reader.buffer.len)
        return error.HeadBufferTooSmall;
    return .{
        .reader = reader,
        .headers = options.headers,
        .head_buf = options.head_buf,
        .trailer_buf = options.trailer_buf,
        .max_drain = options.max_drain,
    };
}

/// Trailers from the last chunked body, scanned into `storage`. They
/// point into `trailer_buf` and stay valid until the next take. Empty if
/// the message had none, or if no `trailer_buf` was given.
///
/// `TooManyHeaders` means one of the buffers was too small: `storage`
/// for the scanned headers, or `trailer_buf` for the lines. We never
/// hand back a truncated set as if it were complete.
///
/// These are not filtered, unlike the ones we write. A peer's trailers
/// are just data. They arrive after the body, so nothing in them can
/// change framing or routing, which are both decided by that point.
pub fn trailers(w: *const HeadWindow, storage: []scan.Header) scan.Error![]const scan.Header {
    if (w.trailers_truncated) return error.TooManyHeaders;
    if (w.trailers_raw.len == 0) return &.{};
    return scan.trailers(w.trailers_raw, storage);
}

/// Can we take another head from where the reader is now?
///
/// False once a body ended somewhere we can't account for, and false
/// while there is a pending body nobody is going to read. Reading the
/// body changes the answer.
pub fn usable(w: *const HeadWindow) bool {
    if (w.finished) return false;
    return w.pending == .none or w.max_drain != 0;
}

pub const TakeError = error{
    /// Not a message.
    Invalid,
    /// The head didn't fit, or it had too many headers.
    HeadTooLarge,
    Ambiguous,
    UnsupportedEncoding,
    ReadFailed,
} || Io.Cancelable;

pub const Kind = enum { request, response };

pub fn Taken(comptime kind: Kind) type {
    return struct {
        head: switch (kind) {
            .request => scan.Head,
            .response => scan.ResponseHead,
        },
        framing: body.Framing,
    };
}

/// The next request head, or null if there isn't going to be one.
pub fn takeRequest(w: *HeadWindow) TakeError!?Taken(.request) {
    return w.take(.request, null);
}

/// The next response head. `sent_method` decides the framing, since a
/// HEAD is answered with a length and no body.
pub fn takeResponse(w: *HeadWindow, sent_method: ?scan.Method) TakeError!?Taken(.response) {
    return w.take(.response, sent_method);
}

/// Cleans up after the last head before we scan anything. There is no
/// separate call for it, so a caller can't read a flag the drain hasn't
/// set yet.
fn take(w: *HeadWindow, comptime kind: Kind, sent_method: ?scan.Method) TakeError!?Taken(kind) {
    if (w.finished) return null;
    w.drainPending();
    if (w.finished) return null;

    w.releaseHead();
    w.trailers_raw = "";
    w.trailers_truncated = false;
    w.claimed = false;

    var last_len: usize = 0;
    var filled = false;
    while (true) {
        const buffered = w.reader.buffered();
        if (buffered.len != 0) {
            const scanned = switch (kind) {
                .request => scan.request(buffered, w.headers, last_len),
                .response => scan.response(buffered, w.headers, last_len),
            } catch |err| return switch (err) {
                error.Invalid => error.Invalid,
                error.TooManyHeaders => error.HeadTooLarge,
            };
            if (scanned) |got| {
                const framing = switch (kind) {
                    .request => try body.request(got.head),
                    .response => try body.response(got.head, sent_method),
                };
                // We store nothing until the last step that can fail
                // is done, so a rejected head leaves nothing half set.
                const head = switch (framing) {
                    .none => got.head,
                    else => try w.keepHead(kind, buffered[0..got.len], got.head),
                };
                w.head_len = got.len;
                w.pending = framing;
                w.generation +%= 1;
                return .{ .head = head, .framing = framing };
            }
            last_len = buffered.len;
            // Incomplete, with nowhere to put the rest. We check this
            // after the scan and not after the fill, because a peer
            // sending head and body together fills the buffer with a
            // perfectly good head. And only after a fill, because a
            // reader whose buffer is its data looks full from the
            // start.
            if (filled and buffered.len == w.reader.buffer.len) return error.HeadTooLarge;
        }

        w.reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => {
                if (w.reader.bufferedLen() == 0) return null;
                return error.Invalid;
            },
            error.ReadFailed => return error.ReadFailed,
        };
        filled = true;
    }
}

/// One pass of the chunked decoder over whatever the reader has.
///
/// The bytes get copied into `dest` and decoded there, because a
/// reader's buffer might be memory we can't write to. `dest` limits how
/// much we decode in one pass, not how big a body can be. Anything the
/// decoder didn't consume stays in the reader for the next pass.
///
/// All three body paths go through here. The only difference between
/// them is where the decoded bytes end up.
const Step = struct {
    /// Source bytes looked at, consumed or not.
    looked: usize,
    /// The decoded bytes, at the front of `dest`.
    decoded: usize,
    outcome: enum {
        /// Some source was consumed and the body carries on.
        more,
        /// Halfway through a header and wants more bytes. Fill the
        /// reader instead of spinning.
        need_fill,
        /// The last chunk is in. `trailers_raw` is set.
        done,
        /// The chunked encoding is malformed.
        bad,
    },
};

fn decodeStep(w: *HeadWindow, d: *chunked.Decoder, dest: []u8) Step {
    const buffered = w.reader.buffered();
    const want = @min(buffered.len, dest.len);
    if (want == 0) return .{ .looked = 0, .decoded = 0, .outcome = .need_fill };

    @memcpy(dest[0..want], buffered[0..want]);
    const r = d.decode(dest[0..want]) catch
        return .{ .looked = want, .decoded = 0, .outcome = .bad };

    const used = want - r.leftover;
    w.reader.toss(used);
    if (r.done) {
        w.trailers_raw = r.trailers;
        w.trailers_truncated = d.trailers_truncated;
        return .{ .looked = want, .decoded = r.decoded, .outcome = .done };
    }
    return .{
        .looked = want,
        .decoded = r.decoded,
        .outcome = if (used == 0) .need_fill else .more,
    };
}

/// Reads whatever body the caller didn't, so the next head starts in the
/// right place. It needs no buffer: a counted body is discarded straight
/// through the reader, and a chunked one decodes in place, in bytes we
/// are throwing away anyway.
///
/// Anything that doesn't fit inside `max_drain` ends the window instead.
/// Refusing to carry on reading is always safe. Guessing where the body
/// ended is not.
fn drainPending(w: *HeadWindow) void {
    if (w.pending == .none) return;
    if (w.max_drain == 0) {
        w.stop();
        return;
    }

    w.releaseHead();

    switch (w.pending) {
        .none => unreachable,
        .until_close => w.stop(),
        .length => |n| {
            if (n > w.max_drain) {
                w.stop();
                return;
            }
            w.reader.discardAll64(n) catch {
                w.stop();
                return;
            };
            w.pending = .none;
        },
        .chunked => {
            // We are throwing this away, so the staging buffer can be
            // tiny. `max_drain` bounds the body, not this.
            var stage: [512]u8 = undefined;
            var d: chunked.Decoder = .{ .consume_trailer = true };
            var read: u64 = 0;
            while (true) {
                const st = w.decodeStep(&d, &stage);
                read += st.looked;
                if (st.outcome == .bad or read > w.max_drain) {
                    w.stop();
                    return;
                }
                switch (st.outcome) {
                    .done => {
                        w.pending = .none;
                        return;
                    },
                    .more => continue,
                    .need_fill => w.reader.fillMore() catch {
                        w.stop();
                        return;
                    },
                    .bad => unreachable,
                }
            }
        },
    }
}

pub const BodyError = error{
    /// The peer stopped sending halfway through the body.
    Incomplete,
    /// The chunked encoding is malformed.
    BadChunk,
    /// The destination failed partway through and there is no way to
    /// find out how much it kept. Reading again wouldn't help, since we
    /// can't hand it the same bytes twice.
    SinkFailed,
    /// The body doesn't fit in the buffer it was given. Only `readBody`
    /// returns this.
    BodyTooLarge,
    /// There is no body to hand out. Either this call or the other one
    /// already took it, or the window gave up first. A body is read once
    /// and one way, because a second reader would mistake the next head
    /// for body.
    BodyTaken,
    ReadFailed,
} || Io.Cancelable;

/// Reads the whole body into `buf`. If it doesn't fit you get an error,
/// not a short read.
pub fn readBody(w: *HeadWindow, buf: []u8) BodyError![]u8 {
    // This goes before the `pending` check. Once a body has been read,
    // or the window has given up, `pending` is `.none`, and an empty
    // slice would be a lie about the message.
    if (w.claimed or w.finished) return error.BodyTaken;
    if (w.pending == .none) return buf[0..0];

    switch (w.pending) {
        .none => unreachable,
        .length => |n| {
            // Before we claim it. Nothing has moved yet, so a caller
            // who guessed too small can try again with a bigger
            // buffer.
            if (n > buf.len) return error.BodyTooLarge;
            w.claimed = true;
            w.releaseHead();
            const want: usize = @intCast(n);
            w.reader.readSliceAll(buf[0..want]) catch |err| switch (err) {
                error.EndOfStream => return w.giveUp(error.Incomplete),
                error.ReadFailed => return w.giveUp(error.ReadFailed),
            };
            w.pending = .none;
            return buf[0..want];
        },
        .until_close => {
            w.claimed = true;
            w.releaseHead();
            var out: Io.Writer = .fixed(buf);
            _ = w.reader.streamRemaining(&out) catch |err| switch (err) {
                // Through `giveUp`, because the bytes are already read
                // and a close-delimited body has no boundary after it
                // anyway.
                error.WriteFailed => return w.giveUp(error.BodyTooLarge),
                error.ReadFailed => return w.giveUp(error.ReadFailed),
            };
            // The body ended because the connection did. There is no
            // next message on a socket that is going away.
            w.stop();
            return out.buffered();
        },
        .chunked => {
            w.claimed = true;
            w.releaseHead();
            var d: chunked.Decoder = .{
                .consume_trailer = true,
                .trailer_buf = w.trailer_buf,
            };
            var out: usize = 0;
            // What is left once `buf` is full is usually the
            // terminator, which is framing and not body. It still has to
            // be decoded somewhere, so we decode it here. If any of it
            // turns out to be body, the body didn't fit.
            var tail: [64]u8 = undefined;
            while (true) {
                const full = out == buf.len;
                const st = w.decodeStep(&d, if (full) &tail else buf[out..]);
                if (full and st.decoded != 0) {
                    // Doesn't fit, and this is not a short read. This
                    // goes through `giveUp`, unlike the counted case
                    // below, because the decoder has already eaten part
                    // of a chunk and is about to be thrown away, so
                    // nobody can say where the body ends any more.
                    return w.giveUp(error.BodyTooLarge);
                }
                out += st.decoded;
                switch (st.outcome) {
                    .bad => return w.giveUp(error.BadChunk),
                    .done => {
                        w.pending = .none;
                        return buf[0..out];
                    },
                    .more => continue,
                    .need_fill => w.reader.fillMore() catch |err| switch (err) {
                        error.EndOfStream => return w.giveUp(error.Incomplete),
                        error.ReadFailed => return w.giveUp(error.ReadFailed),
                    },
                }
            }
        },
    }
}

/// A body that failed partway through leaves the reader somewhere nobody
/// can account for. Say so instead of scanning from there.
fn giveUp(w: *HeadWindow, err: anytype) @TypeOf(err) {
    w.stop();
    return err;
}

/// We no longer know where the reader is. Both halves get set here so
/// that no path can set one and forget the other: nothing more gets
/// scanned, and no body is pending because nobody can find its end.
fn stop(w: *HeadWindow) void {
    w.finished = true;
    w.pending = .none;
}

/// A reader over the body. Valid until the next take.
pub const BodyReader = struct {
    window: *HeadWindow,
    interface: Io.Reader,
    /// Where chunked bytes get decoded. It is ours because the
    /// destination might have no buffer to lend us, and the source's
    /// might be read-only.
    scratch: []u8,
    left: u64,
    decoder: chunked.Decoder,
    finished: bool,
    err: ?BodyError,

    fn stream(io_r: *Io.Reader, out: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const b: *BodyReader = @alignCast(@fieldParentPtr("interface", io_r));
        const w = b.window;
        if (b.finished) return error.EndOfStream;

        while (true) {
            const buffered = w.reader.buffered();
            if (buffered.len != 0) switch (w.pending) {
                .none => unreachable,
                .length, .until_close => {
                    const room: u64 = if (w.pending == .until_close)
                        std.math.maxInt(u64)
                    else
                        b.left;
                    const want = @min(@as(u64, limit.minInt(buffered.len)), room);
                    const n: usize = @intCast(want);
                    // Tossed only once the destination has them, so a
                    // write that gives out here leaves the reader where
                    // it was and the count still true.
                    try out.writeAll(buffered[0..n]);
                    w.reader.toss(n);
                    if (w.pending != .until_close) {
                        b.left -= want;
                        if (b.left == 0) b.complete();
                    }
                    return n;
                },
                .chunked => {
                    const room = @min(limit.minInt(buffered.len), b.scratch.len);
                    const st = w.decodeStep(&b.decoder, b.scratch[0..room]);
                    if (st.outcome == .bad) {
                        b.fail(error.BadChunk);
                        return error.ReadFailed;
                    }
                    if (st.outcome == .done) b.complete();
                    if (st.decoded != 0) {
                        // The source bytes are already tossed and the
                        // decoder's state is mid-body, so a destination
                        // that gives out here takes the only account of
                        // where the body ends with it. Nobody may read
                        // from this connection again.
                        out.writeAll(b.scratch[0..st.decoded]) catch |err| {
                            b.fail(error.SinkFailed);
                            return err;
                        };
                        return st.decoded;
                    }
                    if (b.finished) return error.EndOfStream;
                    if (st.outcome == .need_fill) break;
                    continue;
                },
            };
            break;
        }

        w.reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => {
                if (w.pending == .until_close) {
                    b.finished = true;
                    w.stop();
                    return error.EndOfStream;
                }
                b.fail(error.Incomplete);
                return error.ReadFailed;
            },
            error.ReadFailed => {
                b.fail(error.ReadFailed);
                return error.ReadFailed;
            },
        };
        return 0;
    }

    fn complete(b: *BodyReader) void {
        b.finished = true;
        b.window.pending = .none;
    }

    fn fail(b: *BodyReader, e: BodyError) void {
        b.err = e;
        b.finished = true;
        b.window.stop();
    }

    /// What actually went wrong, once the interface says ReadFailed.
    pub fn failure(b: *const BodyReader) ?BodyError {
        return b.err;
    }
};

pub const BodyReaderError = error{
    BodyTaken,
    /// `decode_buf` is smaller than two bytes. The reader buffers into
    /// it whatever the framing is, and chunked decodes into it too. An
    /// `Io.Reader` with nowhere to buffer panics inside std the first
    /// time something takes instead of streams.
    NoDecodeBuffer,
};

/// A reader over the body.
///
/// `decode_buf` is the reader's own memory. It buffers there for the
/// `Io.Reader` calls that take instead of stream, and a chunked body
/// decodes in the other half of it. A few hundred bytes is plenty, and
/// two is the minimum.
pub fn bodyReader(w: *HeadWindow, decode_buf: []u8) BodyReaderError!BodyReader {
    if (w.claimed or w.finished) return error.BodyTaken;
    // Chunked bytes are decoded in it, so there is no making progress
    // without one. A counted body never touches it.
    if (w.pending == .chunked and decode_buf.len == 0) return error.NoDecodeBuffer;
    if (w.pending != .none) {
        w.claimed = true;
        w.releaseHead();
    }
    return .{
        .window = w,
        .interface = .{
            .vtable = &.{ .stream = BodyReader.stream },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        },
        .scratch = decode_buf,
        .left = switch (w.pending) {
            .length => |n| n,
            else => 0,
        },
        .decoder = .{
            .consume_trailer = true,
            .trailer_buf = w.trailer_buf,
        },
        .finished = w.pending == .none,
        .err = null,
    };
}

/// Gives up the connection. The head bytes go and we expect no body.
/// Whatever the peer sent after the head stays in the reader for
/// whoever owns it next.
pub fn handOver(w: *HeadWindow) void {
    w.releaseHead();
    w.pending = .none;
}

/// Drops the head bytes so the body starts at the front of the reader.
/// Safe to call twice, since callers get here by more than one route.
pub fn releaseHead(w: *HeadWindow) void {
    w.reader.toss(w.head_len);
    w.head_len = 0;
}

/// Copies the head out of the reader so reading a body can write over
/// it, then points every borrowed slice at the copy instead.
fn keepHead(
    w: *HeadWindow,
    comptime kind: Kind,
    bytes: []const u8,
    head: switch (kind) {
        .request => scan.Head,
        .response => scan.ResponseHead,
    },
) error{HeadTooLarge}!@TypeOf(head) {
    if (bytes.len > w.head_buf.len) return error.HeadTooLarge;
    const dst = w.head_buf[0..bytes.len];
    @memcpy(dst, bytes);

    const base = bytes.ptr;
    const move = struct {
        fn f(from: []const u8, old: [*]const u8, new: []u8) []const u8 {
            const offset = @intFromPtr(from.ptr) - @intFromPtr(old);
            return new[offset..][0..from.len];
        }
    }.f;

    var out = head;
    switch (kind) {
        .request => {
            out.method = move(head.method, base, dst);
            out.target = move(head.target, base, dst);
        },
        .response => out.reason = move(head.reason, base, dst),
    }
    for (w.headers[0..head.headers.len]) |*h| {
        h.name = move(h.name, base, dst);
        h.value = move(h.value, base, dst);
    }
    out.headers = w.headers[0..head.headers.len];
    return out;
}

const testing = std.testing;

const arrival = @import("arrival.zig");
const Shape = arrival.Shape;
const shapes = arrival.shapes;

const Fixture = struct {
    source: arrival.Source(8192, 512),
    headers: [16]scan.Header,
    head_buf: [1024]u8,
    trailer_buf: [512]u8,

    fn init(f: *Fixture, shape: Shape, input: []const u8, max_drain: u64) HeadWindow {
        const reader = f.source.reader(shape, input);
        return HeadWindow.init(reader, .{
            .headers = &f.headers,
            .head_buf = &f.head_buf,
            .trailer_buf = &f.trailer_buf,
            .max_drain = max_drain,
        }) catch unreachable;
    }
};

test "a head_buf smaller than the reader is refused here, not by the caller" {
    var read_buf: [4096]u8 = undefined;
    var src: std.testing.Reader = .init(&read_buf, &.{});
    var headers: [8]scan.Header = undefined;
    var head_buf: [128]u8 = undefined;

    // A head between 128 and 4096 bytes scans fine and then has nowhere
    // to live once a body turns up behind it.
    try testing.expectError(error.HeadBufferTooSmall, HeadWindow.init(&src.interface, .{
        .headers = &headers,
        .head_buf = &head_buf,
    }));

    _ = try HeadWindow.init(&src.interface, .{ .headers = &headers });
}

test "trailers that did not fit are an error, not a short list" {
    var f: Fixture = undefined;
    var w = f.init(
        .whole,
        "POST /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "1\r\na\r\n0\r\nX-Sum: 42\r\nX-Other: yes\r\n\r\n",
        0,
    );
    w.trailer_buf = f.trailer_buf[0..12];

    _ = (try w.takeRequest()).?;
    var buf: [16]u8 = undefined;
    _ = try w.readBody(&buf);

    var storage: [8]scan.Header = undefined;
    try testing.expectError(error.TooManyHeaders, w.trailers(&storage));
}

test "a head and its body" {
    for (shapes) |shape| {
        var f: Fixture = undefined;
        var w = f.init(shape, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello", 0);

        const taken = (try w.takeRequest()).?;
        try testing.expectEqualStrings("POST", taken.head.method);
        try testing.expectEqualStrings("/a", taken.head.target);

        var buf: [32]u8 = undefined;
        try testing.expectEqualStrings("hello", try w.readBody(&buf));
    }
}

test "an unread body ends the window when draining is refused" {
    for (shapes) |shape| {
        var f: Fixture = undefined;
        var w = f.init(shape, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello" ++
            "GET /b HTTP/1.1\r\nHost: x\r\n\r\n", 0);

        _ = (try w.takeRequest()).?;
        // max_drain is zero, so we don't trust anything after the body.
        try testing.expectEqual(@as(?Taken(.request), null), try w.takeRequest());
        try testing.expect(!w.usable());
    }
}

test "an unread body is drained when the caller allows it" {
    for (shapes) |shape| {
        var f: Fixture = undefined;
        var w = f.init(shape, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello" ++
            "GET /b HTTP/1.1\r\nHost: x\r\n\r\n", 1024);

        _ = (try w.takeRequest()).?;
        const second = (try w.takeRequest()).?;
        try testing.expectEqualStrings("GET", second.head.method);
        try testing.expectEqualStrings("/b", second.head.target);
        try testing.expect(w.usable());
    }
}

test "a body over the drain limit is never scanned as the next head" {
    for (shapes) |shape| {
        var f: Fixture = undefined;
        // Token characters, so a scanner reading them sees a request
        // line.
        const stuffing = "x" ** 600;
        var w = f.init(shape, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 600\r\n\r\n" ++
            stuffing ++ "GET /b HTTP/1.1\r\nHost: x\r\n\r\n", 128);

        _ = (try w.takeRequest()).?;
        try testing.expectEqual(@as(?Taken(.request), null), try w.takeRequest());
        try testing.expect(!w.usable());
    }
}

test "a chunked body is drained without a buffer of its own" {
    for (shapes) |shape| {
        var f: Fixture = undefined;
        var w = f.init(shape, "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n0\r\n\r\n" ++ "GET /b HTTP/1.1\r\nHost: x\r\n\r\n", 1024);

        _ = (try w.takeRequest()).?;
        const second = (try w.takeRequest()).?;
        try testing.expectEqualStrings("/b", second.head.target);
    }
}

test "trailers do not outlive the take that produced them" {
    for (shapes) |shape| {
        var f: Fixture = undefined;
        var w = f.init(shape, "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n0\r\nX-Note: one\r\n\r\n" ++ "GET /b HTTP/1.1\r\nHost: x\r\n\r\n", 1024);

        _ = (try w.takeRequest()).?;
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("hello", try w.readBody(&buf));

        var storage: [4]scan.Header = undefined;
        const t = try w.trailers(&storage);
        try testing.expectEqualStrings("X-Note", t[0].name);

        _ = (try w.takeRequest()).?;
        try testing.expectEqualStrings("", w.trailers_raw);
    }
}

test "a refused head leaves no half-set state behind" {
    var f: Fixture = undefined;
    // Content-Length and Transfer-Encoding together: rejected.
    var w = f.init(.whole, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\nhello", 0);

    try testing.expectError(error.Ambiguous, w.takeRequest());
    try testing.expectEqual(body.Framing.none, w.pending);
    try testing.expectEqual(@as(usize, 0), w.head_len);
    try testing.expectEqual(@as(u32, 0), w.generation);
}

test "the body reader streams what readBody would have returned" {
    for (shapes) |shape| {
        var f: Fixture = undefined;
        var w = f.init(shape, "POST /a HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", 0);

        _ = (try w.takeRequest()).?;
        var out: [64]u8 = undefined;
        var sink: Io.Writer = .fixed(&out);
        var scratch: [16]u8 = undefined;
        var b = try w.bodyReader(&scratch);
        _ = try b.interface.streamRemaining(&sink);
        try testing.expectEqualStrings("hello world", sink.buffered());
    }
}
