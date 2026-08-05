//! Chunked decoding, in place. The payload bytes get moved down over
//! the chunk headers, so a single buffer holds both the encoded input
//! and the decoded output.

const std = @import("std");

pub const Error = error{
    /// Not chunked encoding.
    Invalid,
    /// A chunk size doesn't fit in a u64.
    SizeOverflow,
};

pub const Decoder = struct {
    state: State = .size,
    /// Bytes the chunk we are reading still owes us.
    left: u64 = 0,
    /// Set once a chunk size of zero has been seen.
    saw_last: bool = false,
    /// Whether to consume trailer lines after the last chunk. When false,
    /// decoding stops at the last chunk and the trailers stay in the buffer.
    consume_trailer: bool = false,
    hex_digits: u8 = 0,

    const State = enum {
        size,
        extension,
        size_eol,
        data,
        data_cr,
        data_lf,
        trailer,
        trailer_cr,
        done,
    };

    pub const Result = struct {
        /// The decoded bytes, now at the front of the buffer.
        decoded: usize,
        /// Bytes we didn't consume. In the middle of a stream that is
        /// a partial chunk header, which belongs at the front of the
        /// next call. Once `done`, it is whatever comes after the
        /// message.
        leftover: usize,
        done: bool,
    };

    /// Decodes `buf` in place. Call it again with more bytes to carry on.
    pub fn decode(d: *Decoder, buf: []u8) Error!Result {
        var src: usize = 0;
        var dst: usize = 0;

        while (src < buf.len) {
            switch (d.state) {
                .size => {
                    const c = buf[src];
                    const digit: ?u8 = switch (c) {
                        '0'...'9' => c - '0',
                        'a'...'f' => c - 'a' + 10,
                        'A'...'F' => c - 'A' + 10,
                        else => null,
                    };
                    if (digit) |v| {
                        if (d.hex_digits == 16) return error.SizeOverflow;
                        d.left = d.left * 16 + v;
                        d.hex_digits += 1;
                        src += 1;
                        continue;
                    }
                    if (d.hex_digits == 0) return error.Invalid;
                    d.hex_digits = 0;
                    // Only SP, `;` or CR can follow the size. A bare
                    // LF lets two parsers disagree about where the chunk
                    // ends.
                    switch (c) {
                        '\r' => {
                            src += 1;
                            d.state = .size_eol;
                        },
                        ';', ' ', '\t' => d.state = .extension,
                        else => return error.Invalid,
                    }
                },
                .extension => {
                    // No folding here, so no bare LF either.
                    const c = buf[src];
                    if (c == '\r') {
                        src += 1;
                        d.state = .size_eol;
                    } else if (c == '\n') {
                        return error.Invalid;
                    } else {
                        src += 1;
                    }
                },
                .size_eol => {
                    if (buf[src] != '\n') return error.Invalid;
                    src += 1;
                    d.state = d.afterSize();
                },
                .data => {
                    const want: usize = @min(@as(u64, buf.len - src), d.left);
                    if (dst != src) std.mem.copyForwards(u8, buf[dst..][0..want], buf[src..][0..want]);
                    src += want;
                    dst += want;
                    d.left -= want;
                    if (d.left == 0) d.state = .data_cr;
                },
                .data_cr => {
                    if (buf[src] != '\r') return error.Invalid;
                    src += 1;
                    d.state = .data_lf;
                },
                .data_lf => {
                    if (buf[src] != '\n') return error.Invalid;
                    src += 1;
                    d.state = .size;
                },
                .trailer => {
                    const c = buf[src];
                    if (c == '\r') {
                        src += 1;
                        d.state = .trailer_cr;
                    } else if (c == '\n') {
                        src += 1;
                        d.state = .done;
                    } else {
                        // Skip the line.
                        while (src < buf.len and buf[src] != '\n') src += 1;
                        if (src < buf.len) {
                            src += 1;
                            // A blank line after this one ends the trailers.
                            d.state = .trailer;
                            if (src < buf.len and (buf[src] == '\r' or buf[src] == '\n')) continue;
                        }
                    }
                },
                .trailer_cr => {
                    if (buf[src] != '\n') return error.Invalid;
                    src += 1;
                    d.state = .done;
                },
                .done => break,
            }
        }

        return .{
            .decoded = dst,
            .leftover = buf.len - src,
            .done = d.state == .done,
        };
    }

    fn afterSize(d: *Decoder) State {
        if (d.left == 0) {
            d.saw_last = true;
            return if (d.consume_trailer) .trailer else .done;
        }
        return .data;
    }
};

