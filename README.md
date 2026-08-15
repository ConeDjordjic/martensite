# martensite

HTTP/1.1 for Zig, as parts rather than a framework.

There is no router here, no middleware, no handler type, no `main`. It parses
requests, works out how long the body is, decodes chunked encoding, and writes
responses. You bring the loop.

Named for the crystal phase steel takes when quenched faster than its carbon
can escape.

## What it is

```zig
const martensite = @import("martensite");

var headers: [64]martensite.Header = undefined;
const scanned = try martensite.scan.request(bytes, &headers, 0) orelse return;

// scanned.head.method, .target, .minor_version, .headers
// scanned.len is where the body starts
```

Nothing allocates. The head borrows the bytes you passed in and the headers
land in the array you passed in, so the only memory involved is memory you
already had. This is `httparse`'s shape, not `hyper`'s.

`martensite.body.request(head)` tells you the framing and refuses the
ambiguous cases. `martensite.chunked.Decoder` decodes in place. Neither knows
what a socket is.

## The one rule

**Everything you get back borrows a buffer you own, and stays valid until the
next thing you do to that buffer.** There is no allocator here to make copies
for you, so if you want a method, a target or a header value to outlive the
request, copy it out yourself.

Concretely, for `Server`: a `Request` is good until the next `receive`. After
that its slices point at whatever has since been read over them.

This is the one thing worth getting right before writing any code against
martensite, so it is checked rather than just written down. In Debug and
ReleaseSafe, touching a stale `Request` panics:

```
thread 547234 panic: request outlived the receive that produced it
```

In ReleaseFast the check is gone and you get garbage, which is the same deal
as an index out of range. `req.live()` answers the question without panicking
if you would rather ask.

## Running on an Io

`martensite.Server` is the one piece that takes a `std.Io`, and it is
optional:

```zig
var reader = stream.reader(io, &read_buf);
var writer = stream.writer(io, &write_buf);
var http: martensite.Server = .init(io, &reader.interface, &writer.interface, .{
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

Any `std.Io` implementation works, because that is what an interface is for.
`examples/hello.zig` is a whole server in about sixty lines.

`head_buf` is the one place martensite does copy. Reading a body advances the
reader past the head, and the next fill rebases its buffer over the bytes the
head pointed at, so a request that has a body gets its head copied there
first. A request without one never touches it, and you can leave it out if
you only serve GETs.

One thing to know: **`std.Io.Uring` cannot serve HTTP in Zig 0.16.** Every
socket operation in its vtable is a stub that returns `error.NetworkDown`, so
`listen` fails immediately. It also does not compile without a two-line patch
to two error sets. Use `std.Io.Threaded`, which works, or a third-party
runtime like [zio](https://github.com/lalinsky/zio) for io_uring. When the
standard one grows sockets, nothing here has to change.

## Correctness

```
zig build test
```

Framing is where request smuggling lives, so:

## Installing

```
zig fetch --save git+https://github.com/ConeDjordjic/martensite
```

Zig 0.16.0. The language is not at 1.0 yet, so expect a commit per
release.

## Not here

TLS, HTTP/2, a router, a client. Postgres and WebSocket were in the C version
and are not in this one. Some of that may come back as separate packages; none
of it belongs in a parser.

