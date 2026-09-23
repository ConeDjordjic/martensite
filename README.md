# martensite

An HTTP/1.1 library for Zig.

It parses requests and responses, finds where each body ends, decodes
and encodes chunked bodies and writes responses. There is no router or
middleware.

```zig
const martensite = @import("martensite");

var headers: [64]martensite.Header = undefined;
const scanned = try martensite.scan.request(bytes, &headers, 0) orelse return;

// scanned.head.method, .target, .headers
// scanned.len is where the body starts
```

It doesn't allocate memory. The `scan`, `body` and `chunked` modules
work on byte slices and do no I/O. `Server` and `Client` need a
`std.Io`, but you can use the parser on its own.

## Slices point into your buffers

Every slice you get back points into a buffer you passed in. It stays
valid until the next operation on that buffer, which for `Server` is the
next `receive`. Copy anything you need after that.

Using a `Request` after that panics in Debug and ReleaseSafe:

```
thread 547234 panic: message outlived the receive that produced it
```

ReleaseFast has no check, so you read stale memory. `req.live()` tells
you whether a request is still valid.

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

`head_buf` keeps the request head while you read the body. Requests
without a body don't use it, so you can pass an empty slice. If you pass
a non-empty one, it must be at least as big as the reader's buffer.
Otherwise a request could be accepted without a body and rejected with
one. `init` returns an error if it's too small.

`readBody` needs a buffer that fits the whole body. With
`Content-Length` you know the size before reading:

```zig
const n = req.contentLength() orelse return tooVague();
if (n > max_body) return tooLarge();
const buf = try arena.alloc(u8, n);      // this body, not the largest one
const body = try http.readBody(buf);
```

If you don't check the length first, every request needs a buffer as big
as the largest body you accept.

`contentLength` returns null for a chunked body, because the length
isn't known until it's read. It also returns null when there is no body.
Use `req.hasBody()` to tell them apart. `Client.Response` has both
methods too.

Inside `serve`, return errors from `readBody` with `try`. `serve`
answers `BodyTooLarge` with 413 and a malformed body with 400. If you
catch the error and respond yourself, you have to choose the status for
each error.

`receive` rejects an HTTP/1.1 request that has no `Host` header, more
than one, or one that isn't a host with an optional port. The error is
`error.BadHost` and the response is 400. HTTP/1.0 requests can leave
`Host` out. For a target like `http://a/x`, the host comes from the
target, and `Host` only has to appear once. A target that isn't one of
the four forms HTTP allows, like `a/b`, is `error.BadRequest`. That's
why `req.parsedTarget()` doesn't return an optional.

`.text`, `.json` and `.html` set the response's `content_type`. Other
headers go in `headers`:

```zig
var r: martensite.Response = .json(.ok, body);
r.headers = &.{.{ .name = "Set-Cookie", .value = cookie }};
try http.respond(r);
```

If `headers` also has a Content-Type, you get `error.InvalidHeader` and
nothing is sent.

You can respond to a request once. Calling `respond` again returns
`error.AlreadyAnswered`, because the peer would take the second response
as the answer to its next request. While a streamed response is open,
`receive` returns `error.ResponseOpen` until you call `end`. A 1xx other
than 101, like 103 Early Hints, doesn't count as the response, so you
can send one before it.

If a `ResponseWriter` returns an error, the body on the wire is
incomplete. `LengthMismatch` means the body was shorter than the
`Content-Length`, `InvalidTrailer` means a trailer would have changed
the framing, and `WriteFailed` means the write failed. The connection
then closes and the writer can't be used again. `end` and
`endWithTrailers` can also return `Finished`. `flush` only returns
`WriteFailed`, since that's the only error `Io.Writer` has.

If the handler doesn't read the body, the server reads and discards it
before the next request, up to `max_drain` bytes. The default is 64 KiB.
That way you can answer a POST with 401 or 404 without reading the body,
and the connection stays open. A bigger body closes the connection, and
the response includes `Connection: close`. Set `.max_drain = 0` to never
read a body you didn't ask for. `http.setMaxDrain(n)` changes the limit
for the current request, for example on an upload route that responds
early.

Every response gets a `Date` header unless it already has one. Set
`.date = false` to turn this off.

Bodies that are too big to buffer can be streamed:

