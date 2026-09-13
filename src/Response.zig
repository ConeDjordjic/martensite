//! A response as a value. Writing it is a separate step, so the same
//! value can go to a socket or into a buffer in a test.

const std = @import("std");
const Io = std.Io;

const scan = @import("scan.zig");

const Response = @This();

status: Status = .ok,
headers: []const Header = &.{},
body: []const u8 = "",
/// False closes the connection after this response.
keep_alive: bool = true,
/// Drop the body but keep its Content-Length. For HEAD.
head_only: bool = false,

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const WriteOptions = struct {
    /// Decided by the caller from the request.
    keep_alive: bool,
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
};

pub fn write(r: Response, w: *Io.Writer, options: WriteOptions) WriteError!void {
    try r.writeHead(w, options);
    if (!r.head_only and r.status.mayHaveBody()) try w.writeAll(r.body);
}

/// Status line and headers, up to the blank line.
///
/// Every header is checked before any byte is written. A head that is
/// refused leaves the writer untouched, because a partial head becomes the
/// prefix of whatever the caller sends next, and that is a response split.
pub fn writeHead(r: Response, w: *Io.Writer, options: WriteOptions) WriteError!void {
    for (r.headers) |h| {
        if (!scan.validFieldName(h.name) or !scan.validFieldValue(h.value)) return error.InvalidHeader;
    }
    if (options.date) |d| {
        if (!scan.validFieldValue(d)) return error.InvalidHeader;
    }

    const alive = options.keep_alive and r.keep_alive;

    try w.writeAll("HTTP/1.1 ");
    try w.print("{d} ", .{@intFromEnum(r.status)});
    try w.writeAll(r.status.phrase());
    try w.writeAll("\r\n");

    for (r.headers) |h| {
        try w.writeAll(h.name);
        try w.writeAll(": ");
        try w.writeAll(h.value);
        try w.writeAll("\r\n");
    }

    // 1xx, 204 and 304 have no body. A Content-Length on one makes the
    // peer read the next response as this one's.
    if (r.status.mayHaveBody() and
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
    try r.write(&w, .{ .keep_alive = keep_alive });
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
    const out = try render(.{ .body = "hello", .head_only = true }, true, &buf);
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

    try testing.expectError(error.InvalidHeader, r.write(&w, .{ .keep_alive = true }));
    // Half a head left in the writer becomes the start of whatever goes
    // out next.
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}
