//! Scans request and response heads. Every slice points into the
//! caller's bytes. Nothing is copied and nothing is allocated.

const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// The methods we have names for. Anything else is still valid, and
/// `head.method` always has the raw bytes.
pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,
    PATCH,

    /// Null if it isn't one of the above.
    pub fn parse(bytes: []const u8) ?Method {
        return switch (bytes.len) {
            3 => if (eq(bytes, "GET")) .GET else if (eq(bytes, "PUT")) .PUT else null,
            4 => if (eq(bytes, "POST")) .POST else if (eq(bytes, "HEAD")) .HEAD else null,
            5 => if (eq(bytes, "PATCH")) .PATCH else if (eq(bytes, "TRACE")) .TRACE else null,
            6 => if (eq(bytes, "DELETE")) .DELETE else null,
            7 => if (eq(bytes, "CONNECT")) .CONNECT else if (eq(bytes, "OPTIONS")) .OPTIONS else null,
            else => null,
        };
    }

    /// A HEAD response describes a body without sending one.
    pub fn expectsBody(m: Method) bool {
        return m != .HEAD;
    }

    fn eq(a: []const u8, comptime b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

pub const Head = struct {
    method: []const u8,
    target: []const u8,
    minor_version: u8,
    headers: []const Header,
};

pub const Scanned = struct {
    head: Head,
    /// Length of the head. The body starts here.
    len: usize,
};

pub const Error = error{
    /// These bytes are never going to be a head.
    Invalid,
    /// The header array is full. Try again with a bigger one.
    TooManyHeaders,
};

/// Scans a request head. Null means these bytes could still turn into
/// one.
///
/// `last_len` is what you passed to the last incomplete call, or 0. It
/// saves us scanning what we already looked at.
pub fn request(bytes: []const u8, headers: []Header, last_len: usize) Error!?Scanned {
    if (last_len != 0 and findTerminator(bytes, last_len) == null) return null;

    var s: Scanner = .{ .bytes = bytes };

    const method = try s.token(' ') orelse return null;
    if (method.len == 0) return error.Invalid;
    for (method) |c| if (!isTokenChar(c)) return error.Invalid;

    const target = try s.token(' ') orelse return null;
    if (target.len == 0) return error.Invalid;

    const minor_version = try s.version() orelse return null;
    if (!try s.crlf()) return null;

    var n: usize = 0;
    while (true) {
        if (s.i >= bytes.len) return null;
        if (bytes[s.i] == '\r' or bytes[s.i] == '\n') {
            if (!try s.crlf()) return null;
            return .{
                .head = .{
                    .method = method,
                    .target = target,
                    .minor_version = minor_version,
                    .headers = headers[0..n],
                },
                .len = s.i,
            };
        }
        if (n == headers.len) return error.TooManyHeaders;
        headers[n] = try s.header() orelse return null;
        n += 1;
    }
}

const Scanner = struct {
    bytes: []const u8,
    i: usize = 0,

    fn token(s: *Scanner, delimiter: u8) Error!?[]const u8 {
        const start = s.i;
        while (s.i < s.bytes.len) : (s.i += 1) {
            const c = s.bytes[s.i];
            if (c == delimiter) {
                const out = s.bytes[start..s.i];
                s.i += 1;
                return out;
            }
            if (c == '\r' or c == '\n' or c == 0) return error.Invalid;
        }
        return null;
    }

    fn version(s: *Scanner) Error!?u8 {
        const prefix = "HTTP/1.";
        if (s.bytes.len - s.i < prefix.len + 1) {
            // Only incomplete if what is there still matches.
            const have = s.bytes[s.i..];
            const n = @min(have.len, prefix.len);
            if (!std.mem.eql(u8, have[0..n], prefix[0..n])) return error.Invalid;
            return null;
        }
        if (!std.mem.eql(u8, s.bytes[s.i..][0..prefix.len], prefix)) return error.Invalid;
        s.i += prefix.len;
        const c = s.bytes[s.i];
        if (c < '0' or c > '9') return error.Invalid;
        s.i += 1;
        return c - '0';
    }

    fn crlf(s: *Scanner) Error!bool {
        if (s.i >= s.bytes.len) return false;
        if (s.bytes[s.i] == '\r') {
            s.i += 1;
            if (s.i >= s.bytes.len) return false;
            if (s.bytes[s.i] != '\n') return error.Invalid;
            s.i += 1;
            return true;
        }
        if (s.bytes[s.i] == '\n') {
            s.i += 1;
            return true;
        }
        return error.Invalid;
    }

    fn header(s: *Scanner) Error!?Header {
        // Folded headers get rejected. They smuggle a second header
        // past whoever read the head first.
        const first = s.bytes[s.i];
        if (first == ' ' or first == '\t') return error.Invalid;

        const name_start = s.i;
        while (true) {
            if (s.i >= s.bytes.len) return null;
            const c = s.bytes[s.i];
            if (c == ':') break;
            if (!isTokenChar(c)) return error.Invalid;
            s.i += 1;
        }
        if (s.i == name_start) return error.Invalid;
        const name = s.bytes[name_start..s.i];
        s.i += 1;

        while (s.i < s.bytes.len and (s.bytes[s.i] == ' ' or s.bytes[s.i] == '\t')) s.i += 1;

        const value_start = s.i;
        s.i += try scanValue(s.bytes[s.i..]) orelse return null;
        var end = s.i;
        while (end > value_start and (s.bytes[end - 1] == ' ' or s.bytes[end - 1] == '\t')) end -= 1;
        const value = s.bytes[value_start..end];

        if (!try s.crlf()) return null;
        return .{ .name = name, .value = value };
    }
};

// 16, not the 32 that suggestVectorLength gives. Header values are
// short, so 32-byte chunks leave most of their lanes unused and measured
// slower on a browser-sized head.
const vector_len = 16;
const V = @Vector(vector_len, u8);

/// Bytes up to the CR or LF ending a header value, or null if it hasn't
/// ended. Rejects control characters.
fn scanValue(bytes: []const u8) Error!?usize {
    var i: usize = 0;

    if (vector_len > 1) {
        while (i + vector_len <= bytes.len) : (i += vector_len) {
            const chunk: V = bytes[i..][0..vector_len].*;
            // Everything under 0x20 except tab is illegal, and so is
            // DEL, so a single compare finds both the end of the line
            // and the junk.
            const interesting = interestingLanes(chunk);
            if (@reduce(.Or, interesting)) {
                const mask: std.meta.Int(.unsigned, vector_len) = @bitCast(interesting);
                i += @ctz(mask);
                const c = bytes[i];
                if (c == '\r' or c == '\n') return i;
                return error.Invalid;
            }
        }
    }

    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '\r' or c == '\n') return i;
        if (c < 0x20 and c != '\t') return error.Invalid;
        if (c == 0x7f) return error.Invalid;
    }
    return null;
}