```zig
var b = try http.bodyReader(&decode_buf);
_ = try b.interface.streamRemaining(&file_writer.interface);
```

`decode_buf` is the reader's working buffer, and chunked bodies are
decoded into it. A few hundred bytes is enough. Less than two bytes
gives `error.NoDecodeBuffer`, because the reader can't implement
`takeByte` without room to buffer.

A body can be read once, with `readBody` or with `bodyReader`. A second
attempt returns `error.BodyTaken`. If you stop reading a `bodyReader`
before the end, the connection closes, because the server can't tell
where the next request starts.

To stream a response, leave out the length and it's sent chunked:

```zig
var rw = try http.respondStreaming(.{}, &out_buf, .{});
try rw.interface.print("data: {d}\n\n", .{n});
try rw.end();
```

`out_buf` is the writer's buffer. Its size is the most data sent in one
write, which for a chunked response is the chunk size. It's used
differently from the buffer you pass to `bodyReader`.

### The loop

The loop at the top doesn't handle errors. `serve` runs the same loop
and does:

```zig
http.serve(&app, .{
    .deadline = reader.deadlines(),   // reader is a TimedReader
    .head = .{ .duration = seconds(10) },
    .body = .{ .duration = seconds(30) },
}) catch |err| log(err);
```

`serve` calls `app.handle(&http, req)` for each request. `handle` must
be `pub`. The `head` deadline covers waiting for a request and reading
its head. The `body` deadline starts when the handler is called. Without
`.deadline` there are no time limits.

The deadlines work together with the timeout you pass to
`TimedReader.init`. That timeout limits each read and restarts on every
read. A deadline limits a whole stage. A read stops at whichever comes
first, so a peer that sends one byte every few seconds won't hit the
read timeout but will hit the deadline. When you use a `TimedReader`,
pass `.failure = reader.failureSource()` to `Server.init` as well.
Without it a timeout is treated like any other failed read and gets 400
instead of 408.

`serve` stops at the first error and returns it. Before that, it sends
a response if the peer hasn't had one:

- A request that couldn't be read gets `Status.forError` and
  `Connection: close`.
- A handler error gets the same if nothing has been sent yet. A handler
  that calls `try http.readBody(&buf)` therefore answers 413 when the
  body doesn't fit, and its other errors answer 500.
- If the handler fails after `respondStreaming`, the head is already
  sent and the body can't be fixed. Nothing more is written and the
  connection closes.
- If the handler returns without responding, the peer gets 500 and
  `serve` returns `error.NoResponse`.

Close the stream after `serve` returns.

For your own error responses, for example in JSON, add
`pub fn onError(app, http, req, err) !void` to the app and respond from
it. It's called for every handler error before anything is sent, except
`Canceled`. Errors that `onError` responds to don't stop the loop and
aren't returned from `serve`, so log them there. The connection stays
open unless the error came from the server, like `BodyTooLarge`, or the
handler read part of the body and stopped. Then the response gets
`Connection: close` regardless. If `onError` doesn't respond, `serve`
does what's described above.

`Status.forError` gives the right status for each error, so you don't
need your own mapping:

```zig
pub fn onError(app: *App, http: *martensite.Server, _: martensite.Server.Request, err: anyerror) !void {
    const status: martensite.Status = .forError(err);
    if (@intFromEnum(status) >= 500) app.log(err);   // only our own errors
    try http.respond(.text(status, status.phrase()));
}
```

`pub fn onReceiveError(app, http, err) !void` is the same for a request
that couldn't be read, like a bad head or a timeout. It doesn't get a
request. The connection always closes afterwards, because the server
can't tell where the next request would start, and `serve` still
returns the error.

For an access log, read `http.last`. It has the status of the last
response, the number of body bytes sent and whether the whole body was
sent. It also covers the responses `serve` sends on its own, so you can
read it after `handle`, in `onError` and after `serve` returns.
`receive` resets it.

`serve` has no routing and no context type. If you need those, write
your own loop.

`examples/hello.zig` is a complete server using `serve`.
`examples/api.zig` also uses it, with routing on method and path, a
streamed response, an upload rejected before its body is sent, and
trailers at the end of a chunked upload.

## A client

