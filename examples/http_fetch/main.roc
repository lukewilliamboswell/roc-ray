## Fetch a web page while the window remains responsive.
##
## Press R to fetch again and Escape to quit. Pass `--url URL`, or set
## `ROC_RAY_HTTP_URL`, to replace the default address. This example shows a
## `Task`: work that may wait, such as an HTTP request. A finished Task returns
## one `Message`, which a later `Input` delivers to `update!`.
app [Model, program] {
	rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	roc: "nightly-2026-08-23-fb208ba",
}

import rr.App
import rr.Task
import rr.Http
import rr.Math
import rr.Color
import rr.Draw
import rr.Text
import http.Request
import http.Response

## State kept between updates: the selected URL, the latest request result and
## timing, and prepared labels. The request number identifies the result that
## belongs to the most recent fetch when several Tasks finish in a different
## order from the one in which they started.
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
	subtitle : Text.Prepared,
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
preview_lines = 12.U64

## Bytes of each preview line to show, so a minified payload does not draw one
## row off the right edge of the window.
preview_columns = 96.U64

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
			title: Text.from("Fetching while the frame keeps moving", font).size(26).prepare!()?,
			subtitle: Text.from("Http.send! parks a coroutine on the socket; the frame loop never waits for it", font).size(15).prepare!()?,
			hint: Text.from("R  fetch again        ESC  quit", font).size(14).spacing(2.0).prepare!()?,
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

## One request, written top to bottom. Waiting here pauses this Task while the
## app continues updating and drawing.
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
		Err(HttpErr(MalformedResponse)) => Broke(id, "the reply was not a well-formed HTTP response")
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

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
render! = |model, frame| {
	size = frame.size!()
	frame.rectangle_gradient_v!({ x: 0, y: 0, width: size.width, height: size.height, color_top: bg_top, color_bottom: bg_bottom })
	frame.circle_gradient!({ center: { x: size.width * 0.5, y: -40 }, radius: size.height, color_inner: Color.from_hex_rgba(0x3a5f9c33), color_outer: Color.from_hex_rgba(0x00000000) })

	model.title.draw!(frame, { pos: { x: 44, y: 36 }, color: ink })
	model.subtitle.draw!(frame, { pos: { x: 44, y: 72 }, color: muted })

	width = size.width - 88
	accent = state_color(model.state)

	# The request card: what was asked for, and where the answer has got to.
	frame.rounded_rectangle!({ x: 44, y: 112, width: width, height: 88, radius: 0.14, segments: 8, style: Draw.filled_and_outlined(card, card_edge, 1) })
	frame.rounded_rectangle!({ x: 44, y: 124, width: 4, height: 64, radius: 1, segments: 4, style: Draw.filled(accent) })
	frame.rounded_rectangle!({ x: 68, y: 130, width: 46, height: 22, radius: 0.5, segments: 8, style: Draw.filled(Color.with_alpha(accent_url, 45)) })
	frame.text_at!({ pos: { x: 80, y: 133 }, text: "GET", size: 14, color: accent_url })
	frame.text_at!({ pos: { x: 128, y: 132 }, text: model.url, size: 16, color: ink })
	frame.text_at!({ pos: { x: 68, y: 164 }, text: headline(model.state), size: 15, color: accent })
	draw_indicator!(frame, { x: 44 + width - 44, y: 156 }, model.state, model.elapsed)

	# The body preview, in a panel of its own so a long line is clipped by the
	# panel rather than running off the window.
	panel_top = 224
	panel_height = size.height - panel_top - 64
	frame.rounded_rectangle!({ x: 44, y: panel_top, width: width, height: panel_height, radius: 0.05, segments: 8, style: Draw.filled_and_outlined(panel, card_edge, 1) })
	frame.text_at!({ pos: { x: 68, y: panel_top + 14 }, text: "first ${U64.to_str(preview_lines)} lines of the body", size: 13, color: faint })
	frame.line!({ start: { x: 44, y: panel_top + 40 }, end: { x: 44 + width, y: panel_top + 40 }, stroke: Stroke({ color: card_edge, thickness: 1 }) })

	frame.with_scissor!(
		Math.rect(44, panel_top + 40, width, panel_height - 40),
		|clipped| {
			draw_body!(clipped, model.state, panel_top + 54)
			Ok({})
		},
	)?

	model.hint.draw!(frame, { pos: { x: 44, y: size.height - 40 }, color: faint })
	Ok({})
}

