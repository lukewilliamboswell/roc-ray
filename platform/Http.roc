## Send HTTP requests and decode common response bodies.
##
## Requests are built and read with the shared
## [`roc-lang/http`](https://github.com/roc-lang/http) `Request` and `Response`
## types. This module adds the hosted effects plus JSON and UTF-8 conveniences.
##
## An app that names `Request` or `Response` declares the `http` package in its
## own header, beside the platform:
##
## ```roc
## app [Model, program] {
##     rr: platform "../../platform/main.roc",
##     http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
## }
##
## import rr.Http
## import http.Request
## ```
##
## `Http.get!` and `Http.get_utf8!` take a URL and hand back decoded data, so
## an app that uses only those needs no package dependency of its own.
##
## `Http.send!` waits, so it belongs inside `Task.spawn!`:
##
## ```roc
## update! = |model, input| {
##     if input.devices.key_pressed(KeyR) {
##         Task.spawn!(
##             input,
##             || match Http.get_utf8!("http://127.0.0.1:8000/data.json") {
##                 Ok(body) => Loaded(body)
##                 Err(InvalidUrl(_)) => Failed("that is not a URL this platform will fetch")
##                 Err(HttpErr(Timeout)) => Failed("the request timed out")
##                 Err(HttpErr(_)) => Failed("the request failed at the network layer")
##                 Err(BadBody(_)) => Failed("the reply was not valid UTF-8")
##                 Err(_) => Failed("the request failed")
##             },
##         )
##     }
##     Ok(model)
## }
## ```
##
## `send!` is legal in `init!`, where it blocks startup, and in tasks, where it
## parks the task; it is refused in `update!` and `render!`.
##
## Up to three redirects are followed, and the `Response` is the one at the end
## of that chain.
##
## Every send carries a deadline and a hard cap on the response body, taken
## from `Http.default_config`: thirty seconds, and eight megabytes. Pass a
## `Config` to `send_with!` for different ones, and `0` in either field to
## disable that limit. A request that sets `TimeoutMilliseconds` itself
## overrides the config's deadline; `NoTimeout` on a request means the config's
## deadline applies, so an ordinarily built request is never sent without one.
##
## The body cap is measured after decompression. A response over the cap fails
## rather than being truncated.
##
## An HTTP status is not an error. A 404 or a 503 arrives as `Ok(response)`
## carrying that status; only a failure to complete the exchange is `HttpErr`.
##
## `get!` and `send_json!` infer the JSON type from their call site. Add a type
## annotation when the expected decoded or encoded type is ambiguous.
##
## HTTPS verifies peers with the operating system's certificate store. Custom
## certificate authorities and disabling verification are not supported.
import HostABI
import Url
import http.Request
import http.Response
import http.Header
import http.Method