const testing = std.testing;

fn decodeAll(input: []const u8, consume_trailer: bool) !struct { body: []u8, done: bool, leftover: usize } {
    const S = struct {
        var buf: [16 * 1024]u8 = undefined;
    };
    @memcpy(S.buf[0..input.len], input);
    var d: Decoder = .{ .consume_trailer = consume_trailer };
    const r = try d.decode(S.buf[0..input.len]);
    return .{ .body = S.buf[0..r.decoded], .done = r.done, .leftover = r.leftover };
}

test "one chunk" {
    const r = try decodeAll("5\r\nhello\r\n0\r\n\r\n", false);
    try testing.expectEqualStrings("hello", r.body);
    try testing.expect(r.done);
}

test "several chunks" {
    const r = try decodeAll("3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n", false);
    try testing.expectEqualStrings("abcdefg", r.body);
    try testing.expect(r.done);
}

test "chunk extensions are skipped" {
    const r = try decodeAll("5;name=value\r\nhello\r\n0\r\n\r\n", false);
    try testing.expectEqualStrings("hello", r.body);
}

test "uppercase hex" {
    const r = try decodeAll("A\r\n0123456789\r\n0\r\n\r\n", false);
    try testing.expectEqualStrings("0123456789", r.body);
}

test "trailers left in place when not consuming" {
    const r = try decodeAll("1\r\na\r\n0\r\nX: y\r\n\r\n", false);
    try testing.expectEqualStrings("a", r.body);
    try testing.expect(r.done);
    try testing.expectEqual(@as(usize, "X: y\r\n\r\n".len), r.leftover);
}

test "trailers consumed when asked" {
    const r = try decodeAll("1\r\na\r\n0\r\nX: y\r\n\r\n", true);
    try testing.expectEqualStrings("a", r.body);
    try testing.expect(r.done);
    try testing.expectEqual(@as(usize, 0), r.leftover);
}

test "fed one byte at a time" {
    const input = "3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n";
    var buf: [64]u8 = undefined;
    var d: Decoder = .{};
    var out: usize = 0;
    var done = false;
    for (input) |c| {
        buf[out] = c;
        const r = try d.decode(buf[out .. out + 1]);
        out += r.decoded;
        if (r.done) done = true;
    }
    try testing.expectEqualStrings("abcdefg", buf[0..out]);
    try testing.expect(done);
}

test "rejects" {
    const cases = [_][]const u8{
        "\r\n",
        "z\r\nx\r\n",
        "1\r\naX\r\n",
        "1\r\na\r\r",
    };
    for (cases) |c| try testing.expectError(error.Invalid, decodeAll(c, false));
}

test "a size that cannot fit" {
    try testing.expectError(error.SizeOverflow, decodeAll("11111111111111111\r\n", false));
}

test "a bare LF cannot end a chunk size line" {
    try testing.expectError(error.Invalid, decodeAll("5\r\nhello\r\n0\n0\r\n\r\n", false));
    try testing.expectError(error.Invalid, decodeAll("5\nhello\r\n", false));
    try testing.expectError(error.Invalid, decodeAll("5;x\nhello\r\n", false));
}

test "a bare LF cannot end chunk data" {
    try testing.expectError(error.Invalid, decodeAll("1\r\na\n0\r\n\r\n", false));
}
