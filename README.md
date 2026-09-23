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

## Where slices point

Every slice you get back points into a buffer you own. It stays valid
until the next operation on that buffer, which for `Server` means the
next `receive`. If something has to outlive the request, copy it out.

If you use a `Request` after that, it panics in Debug and ReleaseSafe:

```
thread 547234 panic: message outlived the receive that produced it
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

`readBody` needs a buffer that fits the whole body. If the request uses
`Content-Length` you know the size before reading anything:

```zig
const n = req.contentLength() orelse return tooVague();
if (n > max_body) return tooLarge();
const buf = try arena.alloc(u8, n);      // this body, not the largest one
const body = try http.readBody(buf);
```

If you skip that, the only safe size is the biggest request you are
willing to serve, and then every small request pays for it.
`contentLength` returns null for a chunked body, because there the length
is not known until you read it, and also for a request with no body at
all. Use `req.hasBody()` to tell those two apart. `Client.Response` has
both methods too.

One request gets one response. Calling `respond` twice for the same
request gives you `error.AlreadyAnswered`, because the second one would
go out as the answer to a request the peer has not sent yet. Reading
works the same way while a streamed response is open. `receive` returns
`error.ResponseOpen` until `end` finishes the body.

Any error out of a `ResponseWriter` means the body on the wire is
incomplete. `LengthMismatch` means the body was shorter than promised,
`InvalidTrailer` means a trailer would have changed the framing, and
`WriteFailed` means the write itself failed. After any of them the
connection closes and the writer is done. `end` and `endWithTrailers`
also return `Finished`, and `flush` returns `WriteFailed`, which is the
only error `Io.Writer` has.

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

`decode_buf` is the reader's own scratch space. It buffers into it, and a
chunked body is decoded there on the way out. A few hundred bytes is
enough no matter what the framing is. Less than two bytes gives you
`error.NoDecodeBuffer`, since a reader with no room to buffer can't
implement `takeByte`.

A body is read once and one way. A second `readBody` or `bodyReader` for
the same message is `error.BodyTaken`. If you hand a body to a
`bodyReader` and don't read it to the end, the connection ends, because
after that there is no way to know where the next message starts.

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
`examples/api.zig` is the bigger one: routing on method and path, a
streamed response, an upload that gets rejected before its body is sent,
and trailers at the end of a chunked response.

## A client

```zig
var client: martensite.Client = try .init(io, &reader.interface, &writer.interface, .{
    .headers = &headers,
    .head_buf = &head_buf,
});
try client.send(.{ .method = "POST", .target = "/things", .body = payload });
const res = (try client.receive()) orelse return error.Closed;
if (res.status() != 200) return error.Unexpected;
const body = try client.readBody(&buf);
```

A status you read is a `u16`, not the `Status` enum you write a response
with. Usually what you care about is the class (`res.status() < 300`),
and the number comes from the peer, not from this library. For the same
reason `method()` and `target()` on a request give you raw bytes, with
`knownMethod()` and `parsedTarget()` if you want a parsed form.

One exchange at a time. A second `send` before the response has arrived
is `error.ExchangeOpen`, and a `receive` with nothing outstanding is
`error.NothingSent`. An interim `1xx` does not close the exchange, so the
next `receive` gives you the real response. A `Connection: close` in the
headers you send ends the connection after that exchange, the same as one
from the server.

`Client.Options` has `trailer_buf` and `failure` just like `Server`'s, so
trailers from a chunked response show up in `client.trailers(&storage)`
and a peer that goes quiet comes back as `error.Timeout`.

A request body too big to hold in memory goes out the same way a response
does:

```zig
var rw = try client.sendStreaming(.{ .method = "POST", .target = "/upload" }, &out_buf, .{});
_ = try file_reader.interface.streamRemaining(&rw.interface);
try rw.end();
```

And responses too big to buffer stream like request bodies:

```zig
var b = try client.bodyReader(&decode_buf);
_ = try b.interface.streamRemaining(&file_writer.interface);
```

Name resolution, redirects and connection pooling are out of scope. Those
belong in a client library.

## TLS

There is none, same as hyper. `Server` and `Client` take a `Reader` and a
`Writer`, and so does `std.crypto.tls.Client`, so you can stack one on
the other. `examples/tls_client.zig` does that.

Two things to watch out for. First, `head_buf` still has to be at least
as big as the reader's buffer, and with TLS in between that buffer is a
TLS record, not a round 16K. Second, `send` flushes the TLS writer, but
that only pushes the bytes into the socket writer's buffer, so you have
to flush that one yourself. If you forget, it looks like the server
closed without answering, which took me a while to figure out.

std only ships a TLS client, not a server, so a martensite server needs
something in front of it to terminate TLS.

## Upgrades

```zig
const proto = req.upgradeTo() orelse return;
try http.upgrade(.{ .status = .switching_protocols, .headers = &.{ ... } });
// reader and writer are yours now
```

Clients usually send their first frame without waiting for the 101, and
those bytes are still sitting in the reader after the handover.
`examples/websocket.zig` is a working echo server with framing.

`upgrade` only takes a status that switches protocols. Anything else is
`error.NotSwitching`. If the request has a body you haven't read, it gets
drained first, within `max_drain`. If it can't be, you get
`error.BodyPending`, because otherwise the new protocol would read the
body as its own first bytes. The request is still unanswered then, so you
can send an error instead, and the connection closes after it.

A `CONNECT` answered with a 2xx is the other handover. What comes after
it is a tunnel, so the answer has no body and no framing headers, and the
connection stops being HTTP as soon as that answer goes out. After that
`http.handedOver()` is true and the reader and writer are yours. `respond`
hands over by itself for a 2xx to a `CONNECT` or a 101, and trying to
stream either one gives `error.NoBodyToStream`.

On the client side, a `101` or a 2xx answer to a `CONNECT` you sent comes
back from `receive` so you can read the head, and nothing more is sent or
received on that connection. Call `client.handOver()` when you are done
with the head. Anything the peer sent after it is waiting in the reader.

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

`Client.Options` has the same field.

Without it a timeout stays `error.ReadFailed`. Anything that is not a
timeout stays `error.ReadFailed` either way, because you handle all of
them the same way, by closing the connection.

## Correctness

```
zig build test
zig build test -Dtest-filter="real socket"
```

Some of the tests run over a real socket instead of a buffer. Every
`Server` test also runs a second time with the bytes arriving one at a
time, which is what catches the difference between what was actually read
and what the code assumed was there.

Request smuggling happens in the framing, so all of these are rejected:

- `Content-Length` and `Transfer-Encoding` together.
- Either header twice with different values.
- A `Content-Length` with anything but digits in it.
- `Transfer-Encoding` that does not end in `chunked`.
- A bare LF where a chunk size line needs CRLF.
- A CR in a trailer line with no LF after it.
- Response header values with CR, LF or NUL in them.

Repeated spaces in a request line and folded headers are rejected too.

The same list applies to what this library *writes*. A response or
request that carries both framing headers, or two lengths that disagree,
or a `Content-Length` that is not the length of the body being written,
is `error.AmbiguousFraming` and never reaches the wire. Writing a message
that martensite itself would refuse to read is how a body gets smuggled
past whichever end is less careful. The check happens before the first
byte goes out and before the request counts as answered, so the handler
can still send something else.

Writing `Transfer-Encoding: chunked` yourself and passing already chunked
bytes as the body still works. They have to end with `0\r\n\r\n`, and
trailers after the last chunk go through `respondStreaming` and
`endWithTrailers` rather than in the body.

A connection costs whatever buffers you hand it, plus 176 bytes of
bookkeeping on x86-64, 136 of which is the head window. A test pins both
numbers, so if they grow you see it in the diff.

## Not here

TLS, HTTP/2, a router, connection pooling.

## Installing

```
zig fetch --save git+https://github.com/ConeDjordjic/martensite
```

Zig 0.16.0. The language is not at 1.0 yet, so expect a commit per
release.