```zig
var client: martensite.Client = try .init(io, &reader.interface, &writer.interface, .{
    .headers = &headers,
    .head_buf = &head_buf,
});
try client.send(.{
    .method = "POST",
    .target = "/things",
    .headers = &.{.{ .name = "Host", .value = "example.com" }},
    .body = payload,
});
const res = (try client.receive()) orelse return error.Closed;
if (res.status() != 200) return error.Unexpected;
const body = try client.readBody(&buf);
```

`res.status()` returns a `u16`. The `Status` enum is only for writing
responses, because a peer can send any number. Most of the time you
check a range, like `res.status() < 300`. For the same reason, `method()`
and `target()` on a request return raw bytes. `knownMethod()` and
`parsedTarget()` give you parsed versions. `knownMethod()` is null for
methods other than the eight in RFC 9110 and PATCH, and the usual
response to those is 501.

You have to send `Host` yourself, because the client doesn't know which
host it's connected to. A request with no `Host`, or one a server would
reject, returns `error.BadHost` and nothing is written.

The client handles one request at a time. Calling `send` before the
response arrives returns `error.ExchangeOpen`, and calling `receive`
without sending returns `error.NothingSent`. A 1xx response doesn't
count, so the next `receive` returns the real one. If you send
`Connection: close`, the connection closes after that response, just
like when the server sends it.

`Client.Options` has `trailer_buf` and `failure`, like the server.
Trailers from a chunked response are available through
`client.trailers(&storage)`, and a peer that stops responding gives
`error.Timeout`.

A request body too big to keep in memory can be streamed:

```zig
var rw = try client.sendStreaming(.{
    .method = "POST",
    .target = "/upload",
    .headers = &.{.{ .name = "Host", .value = "example.com" }},
}, &out_buf, .{});
_ = try file_reader.interface.streamRemaining(&rw.interface);
try rw.end();
```

So can a large response:

```zig
var b = try client.bodyReader(&decode_buf);
_ = try b.interface.streamRemaining(&file_writer.interface);
```

The client doesn't resolve names, follow redirects or pool connections.
A higher level client library would do that.

## TLS

martensite doesn't do TLS. `Server` and `Client` take a `Reader` and a
`Writer`, and `std.crypto.tls.Client` does too, so you can put TLS
between the socket and martensite. `examples/tls_client.zig` does this.

With TLS in between, `head_buf` still has to be at least as big as the
reader's buffer, and that buffer is now a TLS record, not 16 KB. Also,
`send` flushes the TLS writer, which only moves the bytes into the
socket writer's buffer. You have to flush the socket writer yourself.
If you forget, it looks like the server closed the connection without
responding. That took me a while to figure out.

The standard library only has a TLS client, so a martensite server needs
a reverse proxy or something similar in front of it for TLS.

## Upgrades

```zig
const proto = req.upgradeTo() orelse return;
try http.upgrade(.{ .status = .switching_protocols, .headers = &.{ ... } });
// reader and writer are yours now
```

Clients often send their first frame before they get the 101, so those
bytes can already be in the reader when you take over.
`examples/websocket.zig` is a working echo server with WebSocket
framing.

`upgrade` only accepts a status that switches protocols. Any other
status returns `error.NotSwitching`. If the request has a body you
haven't read, it's drained first, up to `max_drain`. If it can't be
drained you get `error.BodyPending`, because the new protocol would
otherwise read the body as its own data. The request hasn't been
answered yet at that point, so you can still send an error response.
The connection closes after it.

A 2xx response to `CONNECT` also hands the connection over. What comes
after it is a tunnel, so the response has no body and no framing
headers, and the connection is no longer HTTP once it's sent. After
that `http.handedOver()` is true and you own the reader and writer.
`respond` hands the connection over on its own for a 101 or a 2xx to
`CONNECT`. Streaming either one returns `error.NoBodyToStream`.

On the client, a 101 or a 2xx to a `CONNECT` you sent is returned from
`receive` so you can read its head. After that nothing more is sent or
read on the connection. Call `client.handOver()` when you've read the
head. Anything the server sent after it is waiting in the reader.

## Paths, queries and header lists

