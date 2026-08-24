## Watch a comet keep moving while a 1.2-second Task waits; the app exits after
## the task finishes, or press Escape to quit. This example introduces Tasks as
## work that may wait without pausing drawing, and Messages as the values
## completed tasks deliver to a later Input.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Task
import rr.Color
import rr.Draw
import rr.Stdout
import rr.Text

## State retained between updates: whether the Task is still waiting, the
## current cycle and animation time, and prepared drawing resources. The Model
## records the cycle reported by the Task's Message so the result can be shown
## the next time `render!` draws.
Model : {
	state : State,
	cycle : U64,
	elapsed : F32,
	title : Text.Prepared,
	hint : Text.Prepared,
	font : Draw.Font,
}

## How far the app has got: waiting on the sleeper, or holding the cycle its
## message arrived on.
State : [Waiting, Woke({ arrived_on : U64 })]

Msg : [Woke]

sleep_millis = 1200.U64

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default.with_title("RocRay Task Sleep").with_frame_pacing(Capped(60)),
	|_host| {
		font = Draw.default_font!()
		Ok({
			state: Waiting,
			cycle: 0,
			elapsed: 0,
			title: Text.from("Sleeping on a task while the frame keeps moving", font).size(22).prepare!()?,
			hint: Text.from("ESC quits - the app closes itself once the task answers", font).size(14).prepare!()?,
			font,
		})
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	cycle = input.time.cycle_count
	settled = List.fold(input.messages, model.state, |current, message| apply_message(current, message, cycle))
	if cycle == 0 {
		# Spawned from inside `update!`: the task parks on its sleep before this
		# frame is drawn, and `Woke` arrives on a later input.
		Task.spawn!(
			input,
			|| {
				Task.sleep!(sleep_millis)
				Woke
			},
		)
		# Printed from `update!` too, one line before any of the waiting starts.
		_ = Stdout.line!(start_line)
	}

	match settled {
		Woke({ arrived_on }) => {
			# The line is queued here and written by the host's own thread, so
			# exiting on the next expression does not race it out of the
			# process: shutdown drains the queue.
			_ = Stdout.line!(report_line(arrived_on))
			Err(Exit(0))
		}
		Waiting =>
			if input.devices.key_pressed(KeyEscape) {
				Err(Exit(0))
			} else {
				Ok({ ..model, state: settled, cycle, elapsed: model.elapsed + input.time.elapsed_seconds })
			}
		}
}

## What `update!` prints on the cycle it spawns the sleeper.
start_line : Str
start_line = "task_sleep: sleeping ${U64.to_str(sleep_millis)} ms on a task while the frame loop keeps drawing"

## What `update!` prints once the sleeper's message comes back.
report_line : U64 -> Str
report_line = |arrived_on|
	"task_sleep: slept ${U64.to_str(sleep_millis)} ms, message arrived on cycle ${U64.to_str(arrived_on)}"

expect report_line(18) == "task_sleep: slept 1200 ms, message arrived on cycle 18"

apply_message : State, Msg, U64 -> State
apply_message = |state, message, cycle|
	match message {
		Woke =>
			match state {
				Waiting => Woke({ arrived_on: cycle })
				already => already
			}
		}

expect match apply_message(Waiting, Woke, 18) {
	Woke({ arrived_on }) => arrived_on == 18
	_ => Bool.False
}

## The cycle the sleeper woke on is the first one that arrived, so a second
## message could not move it.
expect apply_message(Woke({ arrived_on: 18 }), Woke, 25) == Woke({ arrived_on: 18 })

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	# How much of the sleep has gone by, clamped so a slow frame cannot
	# overshoot the ring. Purely a view value, so it is derived here.
	progress = F32.min(model.elapsed * 1000 / U64.to_f32(sleep_millis), 1)
	center = { x: 400.F32, y: 340.F32 }

	frame.rectangle_gradient_v!({ x: 0, y: 0, width: 800, height: 600, color_top: Color.from_hex_rgb(0x1b2136), color_bottom: Color.from_hex_rgb(0x0a0c15) })
	frame.circle_gradient!({ center, radius: 260, color_inner: Color.with_alpha(Color.from_hex_rgb(0x5e81ac), 40), color_outer: Color.with_alpha(Color.from_hex_rgb(0x5e81ac), 0) })

	model.title.draw!(frame, { pos: { x: 40, y: 40 }, color: Color.white, align: Text.align_top_left })
	frame.text_at!({ pos: { x: 40, y: 78 }, text: Str.concat("cycle ", U64.to_str(model.cycle)), size: 20, color: Color.from_hex_rgb(0x88c0d0) })
	frame.text_at!({ pos: { x: 40, y: 106 }, text: describe(model.state), size: 20, color: Color.from_hex_rgb(0xa3be8c) })
	model.hint.draw!(frame, { pos: { x: 40, y: 552 }, color: Color.from_hex_rgb(0x6b7590), align: Text.align_top_left })

	# The track, then the arc the sleeper has used up so far.
	frame.circle!({ center, radius: 150, style: Draw.outlined(Color.with_alpha(Color.white, 35), 3) })
	draw_arc!(frame, center, progress, 0)

	# A short trail of the orbiting comet: the same orbit sampled a few
	# frames back, fading out behind the head.
	draw_trail!(frame, center, model.elapsed, 8)
	frame.circle!({ center: orbit(center, model.elapsed), radius: 14, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x88c0d0), Color.white, 3) })

	Ok({})
}

## Where the comet is at a given moment. One function so the head and every
## trail sample are guaranteed to sit on the same orbit.
orbit : { x : F32, y : F32 }, F32 -> { x : F32, y : F32 }
orbit = |center, seconds| { x: center.x + 150 * F32.cos(seconds * 2), y: center.y + 150 * F32.sin(seconds * 2) }

draw_trail! : Draw.Frame, { x : F32, y : F32 }, F32, U64 => {}
draw_trail! = |frame, center, seconds, remaining|
	if remaining == 0 {
		{}
	} else {
		fade = U64.to_f32(remaining) / 8
		frame.circle!({ center: orbit(center, seconds - U64.to_f32(remaining) * 0.03), radius: 12 * fade, style: Draw.filled(Color.with_alpha(Color.from_hex_rgb(0x88c0d0), F32.to_u8_wrap(90 * fade))) })
		draw_trail!(frame, center, seconds, remaining - 1)
	}

## The progress arc, stepped by hand out of short segments so it needs nothing
## more than `frame.line!`.
draw_arc! : Draw.Frame, { x : F32, y : F32 }, F32, U64 => {}
draw_arc! = |frame, center, progress, step|
	if U64.to_f32(step) / 90 >= progress {
		{}
	} else {
		a = -1.5707964 + 6.2831855 * U64.to_f32(step) / 90
		b = -1.5707964 + 6.2831855 * U64.to_f32(step + 1) / 90
		frame.line!({
			start: { x: center.x + 150 * F32.cos(a), y: center.y + 150 * F32.sin(a) },
			end: { x: center.x + 150 * F32.cos(b), y: center.y + 150 * F32.sin(b) },
			stroke: Draw.stroke(Color.from_hex_rgb(0xa3be8c), 5),
		})
		draw_arc!(frame, center, progress, step + 1)
	}

describe : State -> Str
describe = |state|
	match state {
		Waiting => Str.concat(Str.concat("task sleeping ", U64.to_str(sleep_millis)), " ms...")
		Woke({ arrived_on }) => Str.concat(Str.concat("task finished: message arrived on cycle ", U64.to_str(arrived_on)), " (spawned on cycle 0)")
	}
