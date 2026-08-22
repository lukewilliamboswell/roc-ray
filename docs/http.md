# HTTP client

`Http` is roc-ray's HTTP client. It exists because the interesting graphics
programs are increasingly the ones that draw somebody else's data: a live
dashboard, a remote-telemetry plot, a leaderboard. Issue #151 put the objection
plainly -- *every sibling effect is synchronous; blocking 200 ms in a 60 fps
loop costs twelve frames* -- and this platform answers it with the task model
rather than with a callback API.

```roc
update! = |model, input| {
    if input.devices.key_pressed(KeyR) {
        Task.spawn!(
            || match Http.get_utf8!("http://127.0.0.1:8000/data.json") {
                Ok(body) => Loaded(body)
                Err(_) => Failed
            },
        )
    }
    Ok(model)
}
```

`Http.get_utf8!` there is synchronous, exactly like basic-cli's. It returns the
body or an error and nothing else runs in that task until it does. What it does
not do is stall the frame: the host runs the closure on its own coroutine, parks
it on the socket, and the frame loop draws every frame it would have drawn
anyway. The closure's return value arrives on a later `Input.messages`.

See `examples/http_fetch/main.roc`.

## The API

The request and response types come from the shared
[`roc-lang/http`](https://github.com/roc-lang/http) package, the same ones
basic-cli uses, so an app that knows one knows the other. Add it to your app
header alongside the platform:

```roc
app [Model, program] {
    rr: platform "...",
    http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
    roc: "...",
}
```

| Function | What it does |
| --- | --- |
| `Http.send!(request)` | Validate the URI and send, under `Http.default_config` |
| `Http.send_with!(config, request)` | The same under explicit limits |
| `Http.send_json!(request, value)` | Encode `value` as JSON, attach it, send |
| `Http.get_utf8!(url)` | GET, and decode the body as UTF-8 |
| `Http.get!(url)` | GET, and parse the body as JSON |
| `Http.with_json_body(request, value)` | Attach a JSON body and `Content-Type` |
| `Http.decode_json_response(response)` | Parse a response body as JSON |

`get_utf8!` and `get!` take a validated `Url`, so a quoted literal in the source
is checked when it compiles. A URL built at runtime goes through `Url.parse`, or
through `Http.send!`, which parses the request's `uri` itself and reports
`InvalidUrl` when it is not one. Fragments are stripped before sending, because
they are client-side identifiers.

`Url` is roc-ray's own module -- a byte-for-byte copy of basic-cli's, which is
where the parser lives; the shared `http` package deliberately has no URL type.
It is strict on purpose: ASCII DNS names, dotted-decimal IPv4, bracketed IPv6.
Internationalized domain names are rejected rather than guessed at.

## Phases

`Http.send!` waits, so it is a *task* effect, subject to the same phase guard as
`Task.sleep!`:

| Called from | What happens |
| --- | --- |
| inside `Task.spawn!` | parks the coroutine; the frame loop keeps running |
| `init!` | blocks the startup callback, which is where blocking belongs |
| `update!` | the host stops the app and names the phase |
| `render!` | the same |

The `update!` rejection reads:

```
roc-ray: Http.send! is only valid during init! or a task, but it was called
during update!. It waits: call it inside Task.spawn!, where it parks the task,
or in init!, where it blocks.
```

## Limits

Every send carries a deadline and a hard cap on the response body.
`Http.default_config` is 30 s and 8 MiB; `Http.send_with!` takes a different
`Config`. Zero disables either one, which is only ever appropriate against a
server you control.

**The timeout** covers the whole exchange -- connect, TLS handshake, request,
response head, body. A `TimeoutMilliseconds` on the request itself overrides the
config's, and `NoTimeout` on the request means the config's applies, so a request
built the ordinary way is never sent without a deadline.

It is implemented by arming zio's `AutoCancel` around the exchange. The scoped
`zio.withTimeout` was tried first and is *wrong here*: it turns a cancellation
into `error.Timeout` only when the wrapped call can return `error.Canceled`, and
`std.http`'s error sets carry no such error -- a cancelled socket read surfaces
several layers up as `error.ReadFailed`. A timed-out fetch was reported as
`NetworkError`. Arming the timer by hand lets the timer, rather than the error
value, decide. The cancellation is then consumed, so the next effect in the same
task is not cancelled for no visible reason.

**The response cap** is enforced while the body is read, not after: the reader is
given `max_response_bytes + 1` and a body that reaches the limit fails the send.
It is a refusal, never a truncation -- a truncated body decodes into wrong data
instead of into an error. The failure arrives as
`Other("the response body is larger than max_response_bytes (N)")`.

The cap applies to the *decompressed* body. A gzip response is decompressed as it
is read and counted as it is decompressed, so a small compressed payload that
expands past the cap is still refused.

## TLS

`https` is handled by Zig's `std.crypto.tls` against the system certificate
store, loaded through `std.crypto.Certificate.Bundle.rescan`.

**Linux**: verified working on this platform against a real `https://` host.
`rescan` reads the usual `/etc/ssl/certs` locations.

**macOS and Windows**: not verified. `Bundle.rescan` has a Windows path (the
system certificate store) and a macOS path (the system keychain / trust
settings), but roc-ray's CI does not yet make an HTTPS request on either, so
neither is claimed here. The failure mode, if a store cannot be read, is a clean
`Other("the system certificate store could not be loaded for TLS")` rather than
an insecure fall-through -- but it is a gap in coverage and the first thing to
check when porting.

There is no way to supply a custom CA bundle or to disable verification, and no
plan to add one.

## What the host does per request

One `std.http.Client` per send, with `keep_alive = false`. The client owns both
the connection pool and the TLS trust store, and one that outlived the send would
have to be torn down from outside any coroutine, where its `io` calls are not
valid. The price is a TCP handshake per request and, on HTTPS, a certificate
store rescan per request -- a few milliseconds, off the frame thread's critical
path but not free. An app polling an endpoint many times a second will feel it.
Sharing a client across sends is the obvious optimization and is left undone
deliberately, because it needs a shutdown story first.

Headers `std.http.Client` emits itself -- `Host`, `Authorization`, `User-Agent`,
`Connection`, `Accept-Encoding`, `Content-Type` -- are routed to its override
slots, so setting `User-Agent` yields one on the wire rather than two. Header
names and values are checked for wire-legal bytes before the client sees them,
because the client asserts them and would otherwise abort the process on an app's
typo.

`std.http.Method` is a closed enum of the nine RFC methods. `QUERY` and any
`Unknown(ext)` method are reported as an error rather than rewritten into
something else.

## Errors

Transport failures arrive as `Http.TransportErr`, the same set basic-cli uses:

| Variant | When |
| --- | --- |
| `Timeout` | the deadline expired |
| `NetworkError` | the connection could not be made or did not survive |
| `BadBody` | a reply arrived but was not a well-formed HTTP response |
| `Other(bytes)` | anything else, with the host's description |

An HTTP status is *not* an error: a 404 is `Ok` with `Response.status` of 404.

The wire shape between Roc and the host carries no tag union -- the host returns
an `err` code plus a message, and `Http` rebuilds the union. A code `Http` does
not recognise becomes `Other(message)` rather than crashing, so the host can
learn to distinguish a new failure without breaking an app built against an older
platform.

## Size of a locally built platform

A Debug host archive carries the whole of `std.crypto` for TLS. Building the
platform with a plain `zig build` grew the four host archives from 50.8 MB to
88.1 MB, and a bundle of them from about 88 MB to 125 MB -- past roc's default
100 MB transitive-dependency budget, which made *every* app fail to build against
a locally bundled platform.

`zig build -Doptimize=ReleaseFast`, which is what the release workflow runs and
what a release ships, produces 9.9 MB of host archives, so a published platform
is unaffected. The test harness passes `--max-transitive-mb=512`; see
`scripts/local_bundles.py`. If you bundle a Debug platform by hand, you will need
the same flag.

## Testing

`scripts/test_http_client.py` runs a `http.server` handler on a free loopback
port and drives `test/http_fetch` at it three times: a plain fetch, the same
fetch under a `max_response_bytes` smaller than the body, and a slow route under
a 200 ms deadline. Nothing reaches the public internet.

The verdict is reached in Roc, on the value `Http.send_with!` returned -- status,
header count, body text -- so a host that truncates a body, loses the status, or
drops the header list fails the test rather than passing it quietly. Each case
also asserts on a `ROC_RAY_TRACE_TASKS` line, so a pass means the host and the
app agree about what arrived.

`ROC_RAY_TRACE_TASKS=1` prints, per request:

```
[TASK] http GET http://127.0.0.1:8000/data.txt parking
[TASK] http 200 resumed with 56 byte body from http://127.0.0.1:8000/data.txt
[TASK] http body: roc-ray-http-token-9f3a second line of the served file
```

The body preview is the first 200 bytes with control characters blanked. It is
the difference between "the fetch failed" and "the endpoint served an HTML error
page", and it is what makes an HTTP problem debuggable from a log.
