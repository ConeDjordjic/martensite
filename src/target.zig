//! Request-targets: path, query, percent-decoding.

const std = @import("std");

pub const Form = enum {
    /// `/where?q=now`, what a client sends to a server.
    origin,
    /// `http://host/where?q=now`, what a client sends to a proxy.
    absolute,
    /// `host:80`, CONNECT only.
    authority,
    /// `*`, OPTIONS only.
    asterisk,
};

pub const Target = struct {
    form: Form,
    /// Without the query, and still percent-encoded.
    path: []const u8,
    /// Everything after the first `?`. Empty if there wasn't one.
    query: []const u8,
    /// Absolute and authority forms only.
    authority: []const u8,
    /// Absolute form only.
    scheme: []const u8,
};

pub fn parse(raw: []const u8) ?Target {
    if (raw.len == 0) return null;

    if (raw.len == 1 and raw[0] == '*') {
        return .{ .form = .asterisk, .path = "*", .query = "", .authority = "", .scheme = "" };
    }

    if (raw[0] == '/') {
        const cut = std.mem.indexOfScalar(u8, raw, '?');
        return .{
            .form = .origin,
            .path = if (cut) |i| raw[0..i] else raw,
            .query = if (cut) |i| raw[i + 1 ..] else "",
            .authority = "",
            .scheme = "",
        };
    }

    if (std.mem.indexOf(u8, raw, "://")) |sep| {
        const scheme = raw[0..sep];
        if (scheme.len == 0) return null;
        const rest = raw[sep + 3 ..];
        // The authority ends at the path or the query, whichever comes
        // first. `http://host?q=1` is a normal thing to send to a proxy,
        // and stopping only at `/` put the query into the host.
        const end = std.mem.indexOfAny(u8, rest, "/?");
        const authority = if (end) |i| rest[0..i] else rest;
        if (authority.len == 0) return null;
        const after = if (end) |i| rest[i..] else "/";
        const cut = std.mem.indexOfScalar(u8, after, '?');
        return .{
            .form = .absolute,
            // If only a query is left, the path is `/`.
            .path = if (cut) |i| (if (i == 0) "/" else after[0..i]) else after,
            .query = if (cut) |i| after[i + 1 ..] else "",
            .authority = authority,
            .scheme = scheme,
        };
    }

    // Whatever is left is CONNECT only.
    if (std.mem.indexOfAny(u8, raw, "/?#") != null) return null;
    return .{ .form = .authority, .path = "", .query = "", .authority = raw, .scheme = "" };
}

pub const DecodeError = error{
    /// A `%` without two hex digits after it.
    BadEscape,
    /// The result doesn't fit in `out`.
    NoSpace,
};

/// Percent-decodes into `out`. Decoding never makes the input longer,
/// so an `out` the same length as `raw` is always enough.
///
/// `+` is left alone. It only means space in a form body, and decoding
/// it inside a path breaks filenames.
pub fn decode(raw: []const u8, out: []u8) DecodeError![]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (n == out.len) return error.NoSpace;
        const c = raw[i];
        if (c != '%') {
            out[n] = c;
            n += 1;
            i += 1;
            continue;
        }
        if (i + 2 >= raw.len) return error.BadEscape;
        const hi = hex(raw[i + 1]) orelse return error.BadEscape;
        const lo = hex(raw[i + 2]) orelse return error.BadEscape;
        out[n] = hi * 16 + lo;
        n += 1;
        i += 3;
    }
    return out[0..n];
}

