//! HTTP/1.1 for Zig.
//!
//! scan, body and chunked are plain byte-slice code with no I/O. Server
//! and Client need an Io, but you don't have to use them.

pub const scan = @import("scan.zig");
pub const chunked = @import("chunked.zig");
pub const body = @import("body.zig");
pub const target = @import("target.zig");

pub const Response = @import("Response.zig");
pub const Date = @import("Date.zig");
pub const Server = @import("Server.zig");
pub const Client = @import("Client.zig");
pub const TimedReader = @import("TimedReader.zig");

pub const Header = scan.Header;
pub const Head = scan.Head;
pub const Method = scan.Method;
pub const Status = Response.Status;

test {
    _ = scan;
    _ = chunked;
    _ = body;
    _ = target;
    _ = Response;
    _ = Date;
    _ = Server;
    _ = Client;
    _ = TimedReader;
    _ = @import("integration_test.zig");
}
