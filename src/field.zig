//! Writing header lines, and reading the values that are lists.
//!
//! Three things write a field list: a response head, a request head and
//! the trailers after a chunked body. All of them have to check before
//! they write anything, because half a head on the wire becomes the
//! start of whatever goes out next.

const std = @import("std");
const Io = std.Io;

const scan = @import("scan.zig");
const body = @import("body.zig");

/// The same `Header` the Scanner reads, so we can read back what we write.
pub const Header = scan.Header;

pub const Policy = enum {
    /// Anything the Scanner accepts.
    header,
    /// The same, minus anything we already acted on. Trailers come
    /// after the body, so a `Content-Length` in one contradicts framing
    /// we have already used.
    trailer,
};

pub const Error = error{
    /// Bad name, a value the Scanner would reject, or a field that is
    /// not allowed in a trailer.
    Invalid,
};

/// Checks every field and writes nothing. Call it before the first byte
/// of a head goes out.
pub fn check(fields: []const Header, policy: Policy) Error!void {
    for (fields) |f| {
        if (!scan.validFieldName(f.name) or !scan.validFieldValue(f.value)) return error.Invalid;
        if (policy == .trailer and forbiddenInTrailer(f.name)) return error.Invalid;
    }
}

/// Writes one line per field. Call `check` first, because this doesn't
/// check anything.
pub fn write(w: *Io.Writer, fields: []const Header) Io.Writer.Error!void {
    for (fields) |f| {
        try w.writeAll(f.name);
        try w.writeAll(": ");
        try w.writeAll(f.value);
        try w.writeAll("\r\n");
    }
}

/// Everything in a head after the start line, for either side.
pub const Head = struct {
    fields: []const Header,
    body: body.Outgoing,
    /// What the response does with its body. Null for a request.
    answer: ?body.Answer = null,
    /// Written as a Date header unless the fields already have one.
    date: ?[]const u8 = null,
    /// Adds `Connection: close` unless the fields already say so.
    close: bool = false,
};

pub const HeadError = error{
    /// A bad header name, or a value the Scanner would reject. Writing
    /// one lets the caller add headers of their own, or a whole second
    /// message.
    InvalidHeader,
    /// The framing headers say something we would refuse to read: both
    /// `Content-Length` and `Transfer-Encoding`, two lengths that
    /// disagree, a length that isn't the body's, or any framing on a
    /// head that can't have a body.
    AmbiguousFraming,
};

/// Everything about a head that can be refused, decided before a byte
/// goes out. `writeHead` needs what this returns.
pub fn checkHead(h: Head) HeadError!body.Plan {
    check(h.fields, .header) catch return error.InvalidHeader;
    if (h.date) |d| {
        if (!scan.validFieldValue(d)) return error.InvalidHeader;
    }
    return body.outgoing(h.fields, h.body, h.answer) catch error.AmbiguousFraming;
}

/// The fields, the framing header from `plan`, Date, Connection and the
/// blank line. The start line is the caller's job.
pub fn writeHead(w: *Io.Writer, h: Head, plan: body.Plan) Io.Writer.Error!void {
    try write(w, h.fields);
    switch (plan.line) {
        .none => {},
        .length => |n| try w.print("Content-Length: {d}\r\n", .{n}),
        .chunked => try w.writeAll("Transfer-Encoding: chunked\r\n"),
    }
    if (h.date) |d| {
        if (!has(h.fields, "date")) try w.print("Date: {s}\r\n", .{d});
    }
    if (h.close and !body.connectionHas(.ours(h.fields), "close")) {
        try w.writeAll("Connection: close\r\n");
    }
    try w.writeAll("\r\n");
}

/// RFC 9112 §3.2. A request has at most one Host, and it is a host with
/// an optional port. `required` is for HTTP/1.1, where it can't be left
/// out. Both sides use this, so a Client won't send a Host a Server
/// would refuse.
pub fn checkHost(fields: []const Header, required: bool) error{BadHost}!void {
    var found: ?[]const u8 = null;
    for (fields) |f| {
        if (!std.ascii.eqlIgnoreCase(f.name, "host")) continue;
        if (found != null) return error.BadHost;
        found = f.value;
    }
    const value = found orelse return if (required) error.BadHost;
    if (!validHost(value)) return error.BadHost;
}

