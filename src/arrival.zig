//! For tests. Bytes arrive either all at once or one per read.
//!
//! `split` is where the reading bugs turn up, because it is the only
//! thing that separates what we actually read from what we assumed was
//! already there. Every fixture runs both.

const std = @import("std");
const Io = std.Io;
const FailureSource = @import("FailureSource.zig");

pub const Shape = enum { whole, split };

pub const shapes = [_]Shape{ .whole, .split };

/// Room for `max_bytes` of split input plus a `buffer_len` reader
/// buffer. The caller owns it and the reader points into it.
pub fn Source(comptime max_bytes: usize, comptime buffer_len: usize) type {
    return struct {
        fixed: Io.Reader,
        trickle: std.testing.Reader,
        calls: [max_bytes]std.testing.Reader.Call,
        small: [buffer_len]u8,

        const Self = @This();

        pub fn reader(s: *Self, shape: Shape, input: []const u8) *Io.Reader {
            switch (shape) {
                .whole => {
                    s.fixed = .fixed(input);
                    return &s.fixed;
                },
                .split => {
                    std.debug.assert(input.len <= s.calls.len);
                    for (s.calls[0..input.len], 0..) |*c, i| c.* = .{ .buffer = input[i..][0..1] };
                    s.trickle = .init(&s.small, s.calls[0..input.len]);
                    return &s.trickle.interface;
                },
            }
        }

        /// How much the reader can hold. `head_buf` has to match this.
        pub fn bufferLen(_: *const Self, shape: Shape, input: []const u8) usize {
            return switch (shape) {
                .whole => input.len,
                .split => buffer_len,
            };
        }
    };
}

/// Same thing, but for inputs sized at runtime.
pub const Alloc = struct {
    gpa: std.mem.Allocator,
    calls: []std.testing.Reader.Call = &.{},
    fixed: Io.Reader = undefined,
    trickle: std.testing.Reader = undefined,
    small: [512]u8 = undefined,

    pub fn reader(a: *Alloc, shape: Shape, input: []const u8) !*Io.Reader {
        switch (shape) {
            .whole => {
                a.fixed = .fixed(input);
                return &a.fixed;
            },
            .split => {
                a.calls = try a.gpa.alloc(std.testing.Reader.Call, input.len);
                for (a.calls, 0..) |*c, i| c.* = .{ .buffer = input[i..][0..1] };
                a.trickle = .init(&a.small, a.calls);
                return &a.trickle.interface;
            },
        }
    }

    /// How much the reader can hold.
    pub fn bufferLen(a: *const Alloc, shape: Shape, input: []const u8) usize {
        return switch (shape) {
            .whole => input.len,
            .split => a.small.len,
        };
    }

    pub fn deinit(a: *Alloc) void {
        a.gpa.free(a.calls);
    }
};

/// A reader that always fails and knows why, so tests can drive
/// `Options.failure` without waiting for a real timeout.
pub const Failing = struct {
    interface: Io.Reader = undefined,
    buf: [64]u8 = undefined,
    why: anyerror = error.Timeout,

    pub fn init(f: *Failing) void {
        f.interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = &f.buf,
            .seek = 0,
            .end = 0,
        };
    }

    fn stream(_: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
        return error.ReadFailed;
    }

    fn cause(ctx: *anyopaque) ?anyerror {
        const f: *Failing = @ptrCast(@alignCast(ctx));
        return f.why;
    }

    /// Pass this to `Options.failure`.
    pub fn source(f: *Failing) FailureSource {
        return .{ .ctx = f, .cause = cause };
    }
};
