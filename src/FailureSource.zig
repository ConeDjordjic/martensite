//! Why the last read failed.
//!
//! `std.Io.Reader` only ever says `error.ReadFailed`, so a reader that
//! knows the peer timed out instead of disappearing has no way to tell
//! us through the interface. This works around it: a pointer to the
//! reader, plus a function that gets the cause back out.
//! `TimedReader.failureSource` gives you one.

const FailureSource = @This();

ctx: *anyopaque,
cause: *const fn (*anyopaque) ?anyerror,

/// Why the last read failed, if the reader kept it.
pub fn last(f: FailureSource) ?anyerror {
    return f.cause(f.ctx);
}

/// What to report a `ReadFailed` as. Only `Timeout` gets its own error.
/// Reset, no route and out of resources all end the connection the same
/// way, so there would be nothing for the caller to decide.
/// Takes an optional so callers without a source can still call it.
pub fn readError(f: ?FailureSource) error{ Timeout, ReadFailed } {
    const src = f orelse return error.ReadFailed;
    const cause = src.last() orelse return error.ReadFailed;
    return if (cause == error.Timeout) error.Timeout else error.ReadFailed;
}