/// `uri-host [ ":" port ]`, or empty. A client sends an empty Host when
/// the target has no authority.
pub fn validHost(value: []const u8) bool {
    if (value.len == 0) return true;
    var port: ?[]const u8 = null;
    if (value[0] == '[') {
        const close = std.mem.indexOfScalar(u8, value, ']') orelse return false;
        if (!validIp6(value[1..close])) return false;
        const rest = value[close + 1 ..];
        if (rest.len != 0) {
            if (rest[0] != ':') return false;
            port = rest[1..];
        }
    } else {
        const cut = std.mem.indexOfScalar(u8, value, ':');
        if (!validRegName(if (cut) |i| value[0..i] else value)) return false;
        if (cut) |i| port = value[i + 1 ..];
    }
    if (port) |p| {
        if (p.len == 0) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn validIp6(text: []const u8) bool {
    // The longest IPv6 address with an IPv4 tail. std's parser counts
    // with a u8, so nothing longer gets near it.
    if (text.len > 45) return false;
    _ = std.Io.net.Ip6Address.parse(text, 0) catch return false;
    return true;
}

/// Also covers IPv4, which is a reg-name as far as the characters go.
fn validRegName(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (std.ascii.isAlphanumeric(c)) continue;
        if (std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=", c) != null) continue;
        if (c != '%') return false;
        if (i + 2 >= text.len or !std.ascii.isHex(text[i + 1]) or !std.ascii.isHex(text[i + 2])) return false;
        i += 2;
    }
    return true;
}

/// The items of a comma-separated value like `Accept-Encoding: gzip;q=0.8, br`.
/// It allocates nothing and every slice points into `value`.
///
/// This reads RFC 9110 §5.6 lists of tokens with parameters. An item is
/// `token [ "/" token ] [ "=" value ]`, then any number of
/// `; name [ "=" value ]`, where a value is a token or a quoted string.
/// Whitespace is allowed around `,` and `;` and nowhere else. Empty items
/// and empty parameters are skipped.
///
/// Values that aren't built from tokens, like ETags in `If-None-Match` or
/// the URLs in `Link`, are not this kind of list and come back
/// `Malformed`.
pub fn list(value: []const u8) List {
    return .{ .rest = value };
}

pub const ListError = error{
    /// An item that doesn't fit the grammar, like an unterminated quote
    /// or `=` with nothing after it. The items before it were fine.
    /// Nothing after it comes back, because once a quote is in doubt
    /// there is no telling where the next item starts.
    Malformed,
};

pub const List = struct {
    rest: []const u8,

    pub const Item = struct {
        /// `gzip`, `no-cache`, `text/html`.
        token: []const u8,
        /// What followed `=`, as it was sent. Still quoted if it was.
        /// Empty if there was no `=`.
        value: []const u8,
        /// The parameters, starting at the first `;`. Walk them with
        /// `params`.
        raw_params: []const u8,

        pub fn params(i: Item) Params {
            return .{ .rest = i.raw_params };
        }
    };

    /// The next item, or null at the end. After `Malformed` it returns
    /// null.
    pub fn next(l: *List) ListError!?Item {
        const s = l.rest;
        var i = skipOws(s, 0);
        while (i < s.len and s[i] == ',') i = skipOws(s, i + 1);
        if (i == s.len) {
            l.rest = "";
            return null;
        }
        errdefer l.rest = "";

        const token_start = i;
        i = try tokenEnd(s, i);
        if (i < s.len and s[i] == '/') i = try tokenEnd(s, i + 1);
        const token = s[token_start..i];

        var value: []const u8 = "";
        if (i < s.len and s[i] == '=') {
            const value_start = i + 1;
            i = try valueEnd(s, value_start);
            value = s[value_start..i];
        }

        const params_start = i;
        while (true) {
            const j = skipOws(s, i);
            if (j == s.len or s[j] == ',') break;
            if (s[j] != ';') return error.Malformed;
            i = (try param(s, j + 1)).end;
        }

        const after = skipOws(s, i);
        l.rest = if (after == s.len) "" else s[after + 1 ..];
        return .{ .token = token, .value = value, .raw_params = s[params_start..i] };
    }
};

/// Parameters of an item that `List.next` already checked, so walking
/// them can't fail.
pub const Params = struct {
    rest: []const u8,

    pub const Param = struct {
        /// Compare it case-insensitively. RFC 9110 says parameter names
        /// are.
        name: []const u8,
        /// As it was sent, still quoted if it was. Empty if there was no
        /// `=`. `unquote` gives you the bytes.
        value: []const u8,
    };

    pub fn next(p: *Params) ?Param {
        while (true) {
            const i = skipOws(p.rest, 0);
            if (i == p.rest.len) return null;
            // Checked already, so this is a `;`.
            const found = param(p.rest, i + 1) catch unreachable;
            p.rest = p.rest[found.end..];
            if (found.param) |got| return got;
        }
    }
};

/// A quoted string's bytes, with the quotes gone and each `\x` turned
/// into `x`. A value that isn't quoted comes back as it is, without
/// touching `buf`. The result is never longer than `value`.
pub fn unquote(value: []const u8, buf: []u8) error{ Malformed, NoSpaceLeft }![]const u8 {
    if (value.len == 0 or value[0] != '"') return value;
    if ((quotedEnd(value, 0) catch return error.Malformed) != value.len) return error.Malformed;
    var n: usize = 0;
    var i: usize = 1;
    while (i < value.len - 1) : (i += 1) {
        if (value[i] == '\\') i += 1;
        if (n == buf.len) return error.NoSpaceLeft;
        buf[n] = value[i];
        n += 1;
    }
    return buf[0..n];
}

fn skipOws(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return i;
}

/// Where a token that starts at `from` ends. It can't be empty.
fn tokenEnd(s: []const u8, from: usize) ListError!usize {
    var i = from;
    while (i < s.len and scan.isTokenChar(s[i])) i += 1;
    if (i == from) return error.Malformed;
    return i;
}

/// A token or a quoted string.
fn valueEnd(s: []const u8, from: usize) ListError!usize {
    if (from < s.len and s[from] == '"') return quotedEnd(s, from);
    return tokenEnd(s, from);
}

/// Just past the closing quote of the quoted string at `from`.
fn quotedEnd(s: []const u8, from: usize) ListError!usize {
    var i = from + 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"') return i + 1;
        if (c == '\\') {
            i += 1;
            if (i == s.len) return error.Malformed;
        }
        // RFC 9110 qdtext and quoted-pair both leave out controls
        // other than tab.
        if ((s[i] < 0x20 and s[i] != '\t') or s[i] == 0x7f) return error.Malformed;
    }
    return error.Malformed;
}

/// One parameter after a `;`, or none if it was empty.
fn param(s: []const u8, from: usize) ListError!struct { param: ?Params.Param, end: usize } {
    const i = skipOws(s, from);
    if (i == s.len or s[i] == ',' or s[i] == ';') return .{ .param = null, .end = i };
    const name_end = try tokenEnd(s, i);
    if (name_end == s.len or s[name_end] != '=') {
        return .{ .param = .{ .name = s[i..name_end], .value = "" }, .end = name_end };
    }
    const end = try valueEnd(s, name_end + 1);
    return .{ .param = .{ .name = s[i..name_end], .value = s[name_end + 1 .. end] }, .end = end };
}

fn has(fields: []const Header, name: []const u8) bool {
    for (fields) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, name)) return true;
    }
    return false;
}

