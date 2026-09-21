//! A response as a value. Writing it is a separate step, so the same
//! value can go to a socket or into a buffer in a test.

const std = @import("std");
const Io = std.Io;

const scan = @import("scan.zig");
const field = @import("field.zig");
const body_mod = @import("body.zig");

const Response = @This();

status: Status = .ok,
headers: []const Header = &.{},
body: []const u8 = "",
/// False closes the connection after this response.
keep_alive: bool = true,
/// What happens to the body. The status on its own doesn't decide this,
/// so `Server` sets it from the request it has in hand.
carries: Body = .as_given,

/// The Scanner's one. The same `Header` for both directions.
pub const Header = field.Header;

pub const Body = enum {
    /// Written, if the status allows a body at all.
    as_given,
    /// Described but not written. The head keeps its `Content-Length`
    /// and the bytes stay where they are. This is the answer to a HEAD.
    describe_only,
    /// Neither written nor described. A successful CONNECT is followed
    /// by a tunnel, and framing headers on one look to an intermediary
    /// like the length of a body that is never going to arrive.
    none,
};

/// Everything we can decide about a response before writing starts.
/// Whether the connection survives is not in here, because that gets
/// decided while the response goes out. It is an argument instead of
/// something we capture early.
pub const WriteOptions = struct {
    /// Written as a Date header unless the caller already gave us one.
    date: ?[]const u8 = null,
    /// How the body is framed. `from_body` describes the `body` field,
    /// which is what you want for a complete response. A streamed
    /// response says how it will frame the bytes written later.
    framing: Framing = .from_body,
};

pub const Framing = union(enum) {
    from_body,
    length: u64,
    chunked,
};

pub const WriteError = Io.Writer.Error || error{
    /// A bad header name, or CR, LF or NUL in a value. Writing one lets
    /// the caller tack on extra headers, or a whole second response.
    InvalidHeader,
    /// The caller's framing headers say something we would refuse to
    /// read: both `Content-Length` and `Transfer-Encoding`, two lengths
    /// that disagree, or a length that isn't the body's.
    AmbiguousFraming,
};

pub fn write(r: Response, w: *Io.Writer, keep_alive: bool, options: WriteOptions) WriteError!void {
    try r.writeHead(w, keep_alive, options);
    if (r.carries == .as_given and r.status.mayHaveBody()) try w.writeAll(r.body);
}

/// Everything that can be rejected about a response, decided without
/// writing a byte. `writeHead` calls this first, and `Server` calls it
/// itself before it marks a request answered.
pub fn check(r: Response, options: WriteOptions) WriteError!void {
    field.check(r.headers, .header) catch return error.InvalidHeader;
    if (options.date) |d| {
        if (!scan.validFieldValue(d)) return error.InvalidHeader;
    }

    // The caller's own framing has to agree with the body coming after
    // it, otherwise we write a message our own Scanner would reject.
    const announced = field.announced(r.headers) catch return error.AmbiguousFraming;
    const writes_body = r.carries == .as_given and r.status.mayHaveBody();

    // Our own Scanner wants exactly three digits and a space.
    const code = @intFromEnum(r.status);
    if (code < 100 or code > 999) return error.AmbiguousFraming;

    // 1xx and 204 carry no framing at all, not even the caller's. A
    // peer that believes it would read the next response as this one's
    // body. `body.response` gives these statuses no body no matter what
    // the headers say. 304 and the answer to a HEAD can carry a length,
    // which there describes a real body we are deliberately not
    // sending.
    if (code < 200 or code == 204 or r.carries == .none) {
        if (announced.length != null or announced.encoding != null)
            return error.AmbiguousFraming;
    }

    switch (options.framing) {
        .from_body => {
            if (announced.length) |n| {
                if (writes_body and n != r.body.len) return error.AmbiguousFraming;
            }
            if (announced.encoding) |te| {
                // Either an encoding the read side calls
                // UnsupportedEncoding, or a `chunked` whose body isn't.
                // Either way the peer can't find the end.
                if (!body_mod.endsWithChunked(te)) return error.AmbiguousFraming;
                // The caller chunked this themselves, so the framing is
                // theirs, but a body with no terminator never ends and
                // the peer waits forever. Trailers go through
                // `respondStreaming` and `endWithTrailers` instead.
                if (writes_body and !std.mem.endsWith(u8, r.body, "0\r\n\r\n"))
                    return error.AmbiguousFraming;
            }
        },
        .length => |n| {
            if (announced.encoding != null) return error.AmbiguousFraming;
            if (announced.length) |mine| {
                if (mine != n) return error.AmbiguousFraming;
            }
        },
        .chunked => {
            if (announced.length != null) return error.AmbiguousFraming;
            // We chunk the body whatever the header says, so the header
            // has to say chunked.
            if (announced.encoding) |te| {
                if (!body_mod.endsWithChunked(te)) return error.AmbiguousFraming;
            }
        },
    }
}

