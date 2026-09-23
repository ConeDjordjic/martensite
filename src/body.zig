//! How long a body is. This is where request smuggling starts, so
//! anything ambiguous gets rejected instead of guessed at.
//!
//! Both directions live here. We refuse to write any head we would
//! refuse to read, so the two sides share one walk over the headers.

const std = @import("std");
const scan = @import("scan.zig");
const field = @import("field.zig");

pub const Framing = union(enum) {
    none,
    length: u64,
    chunked,
    /// Responses only. The body ends when the connection does, so a
    /// complete one and a truncated one look the same.
    until_close,
};

pub const Error = error{
    /// Both framing headers at once, one of them twice with different
    /// values, or a length that isn't a number. Any of these lets two
    /// parsers disagree about where the body ends.
    Ambiguous,
    /// Transfer-Encoding doesn't end with chunked.
    UnsupportedEncoding,
};

/// What a head's framing headers say, before anyone decides what that
/// means for the body.
const Announced = struct {
    length: ?u64 = null,
    encoding: ?[]const u8 = null,

    fn framed(a: Announced) bool {
        return a.length != null or a.encoding != null;
    }
};

fn walk(headers: []const scan.Header) error{Ambiguous}!Announced {
    var out: Announced = .{};
    for (headers) |h| {
        if (eqlIgnoreCase(h.name, "content-length")) {
            // The Scanner trims the value already. Heads we write come
            // from the caller and might not be.
            const v = parseLength(std.mem.trim(u8, h.value, " \t")) orelse
                return error.Ambiguous;
            // Repeating is only fine if it agrees.
            if (out.length) |prev| {
                if (prev != v) return error.Ambiguous;
            }
            out.length = v;
        } else if (eqlIgnoreCase(h.name, "transfer-encoding")) {
            if (out.encoding != null) return error.Ambiguous;
            out.encoding = h.value;
        }
    }
    // The RFC says Transfer-Encoding wins, but anyone sending both is
    // either confused or probing us. Don't trust either one.
    if (out.length != null and out.encoding != null) return error.Ambiguous;
    return out;
}

/// What the head says about the length of its body, or null if it says
/// nothing.
fn announced(headers: []const scan.Header) Error!?Framing {
    const a = try walk(headers);
    if (a.encoding) |te| {
        if (!endsWithChunked(te)) return error.UnsupportedEncoding;
        return .chunked;
    }
    if (a.length) |v| return if (v == 0) .none else .{ .length = v };
    return null;
}

/// Framing of a request body. RFC 9112 section 6.
pub fn request(head: scan.Head) Error!Framing {
    // A request with no framing header has no body. There is no
    // connection close to end one with.
    return try announced(head.headers) orelse .none;
}

/// Framing of a response body. `method` is the request's method, and
/// null for anything we don't have a name for. We take the enum instead
/// of the bytes so we don't have to hold a slice of the request until
/// its response arrives.
pub fn response(head: scan.ResponseHead, method: ?scan.Method) Error!Framing {
    if (answer(method, head.status) != .body) return .none;
    // With neither header the body runs until the connection closes.
    return try announced(head.headers) orelse .until_close;
}

/// What comes after a response head. The status decides most of it and
/// the request's method decides the rest. Both sides of a connection
/// read this one function, so they can't disagree about a tunnel.
pub const Answer = enum {
    /// An ordinary body.
    body,
    /// The answer to a HEAD. The head describes the body a GET would
    /// have got, and no body follows.
    head,
    /// 304. Like `head`, except only the caller knows what length to
    /// describe, so we never add one.
    not_modified,
    /// 204. No body and no framing headers.
    no_content,
    /// A 1xx other than 101. The real response is still to come.
    interim,
    /// 101. The next bytes belong to another protocol.
    switch_protocols,
    /// A 2xx to a CONNECT. The next bytes are tunnel bytes.
    tunnel,

    /// The connection stops speaking HTTP after this head.
    pub fn switches(a: Answer) bool {
        return a == .switch_protocols or a == .tunnel;
    }

    /// Whether the head may carry framing headers at all. A peer that
    /// believes a length on a 1xx or a 204 reads the next response as
    /// its body. On a tunnel, a length promises an intermediary a body
    /// that never arrives.
    fn framed(a: Answer) bool {
        return switch (a) {
            .body, .head, .not_modified => true,
            .no_content, .interim, .switch_protocols, .tunnel => false,
        };
    }
};

