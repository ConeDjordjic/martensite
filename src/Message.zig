//! A head in hand, plus the check that stops you reading it once the
//! next one has arrived.
//!
//! Server's `Request` and Client's `Response` are both this type. Only
//! the head and a few of the questions differ. Reading a stale message
//! gives you slices pointing into whatever arrived after it.

const std = @import("std");

const scan = @import("scan.zig");
const body = @import("body.zig");
const target_mod = @import("target.zig");
const HeadWindow = @import("HeadWindow.zig");

pub const Kind = enum { request, response };

/// A message gets everything it needs passed in, so it can't reach back
/// into the Server or Client that made it.
pub fn Message(comptime kind: Kind) type {
    return struct {
        head: switch (kind) {
            .request => scan.Head,
            .response => scan.ResponseHead,
        },
        framing: body.Framing,
        /// Checked against `window.generation` to catch stale reads.
        window: *const HeadWindow,
        generation: u32,

        const M = @This();

        /// Asking a request question on a response, or the other way
        /// round, fails to compile.
        fn only(comptime want: Kind, comptime name: []const u8) void {
            if (kind != want) @compileError(name ++ " is a " ++ @tagName(want) ++ " question");
        }

        // Both kinds.

        pub fn header(m: M, name: []const u8) ?[]const u8 {
            m.check();
            for (m.head.headers) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
            }
            return null;
        }

        pub fn headers(m: M) []const scan.Header {
            m.check();
            return m.head.headers;
        }

        /// Every header with this name, not just the first one.
        pub fn headerIter(m: M, name: []const u8) HeaderIterator {
            m.check();
            return .{ .rest = m.head.headers, .name = name };
        }

        /// Body length, when `Content-Length` gave us one. Null for a
        /// chunked body, a body that runs until close, or no body at
        /// all. Use it to size the buffer for `readBody`.
        pub fn contentLength(m: M) ?u64 {
            m.check();
            return switch (m.framing) {
                .length => |n| n,
                else => null,
            };
        }

        /// Is there a body at all? Chunked counts, even with no length.
        pub fn hasBody(m: M) bool {
            m.check();
            return m.framing != .none;
        }

        /// Still the current message?
        pub fn live(m: M) bool {
            return m.generation == m.window.generation;
        }

        fn check(m: M) void {
            if (std.debug.runtime_safety and !m.live()) {
                @panic("message outlived the receive that produced it");
            }
        }

        // Requests only.

        pub fn method(m: M) []const u8 {
            comptime only(.request, "method");
            m.check();
            return m.head.method;
        }

        /// The method as an enum, or null if we have no name for it.
        pub fn knownMethod(m: M) ?scan.Method {
            comptime only(.request, "knownMethod");
            m.check();
            return scan.Method.parse(m.head.method);
        }

        pub fn target(m: M) []const u8 {
            comptime only(.request, "target");
            m.check();
            return m.head.target;
        }

        /// The target split into parts, or null if the shape is illegal.
        pub fn parsedTarget(m: M) ?target_mod.Target {
            comptime only(.request, "parsedTarget");
            m.check();
            return target_mod.parse(m.head.target);
        }

        /// The protocol the peer wants to switch to. It needs
        /// `Connection: upgrade` as well, because Upgrade on its own is
        /// hop-by-hop and might just be left over from a proxy.
        pub fn upgradeTo(m: M) ?[]const u8 {
            comptime only(.request, "upgradeTo");
            m.check();
            if (!body.connectionHas(.of(m.head), "upgrade")) return null;
            return m.header("upgrade");
        }

        /// The request wants a go-ahead before it sends its body.
        /// Reading the body sends it. This is a fact about the head, so
        /// it stays true after the 100 has gone out. Any other `Expect`
        /// was already rejected by `receive`.
        pub fn expectsContinue(m: M) bool {
            comptime only(.request, "expectsContinue");
            m.check();
            const value = m.header("expect") orelse return false;
            return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), "100-continue");
        }

        // Responses only.

        pub fn status(m: M) u16 {
            comptime only(.response, "status");
            m.check();
            return m.head.status;
        }

        pub fn reason(m: M) []const u8 {
            comptime only(.response, "reason");
            m.check();
            return m.head.reason;
        }
    };
}

pub const HeaderIterator = struct {
    rest: []const scan.Header,
    name: []const u8,

    pub fn next(it: *HeaderIterator) ?[]const u8 {
        while (it.rest.len != 0) {
            const h = it.rest[0];
            it.rest = it.rest[1..];
            if (std.ascii.eqlIgnoreCase(h.name, it.name)) return h.value;
        }
        return null;
    }
};
