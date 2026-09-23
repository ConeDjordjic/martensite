//! Writing header lines.
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
