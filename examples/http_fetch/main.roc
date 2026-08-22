app [Model, program] {
	rr: platform "../../platform/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	roc: "nightly-2026-08-21-90da19f",
}

import rr.App
import rr.Task
import rr.Http
import rr.Color
import rr.Draw
import rr.Text
import http.Request
import http.Response

## Fetching over HTTP without dropping a frame.
##
## The whole request is one ordinary-looking line inside `Task.spawn!`:
##
##     Task.spawn!(input, || fetch!(id, url))
##
## `Http.send!` inside that closure looks synchronous and is: it returns the
## response, or an error, and nothing else happens in that task until it does.
## What it does *not* do is stall the frame. The host runs the closure on its
## own coroutine and parks it on the socket, so the ring keeps spinning and the
## elapsed counter keeps climbing for however long the server takes. That is
## the difference this platform's task model buys: a 200 ms round trip costs
## twelve frames if you call it from `update!`, and nothing if you call it from
## a task.
##
## Press R to fetch again, ESC to quit. The URL comes from `--url`, then from
## `ROC_RAY_HTTP_URL`, then from the default below.
Model : {
	url : Str,
	state : State,

	## Which fetch the panel is showing.
	##
	## R can start a second fetch while the first is still in flight, and
	## independent tasks finish in whatever order they finish in -- the newer
	## one may well answer first. So each reply carries the id of the fetch it
	## belongs to, and a straggler from an abandoned one is dropped rather than
	## overwriting a fresher answer. An app whose work cannot overlap needs none
	## of this: the `Msg` variant is identity enough.
	fetch : U64,
	elapsed : F32,
	started_waiting : F32,
	title : Text.Prepared,
	hint : Text.Prepared,
}

## Where the current request has got to.
State : [
	Waiting,
	Loaded({ status : U16, lines : List(Str), bytes : U64, waited_ms : U64 }),
	Failed(Str),
]

Msg : [Arrived(U64, U16, Str), Broke(U64, Str)]

default_url : Str
default_url = "https://www.roc-lang.org/"

## Lines of the body to show. More than this and the panel stops being a
## preview and starts being a bad text viewer.
preview_lines : U64
preview_lines = 12

## Bytes of each preview line to show, so a minified payload does not draw one
## row off the right edge of the window.
preview_columns : U64
preview_columns = 96

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init_for_args(
	|_args| App.default.with_title("RocRay HTTP Fetch").with_size({ width: 900, height: 640 }).with_frame_pacing(Capped(60)),
	|startup| {
		font = Draw.default_font!()
		url = chosen_url(App.args!(startup), App.read_env!(startup, "ROC_RAY_HTTP_URL"))
		Ok({
			url,
			state: Waiting,
			fetch: 0,
			elapsed: 0,
			started_waiting: 0,
			title: Text.from("Fetching while the frame keeps moving", font).size(24).prepare!()?,
			hint: Text.from("R fetch again      ESC quit", font).size(15).spacing(2.0).prepare!()?,
		})
	},
)

## `--url X` wins, then the environment, then the built-in default.
chosen_url : List(Str), Try(Str, [NotFound, ..]) -> Str
chosen_url = |args, from_env| {
	var $found = ""
	var $index = 0
	for arg in args {
		if arg == "--url" and $index + 1 < List.len(args) {
			$found = List.get(args, $index + 1) ?? ""
		}
		$index = $index + 1
	}
	if $found != "" {
		$found
	} else {
		match from_env {
			Ok(value) if value != "" => value
			_ => default_url
		}
	}
}

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	elapsed = model.elapsed + input.time.elapsed_seconds

	# Cycle 0 starts the first fetch; R starts another one. Both are the same
	# call, and both return immediately -- the task runs after `update!` does.
	refetch = input.time.cycle_count == 0 or input.devices.key_pressed(KeyR)
	fetch = if refetch model.fetch + 1 else model.fetch

	# Folded against the id being waited for, so whatever an abandoned fetch
	# delivers on this cycle goes the same way the fetch itself did.
	state = List.fold(input.messages, model.state, |current, message| apply(current, message, fetch, elapsed - model.started_waiting))

	if refetch {
		url = model.url
		id = fetch
		Task.spawn!(input, || fetch!(id, url))
	}

	if input.devices.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		Ok({
			..model,
			fetch,
			elapsed,
			state: if refetch Waiting else state,
			started_waiting: if refetch elapsed else model.started_waiting,
		})
	}
}

## One request, written top to bottom. The host parks this coroutine on the
## socket; `update!` has already returned by the time the reply arrives.
##
## `Http.send!` rather than `Http.get_utf8!` because this URL is a runtime
## string: `get_utf8!` takes an already-validated `Url`, which is what a quoted
## literal in the source becomes. `send!` does the parsing itself and reports
## `InvalidUrl` when the string is not one.
fetch! : U64, Str => Msg
fetch! = |id, url|
	match Http.send!(Request.from_method(GET).with_uri(url)) {
		Ok(response) =>
			match Str.from_utf8(Response.body(response)) {
				Ok(body) => Arrived(id, Response.status(response), body)
				Err(_) => Broke(id, "the response body was not valid UTF-8")
			}
		Err(InvalidUrl(_)) => Broke(id, "that is not a URL this platform will fetch")
		Err(HttpErr(Timeout)) => Broke(id, "the request timed out")
		Err(HttpErr(NetworkError)) => Broke(id, "the request failed at the network layer")
		Err(HttpErr(BadBody)) => Broke(id, "the reply was not a well-formed HTTP response")
		Err(HttpErr(Other(bytes))) => Broke(id, Str.from_utf8(bytes) ?? "the request failed")
	}

