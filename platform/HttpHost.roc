## Internal transport for the HTTP client.
##
## This module is intentionally not exposed by the platform package.
##
## `send!` waits, so it is a task effect: inside `Task.spawn!` it parks the
## coroutine while the host's `std.http.Client` runs on the zio runtime and the
## frame loop keeps drawing; inside `init!` it blocks. Calling it from
## `update!` or `render!` is a programmer error and stops the app.
##
## The wire shape mirrors basic-cli's `RequestToAndFromHost` /
## `ResponseToAndFromHost` so an app that knows one knows the other, with two
## deliberate differences.
##
## Headers are a `List(HeaderPair)` of records rather than the `List((Str, Str))`
## basic-cli's Rust glue produces; the two are the same bytes, and the record
## names its fields at the Zig boundary.
##
## No tag union crosses the boundary. basic-cli's host returns
## `Try(Response, TransportErr)` and `TransportErr` carries a payload; the rest
## of this platform keeps unions off the ABI (see `InputFromHostCycle` in
## `main.roc`), so failures arrive as an `err` code plus a message string and
## `Http` rebuilds the tag union on the Roc side.
HttpHost := [].{

	## One HTTP header, in the order the peer sent or expects it.
	HeaderPair : {
		name : Str,
		value : Str,
	}

	## A request, already validated by `Http` and flattened for the host.
	##
	## `method` is basic-cli's numeric method code and `method_ext` names the
	## method when the code cannot (`QUERY`, and anything `Unknown`). `Http`
	## refuses both before this effect runs, so `method_ext` is empty on every
	## request that gets here; the field stays because it is part of the shape
	## basic-cli's host reads, and the host keeps its own refusal for it.
	##
	## `timeout_ms` of 0 means no deadline, matching basic-cli's
	## `to_host_timeout`. `max_response_bytes` is a hard cap on the decompressed
	## body; the host stops reading and answers `ERR_BODY_TOO_LARGE` rather than
	## letting a remote server decide how much of this process's memory to use.
	RequestToHost : {
		method : U8,
		method_ext : Str,
		headers : List(HeaderPair),
		uri : Str,
		body : List(U8),
		timeout_ms : U64,
		max_response_bytes : U64,
	}

	## A response, or the transport failure that replaced it.
	##
	## `err` is 0 on success and one of the `ERR_*` codes below otherwise. On a
	## failure `status`, `headers` and `body` are empty and `err_message` carries
	## the host's description; on success `err_message` is empty.
	ResponseFromHost : {
		err : U8,
		err_message : Str,
		status : U16,
		headers : List(HeaderPair),
		body : List(U8),
	}

	## Send one request and wait for the whole response.
	send! : RequestToHost => ResponseFromHost
}
