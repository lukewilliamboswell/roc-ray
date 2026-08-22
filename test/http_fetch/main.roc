app [Model, program] {
	rr: platform "../../platform/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	roc: "nightly-2026-08-21-90da19f",
}

import rr.App
import rr.Task
import rr.Http
import http.Request
import http.Response

## Probe: GET a URL from a local server on a task and check what came back.
##
## `scripts/test_http_client.py` serves known files over localhost, runs this
## headless, and reads the exit code. The check happens in Roc, on the value
## `Http.send_with!` returned, so the test fails if the response reaches the app
## wrong -- a truncated body, a lost status, a header list that does not survive
## the boundary -- and not only if the host's own trace line is missing.
##
## Exit codes: 0 the expectation held, 3 it did not, 4 nothing arrived in time.
##
## Usage:
##     --http-url URL              what to fetch
##     --http-expect TEXT          pass when a 200 body contains TEXT
##     --http-expect-error TEXT    pass when the send fails and says TEXT
##     --http-timeout-ms N         override Http.default_config.timeout_ms
##     --http-max-bytes N          override Http.default_config.max_response_bytes
Model : {
	url : Str,
	config : Http.Config,
	expectation : Expectation,
	cycle : U64,
	outcome : Outcome,
}

## What this run is checking for.
Expectation : [Body(Str), Failure(Str)]

Outcome : [Pending, Passed, FailedWith(Str)]

Msg : [Fetched(U16, Str, U64), Failed(Str)]

## How long to wait for the task before calling the run a failure. At the
## headless pace this is far longer than a localhost round trip.
deadline_cycles : U64
deadline_cycles = 240

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init_for_args(
	|_args| App.default,
	|startup| {
		args = App.args!(startup)
		expected_error = flag_value(args, "--http-expect-error", "")
		Ok({
			url: flag_value(args, "--http-url", ""),
			config: {
				timeout_ms: flag_number(args, "--http-timeout-ms", Http.default_config.timeout_ms),
				max_response_bytes: flag_number(args, "--http-max-bytes", Http.default_config.max_response_bytes),
			},
			expectation: if expected_error == "" Body(flag_value(args, "--http-expect", "")) else Failure(expected_error),
			cycle: 0,
			outcome: Pending,
		})
	},
)

## The argument following `flag`, or `fallback` when it is absent.
flag_value : List(Str), Str, Str -> Str
flag_value = |args, flag, fallback| {
	var $found = fallback
	var $index = 0
	for arg in args {
		if arg == flag and $index + 1 < List.len(args) {
			$found = List.get(args, $index + 1) ?? fallback
		}
		$index = $index + 1
	}
	$found
}

## The same, parsed as a decimal count.
flag_number : List(Str), Str, U64 -> U64
flag_number = |args, flag, fallback| {
	bytes = Str.to_utf8(flag_value(args, flag, ""))
	if List.is_empty(bytes) or Bool.not(List.all(bytes, |byte| byte >= 48 and byte <= 57)) {
		fallback
	} else {
		List.fold(bytes, 0, |acc, byte| acc * 10 + U8.to_u64(byte - 48))
	}
}

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	if model.cycle == 0 {
		url = model.url
		config = model.config
		Task.spawn!(input, || fetch!(config, url))
	}
	outcome = List.fold(input.messages, model.outcome, |current, message| judge(current, message, model.expectation))
	next = { ..model, cycle: model.cycle + 1, outcome }
	match next.outcome {
		Passed => Err(Exit(0))
		FailedWith(_) => Err(Exit(3))
		Pending =>
			if next.cycle > deadline_cycles {
				Err(Exit(4))
			} else {
				Ok(next)
			}
		}
}

## The whole exchange, written as if it were synchronous. It is not: the host
## parks this coroutine on the socket and the frame loop keeps running.
fetch! : Http.Config, Str => Msg
fetch! = |config, url|
	match Http.send_with!(config, Request.from_method(GET).with_uri(url)) {
		Ok(response) =>
			match Str.from_utf8(Response.body(response)) {
				Ok(text) => Fetched(Response.status(response), text, List.len(Response.headers(response)))
				Err(_) => Failed("the response body was not valid UTF-8")
			}
		Err(err) => Failed(describe(err))
	}

## Decide the run's verdict from one delivered message.
judge : Outcome, Msg, Expectation -> Outcome
judge = |current, message, expectation|
	match current {
		Passed => Passed
		FailedWith(reason) => FailedWith(reason)
		Pending =>
			match (expectation, message) {
				(Failure(wanted), Failed(reason)) =>
					if Str.contains(reason, wanted) {
						Passed
					} else {
						FailedWith(Str.concat("the send failed for another reason: ", reason))
					}
				(Failure(_), Fetched(_, _, _)) => FailedWith("the send was expected to fail but it succeeded")
				(Body(_), Failed(reason)) => FailedWith(reason)
				(Body(wanted), Fetched(status, body, header_count)) =>
					if status != 200 {
						FailedWith("unexpected status")
					} else if header_count == 0 {
						FailedWith("no response headers crossed the boundary")
					} else if !Str.contains(body, wanted) {
						FailedWith("the body did not contain the expected text")
					} else {
						Passed
					}
				}
		}

## Name a send failure without depending on how the platform renders it.
describe : [InvalidUrl(_), HttpErr([Timeout, NetworkError, BadBody, Other(List(U8))])] -> Str
describe = |err|
	match err {
		InvalidUrl(_) => "the URL was rejected before any host effect ran"
		HttpErr(Timeout) => "the request timed out"
		HttpErr(NetworkError) => "the request failed at the network layer"
		HttpErr(BadBody) => "the reply was not a well-formed HTTP response"
		HttpErr(Other(bytes)) => Str.from_utf8(bytes) ?? "the host reported an unprintable failure"
	}

render! : Model, _ => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})

expect judge(Pending, Fetched(200, "hello token", 3), Body("token")) == Passed
expect judge(Pending, Fetched(404, "hello token", 3), Body("token")) == FailedWith("unexpected status")
expect judge(Pending, Fetched(200, "nothing", 3), Body("token")) == FailedWith("the body did not contain the expected text")
expect judge(Pending, Fetched(200, "hello token", 0), Body("token")) == FailedWith("no response headers crossed the boundary")

# An expected failure passes only on the failure it named.
expect judge(Pending, Failed("the request timed out"), Failure("timed out")) == Passed
expect judge(Pending, Failed("the request failed at the network layer"), Failure("timed out")) != Passed
expect judge(Pending, Fetched(200, "hello", 3), Failure("timed out")) == FailedWith("the send was expected to fail but it succeeded")

expect flag_value(["--http-url", "http://x", "--http-expect", "y"], "--http-expect", "z") == "y"
expect flag_value(["--http-url"], "--http-url", "z") == "z"
expect flag_number(["--http-max-bytes", "64"], "--http-max-bytes", 9) == 64
expect flag_number(["--http-max-bytes", "not a number"], "--http-max-bytes", 9) == 9