fn forbiddenInTrailer(name: []const u8) bool {
    const forbidden = [_][]const u8{
        "transfer-encoding", "content-length", "host",  "trailer",
        "connection",        "te",             "range", "expect",
    };
    for (forbidden) |f| {
        if (std.ascii.eqlIgnoreCase(name, f)) return true;
    }
    return false;
}

const testing = std.testing;

test "a field the Scanner would refuse is refused here" {
    for ([_]Header{
        .{ .name = "", .value = "1" },
        .{ .name = "X Thing", .value = "1" },
        .{ .name = "X:Thing", .value = "1" },
        .{ .name = "X", .value = "a\r\nY: 2" },
        .{ .name = "X", .value = "a\x7f" },
    }) |bad| {
        try testing.expectError(error.Invalid, check(&.{bad}, .header));
    }
}

test "a trailer may not change what the framing already decided" {
    for ([_][]const u8{ "Content-Length", "Transfer-Encoding", "Connection", "Host", "TE" }) |name| {
        const f: Header = .{ .name = name, .value = "1" };
        // Fine in a head, not allowed in a trailer.
        try check(&.{f}, .header);
        try testing.expectError(error.Invalid, check(&.{f}, .trailer));
    }
}

test "checking says nothing about the writer" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(error.Invalid, check(&.{.{ .name = "X", .value = "a\rb" }}, .header));
    try testing.expectEqualStrings("", w.buffered());

    try write(&w, &.{ .{ .name = "A", .value = "1" }, .{ .name = "B", .value = "2" } });
    try testing.expectEqualStrings("A: 1\r\nB: 2\r\n", w.buffered());
}

