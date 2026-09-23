//! A response as a value. `Server` writes it, because only the server
//! knows the request it answers, and the request decides things like
//! whether a body goes out at all.

const std = @import("std");

const field = @import("field.zig");

const Response = @This();

status: Status = .ok,
/// Goes out as Content-Type. `text`, `json` and `html` set it, so
/// `headers` stays yours. Don't put a Content-Type in both.
content_type: ?[]const u8 = null,
headers: []const Header = &.{},
body: []const u8 = "",
/// False closes the connection after this response. A `Connection:
/// close` in `headers` does the same.
keep_alive: bool = true,

/// The same `Header` the Scanner uses, in both directions.
pub const Header = field.Header;

pub fn text(status: Status, s: []const u8) Response {
    return .{
        .status = status,
        .content_type = "text/plain; charset=utf-8",
        .body = s,
    };
}

pub fn json(status: Status, s: []const u8) Response {
    return .{
        .status = status,
        .content_type = "application/json",
        .body = s,
    };
}

pub fn html(status: Status, s: []const u8) Response {
    return .{
        .status = status,
        .content_type = "text/html; charset=utf-8",
        .body = s,
    };
}

pub const Status = enum(u16) {
    @"continue" = 100,
    switching_protocols = 101,
    early_hints = 103,

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
    /// Only the errors the peer caused get a 4xx. Anything else,
    /// including a mistake by the caller, is a 500.
    ///
    /// This says nothing about keeping the connection. None of these
    /// leave the reader on a message boundary, so whatever response
    /// carries one is the last.
    pub fn forError(err: anyerror) Status {
        return named(err) orelse .internal_server_error;
    }

    /// Every error `Server` can hand you, listed on purpose. A test in
    /// Server.zig fails if a new one shows up without a line here.
    pub fn named(err: anyerror) ?Status {
        return switch (err) {
            error.Timeout => .request_timeout,
            error.HeadTooLarge => .request_header_fields_too_large,
            error.UnsupportedExpectation => .expectation_failed,
            error.BodyTooLarge => .payload_too_large,
            error.UnsupportedEncoding => .not_implemented,
            // The rest all mean "not a request we are going to serve".
            error.BadRequest,
            error.BadHost,
            error.Ambiguous,
            error.Incomplete,
            error.BadChunk,
            error.ReadFailed,
            => .bad_request,
            // Not the peer's fault. Don't blame the request in the log.
            error.AlreadyAnswered,
            error.ResponseOpen,
            error.RequestUnanswered,
            error.BodyTaken,
            error.NoDecodeBuffer,
            error.SinkFailed,
            error.WriteFailed,
            error.Canceled,
            // A response we refused to write.
            error.InvalidHeader,
            error.AmbiguousFraming,
            error.BodyPending,
            error.NotSwitching,
            error.NoBodyToStream,
            error.InvalidTrailer,
            error.LengthMismatch,
            error.Finished,
            // A handler that didn't answer.
            error.NoResponse,
            => .internal_server_error,
            else => null,
        };
    }

    pub fn phrase(s: Status) []const u8 {
        return switch (s) {
            .@"continue" => "Continue",
            .switching_protocols => "Switching Protocols",
            .early_hints => "Early Hints",
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

test "the errors the peer caused are the only 4xx" {
    try testing.expectEqual(Status.request_timeout, Status.forError(error.Timeout));
    try testing.expectEqual(Status.request_header_fields_too_large, Status.forError(error.HeadTooLarge));
    try testing.expectEqual(Status.expectation_failed, Status.forError(error.UnsupportedExpectation));
    try testing.expectEqual(Status.payload_too_large, Status.forError(error.BodyTooLarge));
    try testing.expectEqual(Status.not_implemented, Status.forError(error.UnsupportedEncoding));
    try testing.expectEqual(Status.bad_request, Status.forError(error.Ambiguous));
    try testing.expectEqual(Status.bad_request, Status.forError(error.ReadFailed));

    try testing.expectEqual(Status.internal_server_error, Status.forError(error.AlreadyAnswered));
    try testing.expectEqual(Status.internal_server_error, Status.forError(error.OutOfMemory));
}

test "an unnamed status has a phrase" {
    try testing.expectEqualStrings("Unknown", @as(Status, @enumFromInt(599)).phrase());
}
