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
## `Http.Client.get!` and `Http.Client.get_utf8!` take a URL and return decoded data, so
## an app that uses only those needs no package dependency of its own.
##
## `Http.Client.send!` waits, so it belongs inside `Task.spawn!`:
##
## ```roc
## update! = |model, input, io| {
##     if input.devices.key_pressed(KeyR) {
##         http = io.http()
##         Task.spawn!(
##             input,
##             || match http.get_utf8!("http://127.0.0.1:8000/data.json") {
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
## Every send defaults to a thirty-second deadline and an eight-MiB response
## limit. Use `send_with!`, `send_json_with!`, `get_utf8_with!`, or `get_with!`
## to override either field in `Config`.
##
## The body limit is measured after decompression. A response over the limit
## fails with `HttpErr(ResponseTooLarge)`. A requested limit above 64 MiB is
## refused with `HttpErr(ResponseLimitUnsupported)` before any network work.
##
## An HTTP status is not an error. A 404 or a 503 arrives as `Ok(response)`
## with that status. Only a request that gets no complete response is `HttpErr`.
##
## `get!` and `send_json!` infer the JSON type from their call site. Add a type
## annotation when the expected decoded or encoded type is ambiguous.
##
## HTTPS verifies peers with the operating system's certificate store. Custom
## certificate authorities and disabling verification are not supported.
import Host
import Resource
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
	## HTTP response. `ResponseTooLarge` means the decoded response exceeded
	## the request's byte limit. `ResponseLimitUnsupported` means the requested
	## limit exceeds the supported 64 MiB per-response maximum. `Busy` means the
	## host could not reserve room in its shared response budget. It made no
	## network request, and the application may try again after one finishes.
	## `Unavailable` means the HTTP runtime has stopped.
	## `Other` carries a UTF-8 description of remaining failures.
	TransportErr : [Busy, Timeout, NetworkError, MalformedResponse, ResponseLimitUnsupported, ResponseTooLarge, Unavailable, Other(List(U8))]

	## Per-send props with defaults of 30 seconds and 8 MiB.
	##
	## `timeout_ms` covers connection, request, and the complete response. A
	## request's own `TimeoutMilliseconds` overrides it. Zero disables the
	## deadline in either place.
	##
	## `max_response_bytes` caps the decompressed response body. A zero limit
	## accepts only an empty body.
	Config := {
		timeout_ms : U64 ?? 30_000,
		max_response_bytes : U64 ?? 8 * 1024 * 1024,
	}

	default_config : Config
	default_config = {}

	## Encode a value as JSON and set it as the request body.
	##
	## This uses Roc's builtin JSON encoder, so the value's type determines the
	## encoder through static dispatch. A `Content-Type: application/json`
	## header is added.
	with_json_body : Request, _ -> Try(Request, [JsonErr(_)])
	with_json_body = |request, value| {
		body = Json.to_str_try(value) ? JsonErr

		Ok(
			request
				.add_header("Content-Type", "application/json")
				.with_body(Str.to_utf8(body)),
		)
	}

	## Decode a response body as JSON.
	##
	## This uses Roc's builtin JSON parser, so the expected result type
	## determines the parser through static dispatch.
	decode_json_response : Response -> Try(_, [BadBody(Str), JsonErr(_)])
	decode_json_response = |response| {
		body = Str.from_utf8(Response.body(response)) ? |_| BadBody("decode_json_response: response body was not valid UTF-8")
		decoded = Json.parse(body) ? JsonErr

		Ok(decoded)
	}

	## Opaque HTTP authority supplied by App.Io, scoped by the app's declared
	## `HttpOrigin` entries.
	Client :: Resource.Authority.{

		## Private platform construction; no application can manufacture the argument.
		for_host : Resource.Authority -> Client
		for_host = |authority| Client.(authority)

		## Validate and send an HTTP request under `default_config`.
		##
		## The request URI must be an absolute HTTP or HTTPS URL accepted by `Url`.
		## An invalid URL returns `InvalidUrl` before any host effect occurs.
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
		## response = io.http().send!(request)?
		## ```
		send! : Client, Request => Try(Response, [PermissionDenied, InvalidUrl(Url.ParseErr), HttpErr(TransportErr)])
		send! = |Client.(authority), request| perform_send!(authority, request)

		## Validate and send an HTTP request under explicit limits.
		##
		## The same validation, the same phases, and the same outcomes as `send!`;
		## only the deadline and the body cap differ.
		##
		## ```roc
		## response = io.http().send_with!({ timeout_ms: 2_000 }, request)?
		## ```
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks the
		## task; refused in `update!` and `render!`.
		send_with! : Client, Config, Request => Try(Response, [PermissionDenied, InvalidUrl(Url.ParseErr), HttpErr(TransportErr)])
		send_with! = |Client.(authority), config, request| perform_send_with!(authority, config, request)

		## Encode a value as JSON, attach it to the request body, and send it.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks the
		## task; refused in `update!` and `render!`.
		send_json! : Client, Request, _ => Try(Response, [PermissionDenied, JsonErr(_), InvalidUrl(Url.ParseErr), HttpErr(TransportErr)])
		send_json! = |Client.(authority), request, value| perform_send_json!(authority, Http.default_config, request, value)

		## As `send_json!` with explicit limits.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		send_json_with! : Client, Config, { request : Request, value : _ } => Try(Response, [PermissionDenied, JsonErr(_), InvalidUrl(Url.ParseErr), HttpErr(TransportErr)])
		send_json_with! = |Client.(authority), config, { request, value }|
			perform_send_json!(authority, config, request, value)

		## Perform an HTTP GET and decode the response body as a UTF-8 `Str`.
		##
		## The argument is a validated `Url`. Quoted literals work through
		## `Url.from_quote`, so a URL written out in the source is checked at compile
		## time; a string built at runtime goes through `Url.parse`.
		##
		## A body that is not valid UTF-8 returns `BadBody(Str)`. That is this
		## function's own decoding failure, and is not the transport's
		## `MalformedResponse`: the reply arrived and was a well-formed HTTP
		## response, it just is not text. The status is not inspected, so an error
		## page comes back as the `Str` the server sent.
		##
		## ```roc
		## hello_str = io.http().get_utf8!("http://localhost:8000")?
		## ```
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks the
		## task; refused in `update!` and `render!`.
		get_utf8! : Client, Url.Url => Try(Str, [PermissionDenied, BadBody(Str), InvalidUrl(Url.ParseErr), HttpErr(TransportErr)])
		get_utf8! = |Client.(authority), url| perform_get_utf8!(authority, Http.default_config, url)

		## As `get_utf8!` with explicit limits.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		get_utf8_with! : Client, Config, Url.Url => Try(Str, [PermissionDenied, BadBody(Str), InvalidUrl(Url.ParseErr), HttpErr(TransportErr)])
		get_utf8_with! = |Client.(authority), config, url| perform_get_utf8!(authority, config, url)

		## Perform an HTTP GET and decode the response body as JSON.
		##
		## The expected result type selects the parser through static dispatch. The
		## status is not inspected, so a JSON error page decodes if it happens to fit
		## the expected shape. Same phases as `send!`.
		##
		## ```roc
		## payload : Try({ foo : Str }, _)
		## payload = io.http().get!("http://localhost:8000")
		## ```
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks the
		## task; refused in `update!` and `render!`.
		get! : Client, Url.Url => Try(_, [PermissionDenied, BadBody(Str), InvalidUrl(Url.ParseErr), HttpErr(TransportErr), JsonErr(_)])
		get! = |Client.(authority), url| perform_get!(authority, Http.default_config, url)

		## As `get!` with explicit limits.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		get_with! : Client, Config, Url.Url => Try(_, [PermissionDenied, BadBody(Str), InvalidUrl(Url.ParseErr), HttpErr(TransportErr), JsonErr(_)])
		get_with! = |Client.(authority), config, url| perform_get!(authority, config, url)

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
to_host_request : Http.Config, Request, Str -> Host.HttpRequestToHost
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
from_host_response : Host.HttpResponseFromHost -> Response
from_host_response = |raw|
	Response.from_status(raw.status)
		.with_headers(raw.headers.map(|{ name, value }| { name, value }))
		.with_body(raw.body)

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

## Private authority-taking implementations.
perform_send! : Resource.Authority, Request => Try(Response, [PermissionDenied, InvalidUrl(Url.ParseErr), HttpErr(Http.TransportErr)])
perform_send! = |authority, request| perform_send_with!(authority, Http.default_config, request)

perform_send_with! : Resource.Authority, Http.Config, Request => Try(Response, [PermissionDenied, InvalidUrl(Url.ParseErr), HttpErr(Http.TransportErr)])
perform_send_with! = |authority, config, request| {
	check_method(Request.method(request)) ? HttpErr
	url = Url.parse(Request.uri(request)) ? InvalidUrl
	canonical = Url.without_fragment(url)
	# closed error union to open error union
	match Host.http_send!(authority, to_host_request(config, request, Url.to_str(canonical))) {
		Ok(raw) => Ok(from_host_response(raw))
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(Busy) => Err(HttpErr(Busy))
		Err(MalformedResponse) => Err(HttpErr(MalformedResponse))
		Err(NetworkError) => Err(HttpErr(NetworkError))
		Err(Other(message)) => Err(HttpErr(Other(Str.to_utf8(message))))
		Err(ResponseLimitUnsupported) => Err(HttpErr(ResponseLimitUnsupported))
		Err(ResponseTooLarge) => Err(HttpErr(ResponseTooLarge))
		Err(Timeout) => Err(HttpErr(Timeout))
		Err(Unavailable) => Err(HttpErr(Unavailable))
	}
}

perform_send_json! : Resource.Authority, Http.Config, Request, _ => Try(Response, [PermissionDenied, JsonErr(_), InvalidUrl(Url.ParseErr), HttpErr(Http.TransportErr)])
perform_send_json! = |authority, config, request, value| {
	json_request = Http.with_json_body(request, value)?

	perform_send_with!(authority, config, json_request)
}

perform_get_utf8! : Resource.Authority, Http.Config, Url.Url => Try(Str, [PermissionDenied, BadBody(Str), InvalidUrl(Url.ParseErr), HttpErr(Http.TransportErr)])
perform_get_utf8! = |authority, config, url| {
	response = perform_send_with!(authority, config, Request.from_method(GET).with_uri(Url.to_str(url)))?
	body = Str.from_utf8(Response.body(response)) ? |_| BadBody("perform_get_utf8!: response body was not valid UTF-8")

	Ok(body)
}

perform_get! : Resource.Authority, Http.Config, Url.Url => Try(_, [PermissionDenied, BadBody(Str), InvalidUrl(Url.ParseErr), HttpErr(Http.TransportErr), JsonErr(_)])
perform_get! = |authority, config, url| {
	response = perform_send_with!(authority, config, Request.from_method(GET).with_uri(Url.to_str(url)))?

	Http.decode_json_response(response)
}
