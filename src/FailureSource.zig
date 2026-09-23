//! Why the last read failed.
//!
//! `std.Io.Reader` only ever says `error.ReadFailed`, so a reader that
//! knows the peer timed out instead of disappearing has no way to tell
//! us through the interface. This works around that with a pointer to
//! the reader and a function that gets the cause back out.
//! `TimedReader.failureSource` gives you one.

const FailureSource = @This();

ctx: *anyopaque,
cause: *const fn (*anyopaque) ?anyerror,

/// Why the last read failed, if the reader kept it.
pub fn last(f: FailureSource) ?anyerror {
    return f.cause(f.ctx);
}

/// What to report a `ReadFailed` as. `Timeout` and `Canceled` get their
/// own errors. Reset, no route and out of resources all end the
/// connection the same way, so there would be nothing for the caller to
/// decide. `Canceled` has to come through as itself, or `serve` answers
/// a connection that is being shut down with a 400.
/// Takes an optional so callers without a source can still call it.
pub fn readError(f: ?FailureSource) error{ Timeout, ReadFailed, Canceled } {
    const src = f orelse return error.ReadFailed;
    const cause = src.last() orelse return error.ReadFailed;
    return switch (cause) {
        error.Timeout => error.Timeout,
        error.Canceled => error.Canceled,
        else => error.ReadFailed,
    };
}

/// `readError` for a body, which has no `Timeout` of its own.
pub fn bodyReadError(f: ?FailureSource) error{ ReadFailed, Canceled } {
    return switch (readError(f)) {
        error.Canceled => error.Canceled,
        error.Timeout, error.ReadFailed => error.ReadFailed,
    };
}