test "a head we write reads back with the framing we meant" {
    const H = Header;
    const header_sets = [_][]const H{
        &.{},
        &.{.{ .name = "Content-Length", .value = "5" }},
        &.{.{ .name = "Content-Length", .value = "0" }},
        &.{ .{ .name = "Content-Length", .value = "5" }, .{ .name = "Content-Length", .value = "5" } },
        &.{.{ .name = "Transfer-Encoding", .value = "chunked" }},
        &.{.{ .name = "Transfer-Encoding", .value = "gzip, chunked" }},
        &.{.{ .name = "Transfer-Encoding", .value = "gzip" }},
        &.{ .{ .name = "Content-Length", .value = "5" }, .{ .name = "Transfer-Encoding", .value = "chunked" } },
        &.{.{ .name = "Connection", .value = "close" }},
    };
    const outs = [_]body.Outgoing{
        .{ .complete = "" },
        .{ .complete = "hello" },
        .{ .complete = "5\r\nhello\r\n0\r\n\r\n" },
        .{ .length = 0 },
        .{ .length = 5 },
        .chunked,
    };
    const Exchange = struct { method: ?scan.Method, status: ?u16 };
    const exchanges = [_]Exchange{
        .{ .method = .POST, .status = null },
        .{ .method = .GET, .status = 200 },
        .{ .method = null, .status = 200 },
        .{ .method = .HEAD, .status = 200 },
        .{ .method = .GET, .status = 204 },
        .{ .method = .GET, .status = 304 },
        .{ .method = .GET, .status = 100 },
        .{ .method = .GET, .status = 101 },
        .{ .method = .CONNECT, .status = 200 },
        .{ .method = .CONNECT, .status = 502 },
    };

    var accepted: usize = 0;
    for (header_sets) |fields| for (outs) |out| for (exchanges) |ex| {
        const h: Head = .{
            .fields = fields,
            .body = out,
            .answer = if (ex.status) |st| body.answer(ex.method, st) else null,
        };
        const plan = checkHead(h) catch continue;
        accepted += 1;

        var buf: [256]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        if (ex.status) |st| try w.print("HTTP/1.1 {d} X\r\n", .{st}) else try w.writeAll("POST / HTTP/1.1\r\n");
        try writeHead(&w, h, plan);

        var scanned: [16]Header = undefined;
        const framing = if (ex.status != null)
            try body.response((try scan.response(w.buffered(), &scanned, 0)).?.head, ex.method)
        else
            try body.request((try scan.request(w.buffered(), &scanned, 0)).?.head);

        switch (plan.mode) {
            .discard => try testing.expectEqual(body.Framing.none, framing),
            .chunked => try testing.expectEqual(body.Framing.chunked, framing),
            .length => |n| switch (framing) {
                .none => try testing.expectEqual(@as(u64, 0), n),
                .length => |m| try testing.expectEqual(n, m),
                // Chunked by the caller, and sent as it is.
                .chunked => try testing.expect(out == .complete),
                .until_close => return error.TestUnexpectedResult,
            },
        }
    };
    // So a change that refuses everything can't pass this quietly.
    try testing.expect(accepted > 40);
}

