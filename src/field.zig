//! Writing header lines.
//!
//! Three callers write a field list: a response head, a request head and
//! the trailers after a chunked body. All of them have to check before
//! they write anything, because half a head on the wire becomes the
//! start of whatever goes out next.

const std = @import("std");
const Io = std.Io;

const scan = @import("scan.zig");

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

/// Writes one line each. Call `check` first, because this can't reject.
pub fn write(w: *Io.Writer, fields: []const Header) Io.Writer.Error!void {
    for (fields) |f| {
        try w.writeAll(f.name);
        try w.writeAll(": ");
        try w.writeAll(f.value);
        try w.writeAll("\r\n");
    }
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