fn interestingLanes(chunk: V) @Vector(vector_len, bool) {
    const low = chunk < @as(V, @splat(0x20));
    const tab = chunk == @as(V, @splat('\t'));
    const del = chunk == @as(V, @splat(0x7f));
    return (low & ~tab) | del;
}

/// RFC 9110 token characters.
fn isTokenChar(c: u8) bool {
    return token_chars[c];
}

const token_chars = blk: {
    var t = [_]bool{false} ** 256;
    for ("!#$%&'*+-.^_`|~") |c| t[c] = true;
    for ('0'..'9' + 1) |c| t[c] = true;
    for ('a'..'z' + 1) |c| t[c] = true;
    for ('A'..'Z' + 1) |c| t[c] = true;
    break :blk t;
};

/// Where the head ends, skipping what a previous call already saw.
fn findTerminator(bytes: []const u8, last_len: usize) ?usize {
    // Back up a bit, so a terminator sitting across the boundary is
    // still found.
    const start = if (last_len >= 3) last_len - 3 else 0;
    var i = start;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] != '\n') continue;
        if (i >= 1 and bytes[i - 1] == '\n') return i + 1;
        if (i >= 3 and bytes[i - 1] == '\r' and bytes[i - 2] == '\n' and bytes[i - 3] == '\r') return i + 1;
    }
    return null;
}

const testing = std.testing;

test "methods" {
    try testing.expectEqual(Method.GET, Method.parse("GET").?);
    try testing.expectEqual(Method.OPTIONS, Method.parse("OPTIONS").?);
    try testing.expectEqual(Method.PATCH, Method.parse("PATCH").?);
    // Methods are case sensitive.
    try testing.expectEqual(@as(?Method, null), Method.parse("get"));
    try testing.expectEqual(@as(?Method, null), Method.parse("PROPFIND"));
    try testing.expectEqual(@as(?Method, null), Method.parse(""));
    try testing.expect(!Method.HEAD.expectsBody());
    try testing.expect(Method.GET.expectsBody());
}