test "Date and Connection go out once" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const h: Head = .{
        .fields = &.{ .{ .name = "Date", .value = "mine" }, .{ .name = "Connection", .value = "close" } },
        .body = .{ .complete = "" },
        .answer = .body,
        .date = "ours",
        .close = true,
    };
    try writeHead(&w, h, try checkHead(h));
    try testing.expectEqualStrings("Date: mine\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", w.buffered());
}

test "a head with a value the Scanner refuses is not written" {
    for ([_][]const u8{ "a\r\nX-Evil: 1", "a\nX-Evil: 1", "a\x00b", "a\x01b", "a\x7fb" }) |bad| {
        try testing.expectError(error.InvalidHeader, checkHead(.{
            .fields = &.{.{ .name = "X-Thing", .value = bad }},
            .body = .{ .complete = "" },
        }));
    }
    try testing.expectError(error.InvalidHeader, checkHead(.{ .fields = &.{}, .body = .{ .complete = "" }, .date = "a\r\nb" }));
    // Tab is legal in a value and the Scanner keeps it.
    _ = try checkHead(.{ .fields = &.{.{ .name = "X-Thing", .value = "a\tb" }}, .body = .{ .complete = "" } });
}

test "a Host is a host with an optional port" {
    for ([_][]const u8{ "", "example.com", "example.com:8080", "[::1]", "[::1]:80", "127.0.0.1", "a%41b", "x" }) |good| {
        try testing.expect(validHost(good));
    }
    for ([_][]const u8{ "a b", "a:", "a:x1", "[::1", "[::1]x", "[nope]", ":80", "a/b", "a%4", "a@b", "[" ++ "1" ** 60 ++ "]" }) |bad| {
        try testing.expect(!validHost(bad));
    }
}

test "HTTP/1.1 needs exactly one Host" {
    try testing.expectError(error.BadHost, checkHost(&.{}, true));
    try checkHost(&.{}, false);
    try checkHost(&.{.{ .name = "Host", .value = "" }}, true);
    try testing.expectError(error.BadHost, checkHost(&.{ .{ .name = "Host", .value = "a" }, .{ .name = "host", .value = "a" } }, true));
    try testing.expectError(error.BadHost, checkHost(&.{ .{ .name = "Host", .value = "a" }, .{ .name = "host", .value = "a" } }, false));
    try testing.expectError(error.BadHost, checkHost(&.{.{ .name = "Host", .value = "a b" }}, false));
}

/// Test helper. Collects every item, and says whether the list ended on
/// `Malformed`.
fn items(value: []const u8, out: []List.Item) struct { n: usize, malformed: bool } {
    var l = list(value);
    var n: usize = 0;
    while (true) {
        const item = l.next() catch {
            // Nothing comes after a malformed item.
            std.debug.assert((l.next() catch unreachable) == null);
            return .{ .n = n, .malformed = true };
        } orelse return .{ .n = n, .malformed = false };
        out[n] = item;
        n += 1;
    }
}

test "the headers a list parser is for" {
    var got: [4]List.Item = undefined;

    var r = items("text/html; charset=\"utf-8\"", &got);
    try testing.expectEqual(@as(usize, 1), r.n);
    try testing.expectEqualStrings("text/html", got[0].token);
    var params = got[0].params();
    const charset = params.next().?;
    try testing.expectEqualStrings("charset", charset.name);
    try testing.expectEqualStrings("\"utf-8\"", charset.value);
    try testing.expectEqual(@as(?Params.Param, null), params.next());

    r = items("gzip;q=0.8, br", &got);
    try testing.expectEqual(@as(usize, 2), r.n);
    try testing.expectEqualStrings("gzip", got[0].token);
    params = got[0].params();
    try testing.expectEqualStrings("0.8", params.next().?.value);
    try testing.expectEqualStrings("br", got[1].token);
    try testing.expectEqualStrings("", got[1].raw_params);

    r = items("no-cache=\"Set-Cookie, Authorization\", max-age=60", &got);
    try testing.expectEqual(@as(usize, 2), r.n);
    try testing.expectEqualStrings("no-cache", got[0].token);
    try testing.expectEqualStrings("\"Set-Cookie, Authorization\"", got[0].value);
    try testing.expectEqualStrings("max-age", got[1].token);
    try testing.expectEqualStrings("60", got[1].value);

    r = items("keep-alive, Upgrade", &got);
    try testing.expectEqual(@as(usize, 2), r.n);
    try testing.expectEqualStrings("Upgrade", got[1].token);
    try testing.expect(!r.malformed);
}