pub fn answer(method: ?scan.Method, status: u16) Answer {
    if (status == 101) return .switch_protocols;
    if (status >= 100 and status < 200) return .interim;
    if (method == .CONNECT and status >= 200 and status < 300) return .tunnel;
    if (status == 204) return .no_content;
    if (status == 304) return .not_modified;
    if (method) |m| if (!m.expectsBody()) return .head;
    return .body;
}

/// The body after a head we are about to write.
pub const Outgoing = union(enum) {
    /// In hand, written straight after the head.
    complete: []const u8,
    /// Written afterwards, exactly this long.
    length: u64,
    /// Written afterwards, in chunks.
    chunked,
};

/// How the bytes after a head go out.
pub const Mode = union(enum) {
    chunked,
    /// Exactly this many bytes.
    length: u64,
    /// The peer won't read a body, so we drop whatever gets written.
    /// This is the answer to a HEAD.
    discard,
};

/// What `outgoing` decided.
pub const Plan = struct {
    /// The framing header to add after the caller's own headers.
    line: union(enum) { none, length: u64, chunked },
    mode: Mode,
};

/// Decides how a head we write frames its body, or refuses it if our own
/// read side would refuse it. `to` is null for a request, which always
/// sends its body.
pub fn outgoing(headers: []const scan.Header, out: Outgoing, to: ?Answer) error{Ambiguous}!Plan {
    const a = try walk(headers);
    const allows_framing = if (to) |t| t.framed() else true;
    const sends = if (to) |t| t == .body else true;

    if (a.framed() and !allows_framing) return error.Ambiguous;
    if (a.encoding) |te| {
        // The read side calls this UnsupportedEncoding.
        if (!endsWithChunked(te)) return error.Ambiguous;
    }

    // Whatever the caller wrote has to agree with the body we send.
    switch (out) {
        .complete => |bytes| if (sends) {
            if (a.length) |n| {
                if (n != bytes.len) return error.Ambiguous;
            }
            // They chunked it themselves, so it has to end, or the peer
            // waits forever. Trailers go through a streamed body.
            if (a.encoding != null and !std.mem.endsWith(u8, bytes, "0\r\n\r\n"))
                return error.Ambiguous;
        },
        .length => |n| {
            if (a.encoding != null) return error.Ambiguous;
            if (a.length) |mine| {
                if (mine != n) return error.Ambiguous;
            }
        },
        // We chunk it whatever the header says, so the header has to say
        // chunked.
        .chunked => if (a.length != null) return error.Ambiguous,
    }

    const adds = !a.framed() and allows_framing and to != .not_modified;
    return .{
        .line = if (!adds) .none else switch (out) {
            // A request with no framing has no body, so an empty one
            // needs nothing. A response with none runs until close.
            .complete => |bytes| if (to == null and bytes.len == 0) .none else .{ .length = bytes.len },
            .length => |n| .{ .length = n },
            .chunked => .chunked,
        },
        .mode = if (!sends) .discard else switch (out) {
            .complete => |bytes| .{ .length = bytes.len },
            .length => |n| .{ .length = n },
            .chunked => .chunked,
        },
    };
}

/// The part of a head that decides how long the connection lives. The
/// rules are the same in both directions. A server saying `close` ends
/// it just like a client does.
pub const Connection = struct {
    headers: []const scan.Header,
    minor_version: u8,

    pub fn of(head: anytype) Connection {
        return .{ .headers = head.headers, .minor_version = head.minor_version };
    }

    /// A head we write. We always write HTTP/1.1.
    pub fn ours(headers: []const scan.Header) Connection {
        return .{ .headers = headers, .minor_version = 1 };
    }
};

