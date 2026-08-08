//! HTTP/1.1 for Zig.
//!
//! scan, body and chunked are plain byte-slice code with no I/O. Server
//! and Client need an Io, but you don't have to use them.

pub const scan = @import("scan.zig");
pub const chunked = @import("chunked.zig");
pub const body = @import("body.zig");

pub const Response = @import("Response.zig");
pub const Server = @import("Server.zig");

pub const Header = scan.Header;
pub const Head = scan.Head;
pub const Status = Response.Status;

test {
    _ = scan;
    _ = chunked;
    _ = body;
    _ = Response;
    _ = Server;
}
