//! How long a body is. This is where request smuggling starts, so
//! anything ambiguous gets rejected instead of guessed at.

const std = @import("std");
const scan = @import("scan.zig");

pub const Framing = union(enum) {
    none,
    length: u64,
    chunked,
};

pub const Error = error{
    /// Both framing headers at once, one of them twice with different
    /// values, or a length that isn't a number. Any of these lets two
    /// parsers disagree about where the body ends.
    Ambiguous,
    /// Transfer-Encoding doesn't end with chunked.
    UnsupportedEncoding,
};

/// Framing of a request body, by RFC 9112 section 6.
pub fn request(head: scan.Head) Error!Framing {
    var length: ?u64 = null;
    var transfer_encoding: ?[]const u8 = null;

    for (head.headers) |h| {
        if (eqlIgnoreCase(h.name, "content-length")) {
            const v = parseLength(h.value) orelse return error.Ambiguous;
            // Repeating is only fine if it agrees.
            if (length) |prev| {
                if (prev != v) return error.Ambiguous;
            }
            length = v;
        } else if (eqlIgnoreCase(h.name, "transfer-encoding")) {
            if (transfer_encoding != null) return error.Ambiguous;
            transfer_encoding = h.value;
        }
    }

    if (transfer_encoding) |te| {
        // The RFC says Transfer-Encoding wins, but anyone sending both
        // is either confused or probing us. Don't trust either one.
        if (length != null) return error.Ambiguous;
        if (!endsWithChunked(te)) return error.UnsupportedEncoding;
        return .chunked;
    }

    if (length) |v| return if (v == 0) .none else .{ .length = v };
    return .none;
}

/// Whether the connection can carry another request after this one.
pub fn keepAlive(head: scan.Head) bool {
    var explicit: ?bool = null;
    for (head.headers) |h| {
        if (!eqlIgnoreCase(h.name, "connection")) continue;
        var it = std.mem.splitScalar(u8, h.value, ',');
        while (it.next()) |raw| {
            const token = std.mem.trim(u8, raw, " \t");
            if (eqlIgnoreCase(token, "close")) return false;
            if (eqlIgnoreCase(token, "keep-alive")) explicit = true;
        }
    }
    if (explicit) |v| return v;
    return head.minor_version >= 1;
}

/// The last coding must be chunked, and chunked may appear only once.
fn endsWithChunked(value: []const u8) bool {
    var last: []const u8 = "";
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t");
        if (token.len == 0) continue;
        if (eqlIgnoreCase(token, "chunked")) count += 1;
        last = token;
    }
    return count == 1 and eqlIgnoreCase(last, "chunked");
}

/// Digits only. No sign, no whitespace, no radix prefix: a Content-Length
/// that two parsers read differently is a smuggled request.
fn parseLength(value: []const u8) ?u64 {
    if (value.len == 0) return null;
    var n: u64 = 0;
    for (value) |c| {
        if (c < '0' or c > '9') return null;
        n = std.math.mul(u64, n, 10) catch return null;
        n = std.math.add(u64, n, c - '0') catch return null;
    }
    return n;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

const testing = std.testing;

fn parse(bytes: []const u8, headers: []scan.Header) scan.Head {
    return (scan.request(bytes, headers, 0) catch unreachable).?.head;
}

test "no body" {
    var h: [8]scan.Header = undefined;
    try testing.expectEqual(Framing.none, try request(parse("GET / HTTP/1.1\r\n\r\n", &h)));
}

test "content length" {
    var h: [8]scan.Header = undefined;
    const f = try request(parse("POST / HTTP/1.1\r\nContent-Length: 42\r\n\r\n", &h));
    try testing.expectEqual(@as(u64, 42), f.length);
}

test "zero content length is no body" {
    var h: [8]scan.Header = undefined;
    try testing.expectEqual(
        Framing.none,
        try request(parse("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n", &h)),
    );
}

test "chunked" {
    var h: [8]scan.Header = undefined;
    try testing.expectEqual(
        Framing.chunked,
        try request(parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", &h)),
    );
}

test "gzip then chunked" {
    var h: [8]scan.Header = undefined;
    try testing.expectEqual(
        Framing.chunked,
        try request(parse("POST / HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n", &h)),
    );
}

test "both headers is a refusal, not a preference" {
    var h: [8]scan.Header = undefined;
    try testing.expectError(error.Ambiguous, request(parse(
        "POST / HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n",
        &h,
    )));
}

test "two different content lengths" {
    var h: [8]scan.Header = undefined;
    try testing.expectError(error.Ambiguous, request(parse(
        "POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n",
        &h,
    )));
}

test "the same content length twice is fine" {
    var h: [8]scan.Header = undefined;
    const f = try request(parse("POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n", &h));
    try testing.expectEqual(@as(u64, 5), f.length);
}

test "two transfer encodings" {
    var h: [8]scan.Header = undefined;
    try testing.expectError(error.Ambiguous, request(parse(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
        &h,
    )));
}

test "chunked must be last" {
    var h: [8]scan.Header = undefined;
    try testing.expectError(error.UnsupportedEncoding, request(parse(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked, gzip\r\n\r\n",
        &h,
    )));
}

test "a length that is not a number" {
    var h: [8]scan.Header = undefined;
    // "5 " is missing on purpose. The scanner trims OWS, so it gets
    // here as "5" and is a perfectly good length.
    for ([_][]const u8{ "abc", "+5", "0x5", "-1", "", "5a", "1_0", "99999999999999999999" }) |v| {
        var buf: [128]u8 = undefined;
        const bytes = std.fmt.bufPrint(&buf, "POST / HTTP/1.1\r\nContent-Length: {s}\r\n\r\n", .{v}) catch unreachable;
        try testing.expectError(error.Ambiguous, request(parse(bytes, &h)));
    }
}

test "keep alive defaults by version" {
    var h: [8]scan.Header = undefined;
    try testing.expect(keepAlive(parse("GET / HTTP/1.1\r\n\r\n", &h)));
    try testing.expect(!keepAlive(parse("GET / HTTP/1.0\r\n\r\n", &h)));
}

test "connection close and keep-alive" {
    var h: [8]scan.Header = undefined;
    try testing.expect(!keepAlive(parse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n", &h)));
    try testing.expect(keepAlive(parse("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", &h)));
    try testing.expect(!keepAlive(parse("GET / HTTP/1.1\r\nConnection: keep-alive, close\r\n\r\n", &h)));
    try testing.expect(!keepAlive(parse("GET / HTTP/1.1\r\nconnection: CLOSE\r\n\r\n", &h)));
}