/// Whether the connection can carry another message after this one.
pub fn keepAlive(c: Connection) bool {
    if (connectionHas(c, "close") or connectionMalformed(c)) return false;
    if (connectionHas(c, "keep-alive")) return true;
    return c.minor_version >= 1;
}

/// Whether Connection lists `token`. It is a list, so a plain substring
/// search would find "close" inside "not-close".
pub fn connectionHas(c: Connection, token: []const u8) bool {
    for (c.headers) |h| {
        if (!eqlIgnoreCase(h.name, "connection")) continue;
        var items = field.list(h.value);
        while (items.next() catch null) |item| {
            if (eqlIgnoreCase(item.token, token)) return true;
        }
    }
    return false;
}

/// A Connection we can't read might have said close, so `keepAlive`
/// treats it as if it did.
fn connectionMalformed(c: Connection) bool {
    for (c.headers) |h| {
        if (!eqlIgnoreCase(h.name, "connection")) continue;
        var items = field.list(h.value);
        while (items.next() catch return true) |_| {}
    }
    return false;
}

/// chunked has to be last and can only appear once. A coding with a
/// value, or a value we can't read, is refused.
fn endsWithChunked(value: []const u8) bool {
    var last: ?field.List.Item = null;
    var count: usize = 0;
    var items = field.list(value);
    while (items.next() catch return false) |item| {
        if (item.value.len != 0) return false;
        if (eqlIgnoreCase(item.token, "chunked")) count += 1;
        last = item;
    }
    const l = last orelse return false;
    // chunked takes no parameters.
    return count == 1 and eqlIgnoreCase(l.token, "chunked") and l.raw_params.len == 0;
}

/// Digits only. Two parsers reading a Content-Length differently is how
/// you get a smuggled request, so we don't take a sign or a separator.
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

test "both framing headers are refused" {
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

test "a Transfer-Encoding that only looks like it ends in chunked" {
    var h: [8]scan.Header = undefined;
    for ([_][]const u8{
        "chunked;x=1",
        "gzip;x=\"1, chunked\"",
        "gzip=1, chunked",
        "gzip, \"chunked\"",
        "gzip x, chunked",
    }) |te| {
        var buf: [128]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&buf, "POST / HTTP/1.1\r\nTransfer-Encoding: {s}\r\n\r\n", .{te});
        try testing.expectError(error.UnsupportedEncoding, request(parse(bytes, &h)));
    }
    // A quoted comma in a parameter doesn't hide the real last coding,
    // and a trailing comma is just an empty item.
    for ([_][]const u8{ "gzip;x=\"1, 2\", chunked", "gzip, chunked," }) |te| {
        var buf: [128]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&buf, "POST / HTTP/1.1\r\nTransfer-Encoding: {s}\r\n\r\n", .{te});
        try testing.expectEqual(Framing.chunked, try request(parse(bytes, &h)));
    }
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

fn parseResponse(bytes: []const u8, headers: []scan.Header) scan.ResponseHead {
    return (scan.response(bytes, headers, 0) catch unreachable).?.head;
}

test "a response with a length" {
    var h: [8]scan.Header = undefined;
    const f = try response(parseResponse("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n", &h), .GET);
    try testing.expectEqual(@as(u64, 9), f.length);
}

test "a response with neither header runs until close" {
    var h: [8]scan.Header = undefined;
    try testing.expectEqual(
        Framing.until_close,
        try response(parseResponse("HTTP/1.0 200 OK\r\n\r\n", &h), .GET),
    );
}

test "some statuses have no body whatever the headers say" {
    var h: [8]scan.Header = undefined;
    for ([_][]const u8{
        "HTTP/1.1 204 No Content\r\nContent-Length: 9\r\n\r\n",
        "HTTP/1.1 304 Not Modified\r\nContent-Length: 9\r\n\r\n",
        "HTTP/1.1 100 Continue\r\nContent-Length: 9\r\n\r\n",
    }) |bytes| {
        try testing.expectEqual(Framing.none, try response(parseResponse(bytes, &h), .GET));
    }
}

test "a HEAD response describes a body that is not coming" {
    var h: [8]scan.Header = undefined;
    try testing.expectEqual(
        Framing.none,
        try response(parseResponse("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n", &h), .HEAD),
    );
}