## In flight: a comet of fading dots turning on wall-clock elapsed time, so a
## stalled frame loop would show. Settled: a dot resting in a quiet ring.
draw_indicator! : Draw.Frame, { x : F32, y : F32 }, State, F32 => {}
draw_indicator! = |frame, center, state, elapsed| {
	color = state_color(state)
	frame.circle!({ center: center, radius: 20, style: Draw.outlined(Color.with_alpha(color, 55), 1.5) })
	match state {
		Waiting =>
			List.for_each!(
				spinner_dots,
				|dot| {
					angle = elapsed * 3.6 - dot.lag
					frame.circle!({
						center: { x: center.x + 20 * F32.cos(angle), y: center.y + 20 * F32.sin(angle) },
						radius: dot.radius,
						style: Draw.filled(Color.with_alpha(color, dot.alpha)),
					})
				},
			)

		_ => frame.circle!({ center: center, radius: 6, style: Draw.filled(color) })
	}
}

## What the panel holds, clipped to it: the preview, or why there is none.
draw_body! : Draw.Frame, State, F32 => {}
draw_body! = |frame, state, top|
	match state {
		Loaded({ lines, status: _, bytes: _, waited_ms: _ }) => draw_lines!(frame, lines, top)
		Waiting => frame.text_at!({ pos: { x: 68, y: top + 6 }, text: "waiting for the server...", size: 15, color: muted })
		Failed(_) => frame.text_at!({ pos: { x: 68, y: top + 6 }, text: "nothing to show", size: 15, color: faint })
	}

## Draw the body preview, one line per row, banded so long rows stay readable.
draw_lines! : Draw.Frame, List(Str), F32 => {}
draw_lines! = |frame, lines, top| {
	var $row = 0
	for line in lines {
		y = top + 22 * U64.to_f32($row)
		if $row % 2 == 1 {
			frame.rectangle!({ x: 44, y: y - 3, width: 4000, height: 22, style: Draw.filled(Color.from_hex_rgba(0xffffff06)) })
		}
		frame.text_at!({ pos: { x: 68, y: y }, text: line, size: 15, color: body_ink })
		$row = $row + 1
	}
}

spinner_dots : List({ lag : F32, radius : F32, alpha : U8 })
spinner_dots = [
	{ lag: 0, radius: 4.0, alpha: 255 },
	{ lag: 0.3, radius: 3.4, alpha: 190 },
	{ lag: 0.6, radius: 2.8, alpha: 135 },
	{ lag: 0.9, radius: 2.2, alpha: 85 },
	{ lag: 1.2, radius: 1.7, alpha: 45 },
]

bg_top = Color.from_hex_rgb(0x0b0e17)

bg_bottom = Color.from_hex_rgb(0x151b2a)

card = Color.from_hex_rgb(0x171d2b)

panel = Color.from_hex_rgb(0x131926)

card_edge = Color.from_hex_rgb(0x2a3348)

ink = Color.from_hex_rgb(0xe8ecf5)

body_ink = Color.from_hex_rgb(0xb9c4d8)

muted = Color.from_hex_rgb(0x8a97b0)

faint = Color.from_hex_rgb(0x5c6880)

accent_url = Color.from_hex_rgb(0x6fb3e0)

## One line describing where the request has got to.
headline : State -> Str
headline = |state|
	match state {
		Waiting => "fetching..."
		Failed(reason) => Str.concat("failed: ", reason)
		Loaded({ status, bytes, waited_ms, lines: _ }) =>
			Str.join_with(
				["HTTP ${U16.to_str(status)}", "${U64.to_str(bytes)} bytes", "${U64.to_str(waited_ms)} ms"],
				"    ",
			)
		}

## Green when a response arrived, red when it did not, amber while waiting.
## One colour drives the card's accent bar, its status line and its indicator,
## so the whole card reads as one state.
state_color : State -> Color.Rgba
state_color = |state|
	match state {
		Waiting => Color.from_hex_rgb(0xf2c777)
		Loaded(_) => Color.from_hex_rgb(0x7fd6a2)
		Failed(_) => Color.from_hex_rgb(0xef7d7d)
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