/// Status line and headers, up to the blank line.
///
/// Everything that can be rejected is decided before a byte is written.
/// A rejected head leaves the writer untouched, because half a head on
/// the wire becomes the start of whatever goes out next, and then you
/// have split one response into two.
pub fn writeHead(r: Response, w: *Io.Writer, keep_alive: bool, options: WriteOptions) WriteError!void {
    try r.check(options);

    const alive = keep_alive and r.keep_alive;

    try w.writeAll("HTTP/1.1 ");
    try w.print("{d} ", .{@intFromEnum(r.status)});
    try w.writeAll(r.status.phrase());
    try w.writeAll("\r\n");

    try field.write(w, r.headers);

    // 1xx, 204 and 304 have no body. A Content-Length on one makes the
    // peer read the next response as this one's, and framing on a tunnel
    // promises an intermediary a body that never arrives.
    if (r.status.mayHaveBody() and r.carries != .none and
        !r.hasHeader("content-length") and
        !r.hasHeader("transfer-encoding"))
    {
        switch (options.framing) {
            .from_body => try w.print("Content-Length: {d}\r\n", .{r.body.len}),
            .length => |n| try w.print("Content-Length: {d}\r\n", .{n}),
            .chunked => try w.writeAll("Transfer-Encoding: chunked\r\n"),
        }
    }
    if (options.date) |d| {
        if (!r.hasHeader("date")) {
            try w.writeAll("Date: ");
            try w.writeAll(d);
            try w.writeAll("\r\n");
        }
    }
    if (!alive) try w.writeAll("Connection: close\r\n");

    try w.writeAll("\r\n");
}

fn hasHeader(r: Response, name: []const u8) bool {
    for (r.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    }
    return false;
}

pub fn text(status: Status, s: []const u8) Response {
    return .{
        .status = status,
        .headers = &.{.{ .name = "Content-Type", .value = "text/plain; charset=utf-8" }},
        .body = s,
    };
}

pub fn json(status: Status, s: []const u8) Response {
    return .{
        .status = status,
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = s,
    };
}

pub fn html(status: Status, s: []const u8) Response {
    return .{
        .status = status,
        .headers = &.{.{ .name = "Content-Type", .value = "text/html; charset=utf-8" }},
        .body = s,
    };
}