## Fold one delivered message into the panel's state, if it belongs to the fetch
## being waited for. A reply from an abandoned one leaves the state alone.
apply : State, Msg, U64, F32 -> State
apply = |state, message, current, waited|
	match message {
		Arrived(id, status, body) if id == current =>
			Loaded({
				status,
				lines: List.map(List.take_first(Str.split_on(body, "\n"), preview_lines), clip),
				bytes: List.len(Str.to_utf8(body)),
				waited_ms: F32.floor_to_u64_try(waited * 1000) ?? 0,
			})
		Broke(id, reason) if id == current => Failed(reason)
		_ => state
	}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x121420))
	model.title.draw!(frame, { pos: { x: 40, y: 36 }, color: Color.white, align: Text.align_top_left })
	model.hint.draw!(frame, { pos: { x: 40, y: 74 }, color: Color.from_hex_rgb(0x616e88), align: Text.align_top_left })
	frame.text_at!({ pos: { x: 40, y: 108 }, text: model.url, size: 16, color: Color.from_hex_rgb(0x88c0d0) })
	frame.text_at!({ pos: { x: 40, y: 134 }, text: headline(model.state), size: 18, color: headline_color(model.state) })

	# The ring keeps turning for as long as the request is in flight. It is
	# driven by wall-clock elapsed time, so a stalled frame would be obvious.
	angle = model.elapsed * 2.4
	frame.circle!({
		center: { x: 800 + 44 * F32.cos(angle), y: 96 + 44 * F32.sin(angle) },
		radius: 11,
		style: Draw.filled(Color.from_hex_rgb(0x5e81ac)),
	})
	frame.circle!({ center: { x: 800, y: 96 }, radius: 44, style: Draw.outlined(Color.from_hex_rgb(0x2e3440), 1) })

	match model.state {
		Loaded({ lines, status: _, bytes: _, waited_ms: _ }) => draw_lines!(frame, lines)
		Waiting => {}
		Failed(_) => {}
	}
	Ok({})
}

## Draw the body preview, one line per row.
draw_lines! : Draw.Frame, List(Str) => {}
draw_lines! = |frame, lines| {
	var $row = 0
	for line in lines {
		frame.text_at!({
			pos: { x: 40, y: 184 + 22 * U64.to_f32($row) },
			text: line,
			size: 15,
			color: Color.from_hex_rgb(0xd8dee9),
		})
		$row = $row + 1
	}
}

## One line describing where the request has got to.
headline : State -> Str
headline = |state|
	match state {
		Waiting => "fetching..."
		Failed(reason) => Str.concat("failed: ", reason)
		Loaded({ status, bytes, waited_ms, lines: _ }) =>
			Str.join_with(
				[U16.to_str(status), U64.to_str(bytes), "bytes in", U64.to_str(waited_ms), "ms"],
				" ",
			)
		}

## Green when a response arrived, red when it did not, amber while waiting.
headline_color : State -> Color.Rgba
headline_color = |state|
	match state {
		Waiting => Color.from_hex_rgb(0xebcb8b)
		Loaded(_) => Color.from_hex_rgb(0xa3be8c)
		Failed(_) => Color.from_hex_rgb(0xbf616a)
	}

expect chosen_url(["--url", "http://example.test/"], Err(NotFound)) == "http://example.test/"
expect chosen_url([], Ok("http://from-env.test/")) == "http://from-env.test/"
expect chosen_url([], Err(NotFound)) == default_url

# An argument wins over the environment, and an empty environment value does not.
expect chosen_url(["--url", "http://arg.test/"], Ok("http://env.test/")) == "http://arg.test/"
expect chosen_url([], Ok("")) == default_url

## Keep a preview line inside the panel. Falling back to the whole line when
## the cut lands mid-codepoint is a wider row, never mojibake.
clip : Str -> Str
clip = |line|
	if List.len(Str.to_utf8(line)) <= preview_columns {
		line
	} else {
		Str.from_utf8(List.take_first(Str.to_utf8(line), preview_columns)) ?? line
	}

expect match apply(Waiting, Arrived(1, 200, "one\ntwo\nthree"), 1, 0.5) {
	Loaded({ status, lines, bytes, waited_ms }) =>
		status == 200 and lines == ["one", "two", "three"] and bytes == 13 and waited_ms == 500
	_ => Bool.False
}

## A reply from a fetch that R has already superseded is dropped, whether it
## arrives before or after the one being waited for.
expect apply(Waiting, Arrived(1, 200, "stale"), 2, 0.5) == Waiting
expect apply(Failed("first"), Broke(1, "second"), 2, 0.5) == Failed("first")

expect clip("short") == "short"
expect List.len(Str.to_utf8(clip(Str.repeat("x", 200)))) == preview_columns