test "a plain GET" {
    var headers: [8]Header = undefined;
    const bytes = "GET /hello HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n";
    const s = (try request(bytes, &headers, 0)).?;
    try testing.expectEqualStrings("GET", s.head.method);
    try testing.expectEqualStrings("/hello", s.head.target);
    try testing.expectEqual(@as(u8, 1), s.head.minor_version);
    try testing.expectEqual(@as(usize, 2), s.head.headers.len);
    try testing.expectEqualStrings("Host", s.head.headers[0].name);
    try testing.expectEqualStrings("example.com", s.head.headers[0].value);
    try testing.expectEqualStrings("*/*", s.head.headers[1].value);
    try testing.expectEqual(bytes.len, s.len);
}

test "no headers" {
    var headers: [8]Header = undefined;
    const s = (try request("GET / HTTP/1.0\r\n\r\n", &headers, 0)).?;
    try testing.expectEqual(@as(u8, 0), s.head.minor_version);
    try testing.expectEqual(@as(usize, 0), s.head.headers.len);
}

test "the head stops where the body starts" {
    var headers: [8]Header = undefined;
    const bytes = "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    const s = (try request(bytes, &headers, 0)).?;
    try testing.expectEqualStrings("hello", bytes[s.len..]);
}

test "incomplete at every prefix" {
    const bytes = "GET /x HTTP/1.1\r\nHost: a\r\n\r\n";
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        var headers: [8]Header = undefined;
        try testing.expectEqual(@as(?Scanned, null), try request(bytes[0..i], &headers, 0));
    }
}

test "value whitespace is trimmed both ends" {
    var headers: [8]Header = undefined;
    const s = (try request("GET / HTTP/1.1\r\nX: \t v \t \r\n\r\n", &headers, 0)).?;
    try testing.expectEqualStrings("v", s.head.headers[0].value);
}

test "empty value" {
    var headers: [8]Header = undefined;
    const s = (try request("GET / HTTP/1.1\r\nX:\r\n\r\n", &headers, 0)).?;
    try testing.expectEqualStrings("X", s.head.headers[0].name);
    try testing.expectEqualStrings("", s.head.headers[0].value);
}

test "bare newlines are accepted as line endings" {
    var headers: [8]Header = undefined;
    const s = (try request("GET / HTTP/1.1\nHost: a\n\n", &headers, 0)).?;
    try testing.expectEqualStrings("a", s.head.headers[0].value);
}

test "continuation lines are refused" {
    var headers: [8]Header = undefined;
    try testing.expectError(error.Invalid, request("GET / HTTP/1.1\r\nX: a\r\n b\r\n\r\n", &headers, 0));
}

test "rejects" {
    var headers: [8]Header = undefined;
    const cases = [_][]const u8{
        "GET / HTTP/1.1\r\nHost\x00: a\r\n\r\n",
        "GET / HTTP/1.1\r\n: empty\r\n\r\n",
        "GET / HTTP/2.0\r\n\r\n",
        "GET / HTTPS/1.1\r\n\r\n",
        " / HTTP/1.1\r\n\r\n",
        "GET / HTTP/1.1\r\nX: a\rb\r\n\r\n",
    };
    for (cases) |c| try testing.expectError(error.Invalid, request(c, &headers, 0));
}

test "too many headers" {
    var headers: [1]Header = undefined;
    try testing.expectError(
        error.TooManyHeaders,
        request("GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\n\r\n", &headers, 0),
    );
}

test "last_len skips what was already scanned" {
    var headers: [8]Header = undefined;
    const partial = "GET / HTTP/1.1\r\nHost: a\r\n";
    const whole = partial ++ "\r\n";
    try testing.expectEqual(@as(?Scanned, null), try request(partial, &headers, 0));
    const s = (try request(whole, &headers, partial.len)).?;
    try testing.expectEqual(whole.len, s.len);
}

// The only two places we are stricter than a permissive parser. A test
// counts them, so a third one can't turn up without somebody noticing.

test "one space between request line fields, not a run" {
    var headers: [8]Header = undefined;
    try testing.expectError(error.Invalid, request("POST /  HTTP/1.1\r\n\r\n", &headers, 0));
}

test "a fold is refused as soon as it appears" {
    var headers: [8]Header = undefined;
    // Still incomplete, so a lenient parser can't see the fold yet.
    try testing.expectError(error.Invalid, request("P / HTTP/1.1\nY:=\n \n", &headers, 0));
}