test "a quoted comma or semicolon doesn't end anything" {
    var got: [4]List.Item = undefined;
    const r = items("a=\"x,y\", b;c=\"1;2\"", &got);
    try testing.expectEqual(@as(usize, 2), r.n);
    try testing.expectEqualStrings("\"x,y\"", got[0].value);
    var params = got[1].params();
    try testing.expectEqualStrings("\"1;2\"", params.next().?.value);
    try testing.expectEqual(@as(?Params.Param, null), params.next());
}

test "whitespace around a semicolon or not" {
    var got: [4]List.Item = undefined;
    for ([_][]const u8{ "a;b=1;c=2", "a ; b=1 ;\tc=2", "a; b=1; c=2 " }) |value| {
        const r = items(value, &got);
        try testing.expectEqual(@as(usize, 1), r.n);
        try testing.expect(!r.malformed);
        var params = got[0].params();
        try testing.expectEqualStrings("b", params.next().?.name);
        const c = params.next().?;
        try testing.expectEqualStrings("c", c.name);
        try testing.expectEqualStrings("2", c.value);
        try testing.expectEqual(@as(?Params.Param, null), params.next());
    }
}

test "empty items and parameters are skipped" {
    var got: [4]List.Item = undefined;
    const cases = [_]struct { []const u8, usize }{
        .{ "a,,b", 2 },
        .{ ", a", 1 },
        .{ "a,", 1 },
        .{ "a, ,b ,", 2 },
        .{ "", 0 },
        .{ " \t ", 0 },
        .{ ",,,", 0 },
    };
    for (cases) |case| {
        const r = items(case[0], &got);
        try testing.expectEqual(case[1], r.n);
        try testing.expect(!r.malformed);
    }

    _ = items("a;;b;", &got);
    var params = got[0].params();
    try testing.expectEqualStrings("b", params.next().?.name);
    try testing.expectEqual(@as(?Params.Param, null), params.next());
}

test "a parameter with no value" {
    var got: [1]List.Item = undefined;
    _ = items("a;flag", &got);
    var params = got[0].params();
    const flag = params.next().?;
    try testing.expectEqualStrings("flag", flag.name);
    try testing.expectEqualStrings("", flag.value);
}

test "a malformed item ends the list" {
    var got: [4]List.Item = undefined;
    const cases = [_]struct { []const u8, usize }{
        .{ "a, b=\"open", 1 },
        .{ "a=", 0 },
        .{ "a;b=", 0 },
        .{ "a;b=,c", 0 },
        .{ "a b, c", 0 },
        .{ "a, \"x\"", 1 },
        .{ "a;=1", 0 },
        .{ "a = 1", 0 },
        .{ "a=\"x\"y", 0 },
        .{ "a=\"x\\", 0 },
        .{ "/b", 0 },
        .{ "a/", 0 },
        .{ "a=\"x\x01\"", 0 },
    };
    for (cases) |case| {
        const r = items(case[0], &got);
        try testing.expectEqual(case[1], r.n);
        try testing.expect(r.malformed);
    }
}

test "unquoting" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("x\"y", try unquote("\"x\\\"y\"", &buf));
    try testing.expectEqualStrings("a,b", try unquote("\"a,b\"", &buf));
    try testing.expectEqualStrings("", try unquote("\"\"", &buf));
    // Not quoted, so it comes back as it is and buf isn't needed.
    try testing.expectEqualStrings("token", try unquote("token", &.{}));

    try testing.expectError(error.NoSpaceLeft, unquote("\"abc\"", buf[0..2]));
    try testing.expectError(error.Malformed, unquote("\"abc", &buf));
    try testing.expectError(error.Malformed, unquote("\"a\"b\"", &buf));
    try testing.expectError(error.Malformed, unquote("\"a\\\"", &buf));
    try testing.expectError(error.Malformed, unquote("\"", &buf));
}
