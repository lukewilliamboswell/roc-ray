app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Task
import rr.Color
import rr.Draw
import rr.Stdout
import rr.Text

## A task that waits without stalling the frame, and printing that does not.
##
## On the first cycle `update!` spawns one task: an effectful closure that calls
## `Task.sleep!(300)` and then answers `Woke`. The host runs it on its own
## coroutine stack; the sleep parks that stack, the frame loop keeps going, and
## the closure's return value arrives on `Input.messages` ~18 cycles later at
## 60 Hz. Meanwhile the circle keeps orbiting.
##
## The printing is the contrast. `Stdout.line!` is a queued effect: it copies
## into a host-owned queue and returns, so it belongs in `update!` alongside the
## rest of the app's decisions rather than in a task of its own. Exiting in the
## same `update!` that printed is safe, because the host drains what is queued
## before the process ends. Waiting is what needs a task; writing does not.
Model : {
	state : State,
	cycle : U64,
	elapsed : F32,
	title : Text.Prepared,
}

## How far the app has got: waiting on the sleeper, or holding the cycle its
## message arrived on.
State : [Waiting, Woke({ arrived_on : U64 })]

Msg : [Woke]

sleep_millis : U64
sleep_millis = 300

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

expect report_line(18) == "task_sleep: slept 300 ms, message arrived on cycle 18"

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
	frame.clear!(Color.from_hex_rgb(0x121420))
	model.title.draw!(frame, { pos: { x: 40, y: 40 }, color: Color.white, align: Text.align_top_left })
	frame.text_at!({ pos: { x: 40, y: 92 }, text: Str.concat("cycle ", U64.to_str(model.cycle)), size: 20, color: Color.from_hex_rgb(0x88c0d0) })
	frame.text_at!({ pos: { x: 40, y: 120 }, text: describe(model.state), size: 20, color: Color.from_hex_rgb(0xa3be8c) })
	frame.circle!({ center: { x: 400 + 220 * F32.cos(model.elapsed * 2), y: 300 + 120 * F32.sin(model.elapsed * 2) }, radius: 26, style: Draw.filled(Color.from_hex_rgb(0x5e81ac)) })
	Ok({})
}

describe : State -> Str
describe = |state|
	match state {
		Waiting => Str.concat(Str.concat("task sleeping ", U64.to_str(sleep_millis)), " ms...")
		Woke({ arrived_on }) => Str.concat(Str.concat("task finished: message arrived on cycle ", U64.to_str(arrived_on)), " (spawned on cycle 0)")
	}
