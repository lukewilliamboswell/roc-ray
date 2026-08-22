## An HTTP client for live dashboards and remote data visualization.
##
## Requests are built and read with the shared
## [`roc-lang/http`](https://github.com/roc-lang/http) `Request` and `Response`
## types, exactly as in
## [basic-cli](https://github.com/roc-lang/basic-cli/blob/main/platform/Http.roc).
## This module adds the effects and the small JSON and UTF-8 conveniences.
##
## `Http.send!` waits, so it belongs inside `Task.spawn!`:
##
##     update! = |model, input| {
##         if input.devices.key_pressed(KeyR) {
##             Task.spawn!(
##                 || match Http.get_utf8!("http://127.0.0.1:8000/data.json") {
##                     Ok(body) => Loaded(body)
##                     Err(err) => Failed(Inspect.to_str(err))
##                 },
##             )
##         }
##         Ok(model)
##     }
##
## The task parks on the host's socket while the frame loop keeps drawing, and
## the closure's return value arrives on a later `Input.messages`. Calling
## `send!` from `update!` or `render!` is a programmer error and stops the app
## with a message naming the phase; calling it from `init!` blocks the startup
## callback, which is the one place blocking is intended.
##
## ## Limits
##
## Every send carries a timeout and a hard cap on the response body. The
## defaults come from `Http.default_config`; `send_with!` takes a `Config` when
## an app wants different ones. A response larger than the cap is refused --
## the host stops reading and the send fails -- rather than allowing a remote
## server to choose how much of this process's memory to use.
##
## ## TLS
##
## `https` URLs are served by Zig's `std.crypto.tls` against the system
## certificate store. On Linux that is the usual `/etc/ssl` bundle. See
## `docs/http.md` for what each target needs.
import HttpHost
import Url
import http.Request
import http.Response
import http.Header
import http.Method

Http := [].{

	## Errors raised by the host while sending a request, before a real HTTP
	## response is available.
	##
	## `Other` carries the host's own description of the failure -- a refused
	## connection, an unresolvable name, a body over `max_response_bytes` --
	## as UTF-8 bytes.
	TransportErr : [Timeout, NetworkError, BadBody, Other(List(U8))]

	## Per-send limits.
	##
	## `timeout_ms` is the deadline for the whole exchange: connect, send,
	## response head, and body. 0 means no deadline, which is only ever
	## appropriate against a host you control.
	##
	## `max_response_bytes` caps the decompressed response body. A response
	## that would exceed it fails with `Other` rather than being truncated,
	## because a truncated body silently decodes into wrong data.
	Config : {
		timeout_ms : U64,
		max_response_bytes : U64,
	}

	## Thirty seconds, and eight megabytes of response body.
	##
	## The timeout is generous enough for a slow dashboard endpoint and short
	## enough that a task waiting on a dead server is eventually collected. The
	## body cap holds a large JSON payload but not an accidental video.
	default_config : Config
	default_config = {
		timeout_ms: 30_000,
		max_response_bytes: 8 * 1024 * 1024,
	}

	## Validate and send an HTTP request under `default_config`.
	##
	## The request URI must be an absolute HTTP or HTTPS URL accepted by `Url`.
	## Invalid URLs return `InvalidUrl` before any host effect occurs. Fragments
	## are removed because they are client-side identifiers and are not sent.
	##
	## A `TimeoutMilliseconds` set on the request itself overrides the config's
	## `timeout_ms`; `NoTimeout` on the request means the config's deadline is
	## used, so a request built the ordinary way is never left without one.
	##
	## ```roc
	## request = Request.from_method(GET).with_uri("https://www.roc-lang.org")
	## response = Http.send!(request)?
	## ```
	send! : Request => Try(Response, [InvalidUrl(Url.ParseErr), HttpErr(TransportErr), ..])
	send! = |request| send_with!(default_config, request)

	## Validate and send an HTTP request under explicit limits.
	##
	## ```roc
	## slow = { ..Http.default_config, timeout_ms: 2_000 }
	## response = Http.send_with!(slow, request)?
	## ```
	send_with! : Config, Request => Try(Response, [InvalidUrl(Url.ParseErr), HttpErr(TransportErr), ..])
	send_with! = |config, request| {
		url = Url.parse(Request.uri(request)) ? InvalidUrl
		canonical = Url.without_fragment(url)
		raw = HttpHost.send!(to_host_request(config, request, Url.to_str(canonical)))
		if raw.err == 0 {
			Ok(from_host_response(raw))
		} else {
			Err(HttpErr(to_transport_err(raw)))
		}
	}

	## Encode a value as JSON and set it as the request body.
	##
	## This uses Roc's builtin JSON encoder, so the value's type determines the
	## encoder through static dispatch. A `Content-Type: application/json`
	## header is added.
	with_json_body : Request, _ -> Try(Request, [JsonErr(_), ..])
	with_json_body = |request, value| {
		body = Json.to_str_try(value) ? JsonErr

		Ok(
			request
				.add_header("Content-Type", "application/json")
				.with_body(Str.to_utf8(body)),
		)
	}

	## Encode a value as JSON, attach it to the request body, and send it.
	send_json! : Request, _ => Try(Response, [JsonErr(_), InvalidUrl(Url.ParseErr), HttpErr(TransportErr), ..])
	send_json! = |request, value| {
		json_request = with_json_body(request, value)?

		send!(json_request)
	}

	## Perform an HTTP GET and decode the response body as a UTF-8 `Str`.
	##
	## The argument is a validated `Url`. Quoted literals work through
	## `Url.from_quote`, so a URL written out in the source is checked at
	## compile time; a string built at runtime goes through `Url.parse`.
	##
	## ```roc
	## hello_str = Http.get_utf8!("http://localhost:8000")?
	## ```
	get_utf8! : Url.Url => Try(Str, [BadBody(Str), InvalidUrl(Url.ParseErr), HttpErr(TransportErr), ..])
	get_utf8! = |url| {
		response = send!(Request.from_method(GET).with_uri(Url.to_str(url)))?
		body = Str.from_utf8(Response.body(response)) ? |_| BadBody("get_utf8!: response body was not valid UTF-8")

		Ok(body)
	}

	## Decode a response body as JSON.
	##
	## This uses Roc's builtin JSON parser, so the expected result type
	## determines the parser through static dispatch.
	decode_json_response : Response -> Try(_, [BadBody(Str), JsonErr(_), ..])
	decode_json_response = |response| {
		body = Str.from_utf8(Response.body(response)) ? |_| BadBody("decode_json_response: response body was not valid UTF-8")
		decoded = Json.parse(body) ? JsonErr

		Ok(decoded)
	}

	## Perform an HTTP GET and decode the response body as JSON.
	##
	## ```roc
	## payload : Try({ foo : Str }, _)
	## payload = Http.get!("http://localhost:8000")
	## ```
	get! : Url.Url => Try(_, [BadBody(Str), InvalidUrl(Url.ParseErr), HttpErr(TransportErr), JsonErr(_), ..])
	get! = |url| {
		response = send!(Request.from_method(GET).with_uri(Url.to_str(url)))?

		decode_json_response(response)
	}
}

