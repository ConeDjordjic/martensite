# martensite

An HTTP/1.1 implementation in Zig.

It does request and response parsing, body framing, chunked transfer
encoding and response writing. There is no router and no middleware. Put
those in whatever you build on top.

```zig
const martensite = @import("martensite");

var headers: [64]martensite.Header = undefined;
const scanned = try martensite.scan.request(bytes, &headers, 0) orelse return;

// scanned.head.method, .target, .headers
// scanned.len is where the body starts
```

Nothing allocates. The `scan`, `body` and `chunked` modules take byte
slices and never touch I/O. `Server` and `Client` need a `std.Io`, but
you don't have to use either of them.

## The one rule

Every slice you get back points into a buffer you own. It stays valid
until the next operation on that buffer, which for `Server` means the
next `receive`. If something has to outlive the request, copy it out.

If you use a `Request` after that, it panics in Debug and ReleaseSafe:

```
thread 547234 panic: request outlived the receive that produced it
```

In ReleaseFast there is no check, so you just read a stale pointer. Use
`req.live()` if you want to test for it instead of crashing.

## A server

```zig
var http: martensite.Server = try .init(io, &reader.interface, &writer.interface, .{
    .headers = &headers,
    .head_buf = &head_buf,
});

while (true) {
    const req = try http.receive() orelse break;
    const body = try http.readBody(&body_buf);
    try http.respond(.text(.ok, body));
    if (!http.alive()) break;
}
```

`head_buf` is where the head is kept while you read a body. A request
without a body never uses it, so you can pass an empty slice. If you do
pass one, it has to be at least as big as the reader's buffer. Otherwise
the same request could be accepted or rejected depending on whether it
happened to have a body, which is confusing to debug. `init` rejects that
combination right away instead of letting it show up later as a
`HeadTooLarge`.

One request gets one response. A second `respond` for the same request is
`error.AlreadyAnswered`, because it would go out as the answer to a
request the peer has not sent yet.

If the handler never reads the body, the connection ends. Reading a body
you already rejected is up to you, so you have to say how much of it you
will take:

```zig
.max_drain = 64 * 1024,   // default is 0: don't read it, close instead
```

For bodies that are too big to buffer, stream them:

```zig
var b = try http.bodyReader(&decode_buf);
_ = try b.interface.streamRemaining(&file_writer.interface);
```

`decode_buf` is where chunked bytes are decoded on their way out; a few
hundred bytes is plenty, and a counted body never touches it.

Responses work the same way. You get chunked encoding when you don't give
a length:

```zig
var rw = try http.respondStreaming(.{}, &out_buf, .{});
try rw.interface.print("data: {d}\n\n", .{n});
try rw.end();
```

`out_buf` is the response writer's buffer, so its size is the biggest
piece that goes out in one write. With chunked encoding that is the chunk
size on the wire. Note this is not the same kind of buffer as the one
`bodyReader` takes, even though it sits in the same argument position.

`examples/hello.zig` is a complete server in about eighty lines.

## A client

```zig
var client: martensite.Client = try .init(io, &reader.interface, &writer.interface, .{
    .headers = &headers,
    .head_buf = &head_buf,
});
try client.send(.{ .method = "POST", .target = "/things", .body = payload });
const res = (try client.receive()) orelse return error.Closed;
const body = try client.readBody(&buf);
```

And responses too big to buffer stream like request bodies:

```zig
var b = client.bodyReader(&decode_buf);
_ = try b.interface.streamRemaining(&file_writer.interface);
```

Name resolution, redirects and connection pooling are out of scope. Those
belong in a client library.

## Upgrades

```zig
const proto = req.upgradeTo() orelse return;
try http.upgrade(.{ .status = .switching_protocols, .headers = &.{ ... } });
// reader and writer are yours now
```

Clients usually send their first frame without waiting for the 101, and
those bytes are still sitting in the reader after the handover.
`examples/websocket.zig` is a working echo server with framing.

## Routing bits

```zig
const t = req.parsedTarget() orelse return;      // t.path, t.query, t.form
var pairs: martensite.target.Pairs = .init(t.query);
const decoded = try martensite.target.decode(t.path, &buf);
```

`decode` leaves `+` alone. It only means space in a form body, and
decoding it inside a path breaks filenames. For headers that can show up
more than once, `req.headerIter(name)` walks all of them.

## Runtimes

Any `std.Io` implementation works, which right now means
`std.Io.Threaded`. `std.Io.Uring` has no networking in 0.16. Every
socket entry in its vtable is a stub that returns `error.NetworkDown`,
and it won't even compile without a two line patch to two error sets. If
you want io_uring today, use [zio](https://github.com/lalinsky/zio). None
of this code has to change when the standard backend grows sockets.

`Server` has no clock of its own. Deadlines come from `TimedReader`:

```zig
var reader: martensite.TimedReader = .init(io, stream, &buf, .{ .duration = five_seconds });
reader.startDeadline(.{ .duration = ten_seconds });  // for a whole message
```

The first one bounds a single read, the second bounds a whole message.
Without them a peer can hold a connection open forever. With the settings
above, a silent peer gets a 408 after 5 seconds, and one sending a header
per second is dropped after 11.

`std.Io.Reader` only reports `error.ReadFailed`, so a peer that went
quiet and a peer that went away look the same. If you give `Server`
somewhere to ask, it can tell them apart:

```zig
.failure = reader.failureSource(),   // then receive() can return error.Timeout
```

Without it a timeout stays `error.ReadFailed`. Anything that is not a
timeout stays `error.ReadFailed` either way, because they all end up in
the same place: stop serving this connection.

## Correctness

```
zig build test
zig build test -Dtest-filter="real socket"
```

Some tests run over a real socket rather than a buffer.

Framing is where request smuggling lives, so:

- `Content-Length` and `Transfer-Encoding` together: rejected.
- Either header twice with different values: rejected.
- A `Content-Length` with anything but digits in it: rejected.
- `Transfer-Encoding` that does not end in `chunked`: rejected.
- A bare LF where a chunk size line needs CRLF: rejected.
- A CR in a trailer line with no LF after it: rejected.
- Response header values with CR, LF or NUL in them: rejected.

Repeated spaces in a request line and folded headers are rejected too.

## Not here

TLS, HTTP/2, a router, connection pooling.

## Installing

```
zig fetch --save git+https://github.com/ConeDjordjic/martensite
```

Zig 0.16.0. The language is not at 1.0 yet, so expect a commit per
release.