pub const Status = enum(u16) {
    @"continue" = 100,
    switching_protocols = 101,

    ok = 200,
    created = 201,
    accepted = 202,
    no_content = 204,
    partial_content = 206,

    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    temporary_redirect = 307,
    permanent_redirect = 308,

    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    length_required = 411,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    expectation_failed = 417,
    unprocessable_content = 422,
    too_many_requests = 429,
    request_header_fields_too_large = 431,

    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
    http_version_not_supported = 505,

    _,

    /// What to answer when we reject a request.
    ///
    /// The errors are ours, so the mapping is ours too. Only the ones
    /// the peer caused get a 4xx. Everything else, including a mistake
    /// by the caller, is a 500.
    ///
    /// This says nothing about keeping the connection. None of these
    /// leave the reader on a message boundary, so whatever response
    /// carries one is the last.
    pub fn forError(err: anyerror) Status {
        return switch (err) {
            error.Timeout => .request_timeout,
            error.HeadTooLarge => .request_header_fields_too_large,
            error.UnsupportedExpectation => .expectation_failed,
            error.BodyTooLarge => .payload_too_large,
            error.UnsupportedEncoding => .not_implemented,
            // The rest all mean "not a request we are going to serve".
            error.BadRequest,
            error.Ambiguous,
            error.Incomplete,
            error.BadChunk,
            error.ReadFailed,
            => .bad_request,
            // Not the peer's fault: answered twice, read a body twice,
            // or a write that failed. Don't blame the request in the
            // log.
            else => .internal_server_error,
        };
    }

    /// Whether this status is allowed to have a body.
    pub fn mayHaveBody(s: Status) bool {
        const code = @intFromEnum(s);
        if (code >= 100 and code < 200) return false;
        return switch (s) {
            .no_content, .not_modified => false,
            else => true,
        };
    }

    pub fn phrase(s: Status) []const u8 {
        return switch (s) {
            .@"continue" => "Continue",
            .switching_protocols => "Switching Protocols",
            .ok => "OK",
            .created => "Created",
            .accepted => "Accepted",
            .no_content => "No Content",
            .partial_content => "Partial Content",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .see_other => "See Other",
            .not_modified => "Not Modified",
            .temporary_redirect => "Temporary Redirect",
            .permanent_redirect => "Permanent Redirect",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .not_acceptable => "Not Acceptable",
            .request_timeout => "Request Timeout",
            .conflict => "Conflict",
            .gone => "Gone",
            .length_required => "Length Required",
            .payload_too_large => "Payload Too Large",
            .uri_too_long => "URI Too Long",
            .unsupported_media_type => "Unsupported Media Type",
            .expectation_failed => "Expectation Failed",
            .unprocessable_content => "Unprocessable Content",
            .too_many_requests => "Too Many Requests",
            .request_header_fields_too_large => "Request Header Fields Too Large",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
            .http_version_not_supported => "HTTP Version Not Supported",
            _ => "Unknown",
        };
    }
};

const testing = std.testing;

fn render(r: Response, keep_alive: bool, buf: []u8) ![]u8 {
    var w: Io.Writer = .fixed(buf);
    try r.write(&w, keep_alive, .{});
    return w.buffered();
}

test "a plain response" {
    var buf: [256]u8 = undefined;
    const out = try render(Response.text(.ok, "hi"), true, &buf);
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 2\r\n\r\nhi",
        out,
    );
}

test "close is announced" {
    var buf: [256]u8 = undefined;
    const out = try render(.{ .body = "x" }, false, &buf);
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx",
        out,
    );
}

test "a caller's content length is left alone" {
    var buf: [256]u8 = undefined;
    const out = try render(.{
        .headers = &.{.{ .name = "Content-Length", .value = "0" }},
    }, true, &buf);
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", out);
}

test "HEAD keeps the length and drops the body" {
    var buf: [256]u8 = undefined;
    const out = try render(.{ .body = "hello", .carries = .describe_only }, true, &buf);
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n", out);
}

test "a header value cannot carry a newline" {
    var buf: [256]u8 = undefined;
    for ([_][]const u8{ "a\r\nX-Evil: 1", "a\nX-Evil: 1", "a\rb", "a\x00b" }) |bad| {
        try testing.expectError(error.InvalidHeader, render(.{
            .headers = &.{.{ .name = "X-Thing", .value = bad }},
        }, true, &buf));
    }
}

test "the write side reads a length the way the read side does" {
    var buf: [256]u8 = undefined;
    // Values other parsers accept and we don't. Writing one is how two
    // intermediaries end up disagreeing about where a body ends.
    for ([_][]const u8{ "+5", "-0", "1_0", " 5 x", "0x5" }) |bad| {
        try testing.expectError(error.AmbiguousFraming, render(.{
            .headers = &.{.{ .name = "Content-Length", .value = bad }},
            .body = "hello",
        }, true, &buf));
    }
}