fn hex(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Walks `key=value` pairs. The values are still encoded.
pub const Pairs = struct {
    rest: []const u8,

    pub const Pair = struct { name: []const u8, value: []const u8 };

    pub fn init(query: []const u8) Pairs {
        return .{ .rest = query };
    }

    pub fn next(p: *Pairs) ?Pair {
        while (p.rest.len != 0) {
            const end = std.mem.indexOfAny(u8, p.rest, "&;") orelse p.rest.len;
            const item = p.rest[0..end];
            p.rest = if (end == p.rest.len) "" else p.rest[end + 1 ..];
            if (item.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, item, '=');
            return .{
                .name = if (eq) |i| item[0..i] else item,
                .value = if (eq) |i| item[i + 1 ..] else "",
            };
        }
        return null;
    }
};

const testing = std.testing;

test "origin form" {
    const t = parse("/where?q=now").?;
    try testing.expectEqual(Form.origin, t.form);
    try testing.expectEqualStrings("/where", t.path);
    try testing.expectEqualStrings("q=now", t.query);
}

test "origin form with no query" {
    const t = parse("/where").?;
    try testing.expectEqualStrings("/where", t.path);
    try testing.expectEqualStrings("", t.query);
}

test "an empty query after the question mark" {
    const t = parse("/where?").?;
    try testing.expectEqualStrings("/where", t.path);
    try testing.expectEqualStrings("", t.query);
}

test "a question mark in the query is not a second split" {
    const t = parse("/a?b=c?d").?;
    try testing.expectEqualStrings("/a", t.path);
    try testing.expectEqualStrings("b=c?d", t.query);
}

test "absolute form" {
    const t = parse("http://example.com/where?q=now").?;
    try testing.expectEqual(Form.absolute, t.form);
    try testing.expectEqualStrings("http", t.scheme);
    try testing.expectEqualStrings("example.com", t.authority);
    try testing.expectEqualStrings("/where", t.path);
    try testing.expectEqualStrings("q=now", t.query);
}

test "absolute form with a query and no path" {
    // What a proxy gets. The authority ends before the query.
    const t = parse("http://example.com?q=1").?;
    try testing.expectEqual(Form.absolute, t.form);
    try testing.expectEqualStrings("example.com", t.authority);
    try testing.expectEqualStrings("/", t.path);
    try testing.expectEqualStrings("q=1", t.query);
}

test "absolute form with no path" {
    const t = parse("http://example.com").?;
    try testing.expectEqualStrings("example.com", t.authority);
    try testing.expectEqualStrings("/", t.path);
}

test "authority form, which is CONNECT only" {
    const t = parse("example.com:443").?;
    try testing.expectEqual(Form.authority, t.form);
    try testing.expectEqualStrings("example.com:443", t.authority);
}

test "asterisk form" {
    const t = parse("*").?;
    try testing.expectEqual(Form.asterisk, t.form);
}

test "rubbish" {
    try testing.expectEqual(@as(?Target, null), parse(""));
    try testing.expectEqual(@as(?Target, null), parse("://example.com/"));
    try testing.expectEqual(@as(?Target, null), parse("http:///where"));
    try testing.expectEqual(@as(?Target, null), parse("not/a/target"));
}

test "decoding" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/a b", try decode("/a%20b", &buf));
    try testing.expectEqualStrings("/ä", try decode("/%C3%A4", &buf));
    try testing.expectEqualStrings("/plain", try decode("/plain", &buf));
    try testing.expectEqualStrings("%", try decode("%25", &buf));
}

test "a plus is not a space in a path" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a+b", try decode("a+b", &buf));
}

test "bad escapes" {
    var buf: [64]u8 = undefined;
    for ([_][]const u8{ "%", "%2", "%zz", "%2z", "/a%" }) |bad| {
        try testing.expectError(error.BadEscape, decode(bad, &buf));
    }
}

test "decoding a null byte is allowed" {
    var buf: [64]u8 = undefined;
    const out = try decode("a%00b", &buf);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(@as(u8, 0), out[1]);
}

test "no space" {
    var buf: [2]u8 = undefined;
    try testing.expectError(error.NoSpace, decode("abc", &buf));
}

test "query pairs" {
    var it: Pairs = .init("a=1&b=2&flag&c=");
    var got: [4]Pairs.Pair = undefined;
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) got[n] = p;
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("a", got[0].name);
    try testing.expectEqualStrings("1", got[0].value);
    try testing.expectEqualStrings("flag", got[2].name);
    try testing.expectEqualStrings("", got[2].value);
    try testing.expectEqualStrings("c", got[3].name);
    try testing.expectEqualStrings("", got[3].value);
}

test "empty and doubled separators" {
    var it: Pairs = .init("&&a=1&&");
    try testing.expectEqualStrings("a", it.next().?.name);
    try testing.expectEqual(@as(?Pairs.Pair, null), it.next());
}

test "no query at all" {
    var it: Pairs = .init("");
    try testing.expectEqual(@as(?Pairs.Pair, null), it.next());
}
