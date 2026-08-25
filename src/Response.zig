//! A response as a value. Writing it is a separate step, so the same
//! value can go to a socket or into a buffer in a test.

const std = @import("std");
const Io = std.Io;

const Response = @This();

status: Status = .ok,
headers: []const Header = &.{},
body: []const u8 = "",
/// False closes the connection after this response.
keep_alive: bool = true,
/// Suppress the body, for HEAD. Content-Length still describes what a GET
/// would have returned.
head_only: bool = false,

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const WriteOptions = struct {
    /// Whether the connection is being kept alive, decided by the caller from
    /// the request.
    keep_alive: bool,
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

/// Status line and headers, stopping at the blank line. Separate so a body
/// can be streamed after it.
pub fn writeHead(r: Response, w: *Io.Writer, options: WriteOptions) WriteError!void {
    const alive = options.keep_alive and r.keep_alive;

    try w.writeAll("HTTP/1.1 ");
    try w.print("{d} ", .{@intFromEnum(r.status)});
    try w.writeAll(r.status.phrase());
    try w.writeAll("\r\n");

    for (r.headers) |h| {
        if (!validName(h.name) or !validValue(h.value)) return error.InvalidHeader;
        try w.writeAll(h.name);
        try w.writeAll(": ");
        try w.writeAll(h.value);
        try w.writeAll("\r\n");
    }

    // 1xx, 204 and 304 have no body, and a Content-Length on one of them is
    // how a peer ends up reading the next response as this one's body.
    if (r.status.mayHaveBody() and
        !r.hasHeader("content-length") and
        !r.hasHeader("transfer-encoding"))
    {
        try w.print("Content-Length: {d}\r\n", .{r.body.len});
    }
    if (!alive) try w.writeAll("Connection: close\r\n");

    try w.writeAll("\r\n");
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!token_chars[c]) return false;
    return true;
}

fn validValue(value: []const u8) bool {
    for (value) |c| {
        if (c == '\r' or c == '\n' or c == 0) return false;
    }
    return true;
}

const token_chars = blk: {
    var t = [_]bool{false} ** 256;
    for ("!#$%&'*+-.^_`|~") |c| t[c] = true;
    for ('0'..'9' + 1) |c| t[c] = true;
    for ('a'..'z' + 1) |c| t[c] = true;
    for ('A'..'Z' + 1) |c| t[c] = true;
    break :blk t;
};

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

    /// Whether a response with this status is allowed a body at all.
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