Http := [].{

	## Why the exchange did not produce an HTTP response.
	##
	## An HTTP status is never one of these: a 404 or a 503 is an `Ok`
	## response.
	##
	## `Timeout` is the deadline expiring before the exchange finished.
	## `NetworkError` is a connection that could not be made or did not survive
	## the exchange -- a refused port, a dropped socket, an unreachable host.
	## `MalformedResponse` is a reply that arrived but was not a well-formed
	## HTTP response. `Other` carries the host's own description as UTF-8 bytes: a
	## name that would not resolve, a body over `max_response_bytes`, a
	## certificate store that could not be loaded, or a method this platform
	## cannot send.
	TransportErr : [Timeout, NetworkError, MalformedResponse, Other(List(U8))]

	## Per-send limits.
	##
	## `timeout_ms` is the deadline for the whole exchange: connect, send,
	## response head, and body. `0` means no deadline, which is only ever
	## appropriate against a server you control. A request that sets
	## `TimeoutMilliseconds` itself overrides this value.
	##
	## `max_response_bytes` caps the decompressed response body, and `0` means
	## no cap. A response that would exceed it fails with `Other` rather than
	## being truncated, because a truncated body silently decodes into wrong
	## data.
	##
	## A plain record; build one with
	## `{ ..Http.default_config, timeout_ms: 5_000 }` rather than a chain of
	## `with_*` calls.
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
	## An invalid URL answers `InvalidUrl` before any host effect occurs.
	## Fragments are removed, because they are client-side identifiers and are
	## not sent.
	##
	## The method must be one of the nine RFC methods. `QUERY` and any
	## `Unknown(ext)` method fail as `HttpErr(Other(...))` naming the method,
	## also before any host effect occurs: the host's method type has no
	## representation for either, and reporting it as `Other` keeps an app's
	## exhaustive match over `TransportErr` from breaking over a request no
	## host could send.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	##
	## ```roc
	## request = Request.from_method(GET).with_uri("https://www.roc-lang.org")
	## response = Http.send!(request)?
	## ```
	send! : Request => Try(Response, [InvalidUrl(Url.ParseErr), HttpErr(TransportErr), ..])
	send! = |request| send_with!(default_config, request)

	## Validate and send an HTTP request under explicit limits.
	##
	## The same validation, the same phases, and the same outcomes as `send!`;
	## only the deadline and the body cap differ.
	##
	## ```roc
	## slow = { ..Http.default_config, timeout_ms: 2_000 }
	## response = Http.send_with!(slow, request)?
	## ```
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the
	## task; refused in `update!` and `render!`.
	send_with! : Config, Request => Try(Response, [InvalidUrl(Url.ParseErr), HttpErr(TransportErr), ..])
	send_with! = |config, request| {
		check_method(Request.method(request)) ? HttpErr
		url = Url.parse(Request.uri(request)) ? InvalidUrl
		canonical = Url.without_fragment(url)
		raw = HostABI.http_send!(to_host_request(config, request, Url.to_str(canonical)))
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
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the
	## task; refused in `update!` and `render!`.
	send_json! : Request, _ => Try(Response, [JsonErr(_), InvalidUrl(Url.ParseErr), HttpErr(TransportErr), ..])
	send_json! = |request, value| {
		json_request = with_json_body(request, value)?

		send!(json_request)
	}

	## Perform an HTTP GET and decode the response body as a UTF-8 `Str`.
	##
	## The argument is a validated `Url`. Quoted literals work through
	## `Url.from_quote`, so a URL written out in the source is checked at compile
	## time; a string built at runtime goes through `Url.parse`.
	##
	## A body that is not valid UTF-8 answers `BadBody(Str)`. That is this
	## function's own decoding failure, and is not the transport's
	## `MalformedResponse`: the reply arrived and was a well-formed HTTP
	## response, it just is not text. The status is not inspected, so an error
	## page comes back as the `Str` the server sent.
	##
	## ```roc
	## hello_str = Http.get_utf8!("http://localhost:8000")?
	## ```
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the
	## task; refused in `update!` and `render!`.
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
	## The expected result type selects the parser through static dispatch. The
	## status is not inspected, so a JSON error page decodes if it happens to fit
	## the expected shape. Same phases as `send!`.
	##
	## ```roc
	## payload : Try({ foo : Str }, _)
	## payload = Http.get!("http://localhost:8000")
	## ```
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the
	## task; refused in `update!` and `render!`.
	get! : Url.Url => Try(_, [BadBody(Str), InvalidUrl(Url.ParseErr), HttpErr(TransportErr), JsonErr(_), ..])
	get! = |url| {
		response = send!(Request.from_method(GET).with_uri(Url.to_str(url)))?

		decode_json_response(response)
	}
}

## Refuse a method this platform cannot put on the wire.
##
## `std.http.Method` in the host is a closed enum of the nine RFC methods, so
## `QUERY` and any `Unknown(ext)` method have no representation there. The host
## refuses them too, but only after the request has crossed the boundary and
## been charged against its timeout. Deciding it here means nothing is built,
## nothing is sent, and the failure is the same on every run.
##
## The refusal is an `Other` rather than a variant of its own. Both
## `TransportErr` and `send!`'s error union are matched exhaustively by the apps
## that read them, so a new variant would break every one of them -- for a
## failure that only a request no host could send can reach. The message names
## the method, which is what an app has to print either way.
##
## The host keeps its own refusal for the same codes. It is a separate trust
## boundary, and its check is what makes `methodFromCode` total.
check_method : Method.Method -> Try({}, Http.TransportErr)
check_method = |method|
	match method {
		QUERY => Err(Other(Str.to_utf8(unsupported_method_message("QUERY"))))
		Unknown(ext) => Err(Other(Str.to_utf8(unsupported_method_message(ext))))
		_ => Ok({})
	}

## Say which method was refused. Written once, so the `expect`s below pin the
## wording an app will print.
unsupported_method_message : Str -> Str
unsupported_method_message = |name|
	"${name} is not a method this platform can send"

expect check_method(GET) == Ok({})
expect check_method(POST) == Ok({})
expect check_method(QUERY) == Err(Other(Str.to_utf8("QUERY is not a method this platform can send")))
expect check_method(Unknown("FROB")) == Err(Other(Str.to_utf8("FROB is not a method this platform can send")))

## Flatten a validated request for the host boundary.
##
## The URI is passed separately because the caller has already canonicalized
## it; rebuilding the request just to carry it back would copy its body.
to_host_request : Http.Config, Request, Str -> HostABI.HttpRequestToHost
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
from_host_response : HostABI.HttpResponseFromHost -> Response
from_host_response = |raw|
	Response.from_status(raw.status)
		.with_headers(raw.headers.map(|{ name, value }| { name, value }))
		.with_body(raw.body)

## Rebuild the transport error the host reported.
##
## Unknown codes become `Other` rather than crashing, so a host that learns to
## distinguish a new failure still reports something an app can print.
to_transport_err : HostABI.HttpResponseFromHost -> Http.TransportErr
to_transport_err = |raw|
	if raw.err == 1 {
		Timeout
	} else if raw.err == 2 {
		NetworkError
	} else if raw.err == 3 {
		MalformedResponse
	} else {
		Other(Str.to_utf8(raw.err_message))
	}

## basic-cli's numeric method codes, so the two hosts agree on the wire.
##
## `send_with!` refuses `QUERY` and `Unknown(_)` before this runs, so their
## branches are unreachable from the public API. They stay because the match
## has to be total, and `2` is the code the host refuses.
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
##
## Always `""` for a request `send_with!` accepted. The field stays on the wire
## because it is part of the shape basic-cli's host reads, and because it is
## what the host would need if it ever learned to send an extension method.
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
expect to_transport_err({ err: 3, err_message: "", status: 0, headers: [], body: [] }) == MalformedResponse

# An unrecognised code still reports the host's message rather than crashing.
expect to_transport_err({ err: 99, err_message: "boom", status: 0, headers: [], body: [] }) == Other(Str.to_utf8("boom"))