## Flatten a validated request for the host boundary.
##
## The URI is passed separately because the caller has already canonicalized
## it; rebuilding the request just to carry it back would copy its body.
to_host_request : Http.Config, Request, Str -> HttpHost.RequestToHost
to_host_request = |config, request, uri| {
	method = Request.method(request)
	{
		method: to_host_method(method),
		method_ext: to_host_method_ext(method),
		headers: Request.headers(request).map(|{ name, value }| { name, value }),
		uri,
		body: Request.body(request),
		timeout_ms: to_host_timeout(Request.timeout(request), config.timeout_ms),
		max_response_bytes: config.max_response_bytes,
	}
}

## Rebuild the shared `Response` from the host's flat record.
from_host_response : HttpHost.ResponseFromHost -> Response
from_host_response = |raw|
	Response.from_status(raw.status)
		.with_headers(raw.headers.map(|{ name, value }| { name, value }))
		.with_body(raw.body)

## Rebuild the transport error the host reported.
##
## Unknown codes become `Other` rather than crashing, so a host that learns to
## distinguish a new failure still reports something an app can print.
to_transport_err : HttpHost.ResponseFromHost -> Http.TransportErr
to_transport_err = |raw|
	if raw.err == 1 {
		Timeout
	} else if raw.err == 2 {
		NetworkError
	} else if raw.err == 3 {
		BadBody
	} else {
		Other(Str.to_utf8(raw.err_message))
	}

## basic-cli's numeric method codes, so the two hosts agree on the wire.
to_host_method : Method.Method -> U8
to_host_method = |method|
	match method {
		OPTIONS => 5
		GET => 3
		POST => 7
		PUT => 8
		DELETE => 1
		HEAD => 4
		TRACE => 9
		CONNECT => 0
		PATCH => 6
		QUERY => 2
		Unknown(_) => 2
	}

## Name the method when its code cannot: `QUERY`, and anything `Unknown`.
to_host_method_ext : Method.Method -> Str
to_host_method_ext = |method|
	match method {
		QUERY => "QUERY"
		Unknown(ext) => ext
		_ => ""
	}

## The request's own deadline if it set one, otherwise the config's.
to_host_timeout : [TimeoutMilliseconds(U64), NoTimeout], U64 -> U64
to_host_timeout = |timeout, fallback|
	match timeout {
		TimeoutMilliseconds(ms) => ms
		NoTimeout => fallback
	}

expect to_host_method(GET) == 3
expect to_host_method(Unknown("FROB")) == 2
expect to_host_method_ext(Unknown("FROB")) == "FROB"
expect to_host_method_ext(GET) == ""

# A request that names no deadline of its own inherits the config's, so an
# ordinary `Request.from_method(GET)` is never sent without one.
expect to_host_timeout(NoTimeout, 30_000) == 30_000
expect to_host_timeout(TimeoutMilliseconds(250), 30_000) == 250

expect to_transport_err({ err: 1, err_message: "", status: 0, headers: [], body: [] }) == Timeout
expect to_transport_err({ err: 2, err_message: "", status: 0, headers: [], body: [] }) == NetworkError
expect to_transport_err({ err: 3, err_message: "", status: 0, headers: [], body: [] }) == BadBody

# An unrecognised code still reports the host's message rather than crashing.
expect to_transport_err({ err: 99, err_message: "boom", status: 0, headers: [], body: [] }) == Other(Str.to_utf8("boom"))
