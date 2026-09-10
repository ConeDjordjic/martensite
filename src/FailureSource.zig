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