```zig
const t = req.parsedTarget();                    // t.path, t.query, t.form
var pairs: martensite.target.Pairs = .init(t.query);
const decoded = try martensite.target.decode(t.path, &buf);
const q = martensite.target.Pairs.get(t.query, "q") orelse "";
const words = try martensite.target.decodeQuery(q, &buf);
```

`decode` doesn't turn `+` into a space. `+` only means a space in form
data, and decoding it that way in a path breaks file names. Use
`decodeQuery` for query names and values, which does turn `+` into a
space. `%2B` decodes to `+` in both. For headers that can appear more
than once, `req.headerIter(name)` returns each of them.

Headers like `Accept-Encoding`, `Cache-Control` and `Content-Type` are
lists of tokens with parameters, and a quoted value can contain a
comma. `field.list` splits them without allocating:

```zig
var items = martensite.field.list(req.header("accept-encoding") orelse "");
while (try items.next()) |item| {        // item.token is "gzip", "br"
    var params = item.params();
    while (params.next()) |p| {          // p.name is "q", p.value is "0.8"
        const bytes = try martensite.field.unquote(p.value, &buf);
    }
}
```

`next` doesn't unquote values or parse numbers. Call `field.unquote` on
a quoted value, and parse `q` yourself. `next` returns `error.Malformed`
for an item it can't parse, like one with an unclosed quote, and the
list stops there. Items before it are still valid. Empty items are
skipped. ETags and `Link` URLs aren't token lists, so don't use this
for them.

## Runtimes

Any `std.Io` implementation works, which today means `std.Io.Threaded`.
`std.Io.Uring` has no networking in Zig 0.16. Its socket functions are
stubs that return `error.NetworkDown`, and it doesn't compile without a
two-line patch to two error sets. For io_uring now, use
[zio](https://github.com/lalinsky/zio). martensite won't need changes
when the standard library adds sockets to it.

`Server` has no clock. Deadlines come from `TimedReader`:

```zig
var reader: martensite.TimedReader = .init(io, stream, &buf, .{ .duration = five_seconds });
reader.startDeadline(.{ .duration = ten_seconds });  // for a whole message
```

The first limits a single read and the second limits a whole message.
Without them a peer can keep a connection open forever. With the values
above, a peer that sends nothing gets 408 after 5 seconds, and one that
sends a header every second is dropped after 11.

`std.Io.Reader` only has `error.ReadFailed`, so a peer that stopped
sending and a peer that disconnected look the same. If you give
`Server` a way to check, it can tell them apart:

```zig
.failure = reader.failureSource(),   // then receive() can return error.Timeout
```

`Client.Options` has the same field.

Without it, a timeout is `error.ReadFailed`. Other failures are always
`error.ReadFailed`, since you handle them all by closing the
connection.

## Testing

```
zig build test
zig build test -Dtest-filter="real socket"
```

Some tests run over a real socket. Every `Server` test also runs a
second time with the input arriving one byte at a time, which catches
code that assumes more data has arrived than actually has.

Request smuggling happens when a proxy and a server disagree about where
a message ends. martensite rejects:

- `Content-Length` and `Transfer-Encoding` together.
- Either header twice with different values.
- A `Content-Length` with anything but digits in it.
- A `Transfer-Encoding` that doesn't end in `chunked`.
- A bare LF where a chunk size line needs CRLF.
- A CR in a trailer line with no LF after it.
- Response header values with CR, LF or NUL in them.

It also rejects repeated spaces in a request line and folded headers.

martensite won't write these either. A request or response with both
framing headers, two lengths that disagree, or a `Content-Length` that
doesn't match the body returns `error.AmbiguousFraming` and isn't sent.
The check runs before anything is written and before the request counts
as answered, so the handler can still send a different response.

You can set `Transfer-Encoding: chunked` yourself and pass a body that's
already chunked. It must end with `0\r\n\r\n`. Trailers after the last
chunk go through `respondStreaming` and `endWithTrailers`, not in the
body.

Each connection uses the buffers you give it plus 176 bytes on x86-64,
136 of them in `HeadWindow`. A test checks both numbers, so any growth
shows up in the diff.

## Not included

TLS, HTTP/2, routing and connection pooling.

## Installing

```
zig fetch --save git+https://github.com/ConeDjordjic/martensite
```

Requires Zig 0.16.0. Zig isn't at 1.0 yet, so expect a new commit for
each Zig release.
