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

pub fn write(r: Response, w: *Io.Writer, options: WriteOptions) Io.Writer.Error!void {
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

    if (!r.hasHeader("content-length") and !r.hasHeader("transfer-encoding")) {
        try w.print("Content-Length: {d}\r\n", .{r.body.len});
    }
    if (!alive) try w.writeAll("Connection: close\r\n");

    try w.writeAll("\r\n");
    if (!r.head_only) try w.writeAll(r.body);
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

test "an unnamed status still writes" {
    var buf: [256]u8 = undefined;
    const out = try render(.{ .status = @enumFromInt(599) }, true, &buf);
    try testing.expectEqualStrings("HTTP/1.1 599 Unknown\r\nContent-Length: 0\r\n\r\n", out);
}