test "a successful CONNECT is followed by a tunnel" {
    var h: [8]scan.Header = undefined;
    try testing.expectEqual(
        Framing.none,
        try response(parseResponse("HTTP/1.1 200 OK\r\n\r\n", &h), .CONNECT),
    );
    try testing.expectEqual(
        Framing.until_close,
        try response(parseResponse("HTTP/1.1 502 Bad Gateway\r\n\r\n", &h), .CONNECT),
    );
}

test "a response with both framing headers is refused too" {
    var h: [8]scan.Header = undefined;
    try testing.expectError(error.Ambiguous, response(parseResponse(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n",
        &h,
    ), .GET));
}

test "keep alive defaults by version" {
    var h: [8]scan.Header = undefined;
    try testing.expect(keepAlive(.of(parse("GET / HTTP/1.1\r\n\r\n", &h))));
    try testing.expect(!keepAlive(.of(parse("GET / HTTP/1.0\r\n\r\n", &h))));
}

test "connection close and keep-alive" {
    var h: [8]scan.Header = undefined;
    try testing.expect(!keepAlive(.of(parse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n", &h))));
    try testing.expect(keepAlive(.of(parse("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", &h))));
    try testing.expect(!keepAlive(.of(parse("GET / HTTP/1.1\r\nConnection: keep-alive, close\r\n\r\n", &h))));
    try testing.expect(!keepAlive(.of(parse("GET / HTTP/1.1\r\nconnection: CLOSE\r\n\r\n", &h))));
    // Nobody can say whether this one meant close.
    try testing.expect(!keepAlive(.of(parse("GET / HTTP/1.1\r\nConnection: keep-alive \"close\r\n\r\n", &h))));
}

test "what comes after a response head" {
    const cases = [_]struct { ?scan.Method, u16, Answer }{
        .{ null, 200, .body },
        .{ .GET, 200, .body },
        .{ .GET, 599, .body },
        .{ .HEAD, 200, .head },
        .{ .HEAD, 204, .no_content },
        .{ .GET, 204, .no_content },
        .{ .GET, 304, .not_modified },
        .{ .HEAD, 304, .not_modified },
        .{ .GET, 100, .interim },
        .{ .GET, 103, .interim },
        .{ .GET, 101, .switch_protocols },
        .{ .CONNECT, 101, .switch_protocols },
        .{ .CONNECT, 200, .tunnel },
        .{ .CONNECT, 299, .tunnel },
        .{ .CONNECT, 502, .body },
        .{ null, 204, .no_content },
    };
    for (cases) |c| try testing.expectEqual(c[2], answer(c[0], c[1]));
}

test "a head we write is refused if we would refuse to read it" {
    const H = scan.Header;
    const Case = struct { headers: []const H = &.{}, out: Outgoing = .{ .complete = "hello" }, to: ?Answer = .body };
    const cl5: H = .{ .name = "Content-Length", .value = "5" };
    const te: H = .{ .name = "Transfer-Encoding", .value = "chunked" };
    const gzip: H = .{ .name = "Transfer-Encoding", .value = "gzip" };

    for ([_]Case{
        .{ .headers = &.{ cl5, te } },
        .{ .headers = &.{ cl5, .{ .name = "Content-Length", .value = "6" } } },
        .{ .headers = &.{ te, te } },
        // A length of 0 puts the body exactly where the peer looks for
        // the next message.
        .{ .headers = &.{.{ .name = "Content-Length", .value = "0" }} },
        .{ .headers = &.{.{ .name = "Content-Length", .value = "0" }}, .to = null },
        .{ .headers = &.{gzip} },
        .{ .headers = &.{gzip}, .to = null },
        // Chunked by the caller, but it never ends.
        .{ .headers = &.{te} },
        .{ .headers = &.{cl5}, .out = .chunked },
        .{ .headers = &.{gzip}, .out = .chunked },
        .{ .headers = &.{te}, .out = .{ .length = 5 } },
        .{ .headers = &.{cl5}, .out = .{ .length = 6 } },
        .{ .headers = &.{te}, .out = .{ .complete = "" }, .to = .no_content },
        .{ .headers = &.{cl5}, .to = .no_content },
        .{ .headers = &.{cl5}, .to = .interim },
        .{ .headers = &.{cl5}, .to = .switch_protocols },
        .{ .headers = &.{cl5}, .to = .tunnel },
    }) |c| {
        try testing.expectError(error.Ambiguous, outgoing(c.headers, c.out, c.to));
    }

    // Lengths other parsers take and we don't.
    for ([_][]const u8{ "+5", "-0", "1_0", " 5 x", "0x5", "", "5x" }) |bad| {
        const h: []const H = &.{.{ .name = "Content-Length", .value = bad }};
        try testing.expectError(error.Ambiguous, outgoing(h, .{ .complete = "hello" }, .body));
        try testing.expectError(error.Ambiguous, outgoing(h, .{ .complete = "hello" }, null));
    }
}

test "the framing we add, and what happens to the body" {
    const H = scan.Header;
    const cl5: H = .{ .name = "Content-Length", .value = "5" };
    const te: H = .{ .name = "Transfer-Encoding", .value = "chunked" };
    const chunked_body = "5\r\nhello\r\n0\r\n\r\n";

    const Case = struct { []const H, Outgoing, ?Answer, Plan };
    for ([_]Case{
        .{ &.{}, .{ .complete = "hello" }, .body, .{ .line = .{ .length = 5 }, .mode = .{ .length = 5 } } },
        .{ &.{}, .{ .complete = "" }, .body, .{ .line = .{ .length = 0 }, .mode = .{ .length = 0 } } },
        // A request with no framing has no body, so it needs no header.
        .{ &.{}, .{ .complete = "" }, null, .{ .line = .none, .mode = .{ .length = 0 } } },
        .{ &.{}, .{ .complete = "hello" }, null, .{ .line = .{ .length = 5 }, .mode = .{ .length = 5 } } },
        // The caller's own framing is left alone.
        .{ &.{cl5}, .{ .complete = "hello" }, .body, .{ .line = .none, .mode = .{ .length = 5 } } },
        .{ &.{ cl5, cl5 }, .{ .complete = "hello" }, .body, .{ .line = .none, .mode = .{ .length = 5 } } },
        .{ &.{te}, .{ .complete = chunked_body }, .body, .{ .line = .none, .mode = .{ .length = chunked_body.len } } },
        .{ &.{te}, .chunked, .body, .{ .line = .none, .mode = .chunked } },
        .{ &.{}, .chunked, .body, .{ .line = .chunked, .mode = .chunked } },
        .{ &.{}, .{ .length = 5 }, null, .{ .line = .{ .length = 5 }, .mode = .{ .length = 5 } } },
        // A HEAD describes the body a GET would have got.
        .{ &.{}, .{ .complete = "twelve bytes" }, .head, .{ .line = .{ .length = 12 }, .mode = .discard } },
        .{ &.{.{ .name = "Content-Length", .value = "12" }}, .{ .complete = "" }, .head, .{ .line = .none, .mode = .discard } },
        .{ &.{}, .chunked, .head, .{ .line = .chunked, .mode = .discard } },
        // A 304 can describe one too, but only if the caller says how
        // long.
        .{ &.{cl5}, .{ .complete = "" }, .not_modified, .{ .line = .none, .mode = .discard } },
        .{ &.{}, .{ .complete = "ignored" }, .not_modified, .{ .line = .none, .mode = .discard } },
        .{ &.{}, .{ .complete = "ignored" }, .no_content, .{ .line = .none, .mode = .discard } },
        .{ &.{}, .{ .complete = "ignored" }, .interim, .{ .line = .none, .mode = .discard } },
        .{ &.{}, .{ .complete = "ignored" }, .switch_protocols, .{ .line = .none, .mode = .discard } },
        .{ &.{}, .{ .complete = "ignored" }, .tunnel, .{ .line = .none, .mode = .discard } },
    }) |c| {
        try testing.expectEqual(c[3], try outgoing(c[0], c[1], c[2]));
    }
}