test "statuses that cannot have a body cannot borrow one either" {
    var buf: [256]u8 = undefined;
    for ([_]Status{ .@"continue", .switching_protocols, .no_content }) |status| {
        try testing.expectError(error.AmbiguousFraming, render(.{
            .status = status,
            .headers = &.{.{ .name = "Content-Length", .value = "5" }},
        }, true, &buf));
    }

    // 304 is the exception. The length there describes the body a 200
    // would have carried.
    const out = try render(.{
        .status = .not_modified,
        .headers = &.{.{ .name = "Content-Length", .value = "5" }},
    }, true, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "Content-Length: 5") != null);
}

test "a value the Scanner refuses is not written" {
    var buf: [256]u8 = undefined;
    // One rule for both sides, so a head we write is one we can read.
    for ([_][]const u8{ "a\x01b", "a\x7fb", "\x0bx" }) |bad| {
        try testing.expectError(error.InvalidHeader, render(.{
            .headers = &.{.{ .name = "X-Thing", .value = bad }},
        }, true, &buf));
    }
    // Tab is legal in a value and the Scanner keeps it.
    const out = try render(.{ .headers = &.{.{ .name = "X-Thing", .value = "a\tb" }} }, true, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "X-Thing: a\tb") != null);
}

test "a header name has to be a token" {
    var buf: [256]u8 = undefined;
    for ([_][]const u8{ "", "X Thing", "X:Thing", "X\r\nY" }) |bad| {
        try testing.expectError(error.InvalidHeader, render(.{
            .headers = &.{.{ .name = bad, .value = "1" }},
        }, true, &buf));
    }
}

test "every refusal this library can return has a status" {
    // Server.ReceiveError plus whatever reading a body can return.
    // Anything new that nobody named yet gets a 500 instead of blaming
    // the peer.
    try testing.expectEqual(Status.request_timeout, Status.forError(error.Timeout));
    try testing.expectEqual(Status.request_header_fields_too_large, Status.forError(error.HeadTooLarge));
    try testing.expectEqual(Status.expectation_failed, Status.forError(error.UnsupportedExpectation));
    try testing.expectEqual(Status.payload_too_large, Status.forError(error.BodyTooLarge));
    try testing.expectEqual(Status.not_implemented, Status.forError(error.UnsupportedEncoding));
    try testing.expectEqual(Status.bad_request, Status.forError(error.Ambiguous));
    try testing.expectEqual(Status.bad_request, Status.forError(error.BadRequest));
    try testing.expectEqual(Status.bad_request, Status.forError(error.ReadFailed));

    // Not the peer's fault, so don't report it like it was.
    try testing.expectEqual(Status.internal_server_error, Status.forError(error.AlreadyAnswered));
    try testing.expectEqual(Status.internal_server_error, Status.forError(error.ResponseOpen));
    try testing.expectEqual(Status.internal_server_error, Status.forError(error.BodyTaken));
    try testing.expectEqual(Status.internal_server_error, Status.forError(error.WriteFailed));
}

test "statuses that cannot have a body do not get a length" {
    var buf: [256]u8 = undefined;
    for ([_]Status{ .@"continue", .switching_protocols, .no_content, .not_modified }) |st| {
        const out = try render(.{ .status = st, .body = "ignored" }, true, &buf);
        try testing.expect(std.mem.indexOf(u8, out, "Content-Length") == null);
        try testing.expect(std.mem.indexOf(u8, out, "ignored") == null);
        try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n"));
    }
}

test "an unnamed status still writes" {
    var buf: [256]u8 = undefined;
    const out = try render(.{ .status = @enumFromInt(599) }, true, &buf);
    try testing.expectEqualStrings("HTTP/1.1 599 Unknown\r\nContent-Length: 0\r\n\r\n", out);
}

test "a refused header leaves the writer untouched" {
    var out: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    const r: Response = .{ .status = .ok, .headers = &.{
        .{ .name = "X-Good", .value = "1" },
        .{ .name = "X-Bad", .value = "a\r\nInjected: yes" },
    }, .body = "hi" };

    try testing.expectError(error.InvalidHeader, r.write(&w, true, .{}));
    // Half a head left in the writer becomes the start of whatever goes
    // out next.
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}
