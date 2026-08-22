app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Task
import rr.Color
import rr.Draw
import rr.Stdout
import rr.Text

## A task that waits without stalling the frame, and one that reports.
##
## On the first cycle `update!` spawns one task: an effectful closure that calls
## `Task.sleep!(300)` and then answers `Woke`. The host runs it on its
## own coroutine stack; the sleep parks that stack, the frame loop keeps going,
## and the closure's return value arrives on `Input.messages` ~18 cycles later
## at 60 Hz. Meanwhile the circle keeps orbiting.
##
## `Woke` starts a second task, and that one prints a line to standard output.
## Writing to a stream waits for the same reason a file read does -- a pipe
## whose reader is slow blocks the writer -- so it is refused in `update!` and
## belongs in a task. The app exits when the printing task's own message comes
## back, not when it spawns it: a task still parked at shutdown is cancelled,
## so exiting in the same `update!` that spawned the report would race the
## report to the terminal. That is what makes this the shape a headless CI run
## should use to say what it verified.
Model : {
	state : State,
	cycle : U64,
	elapsed : F32,
	title : Text.Prepared,
}

## How far the app has got. `Reporting` is spawned-but-unanswered, and only
## `Reported` means the line is out of the process.
State : [Waiting, Woke({ arrived_on : U64 }), Reporting({ arrived_on : U64 }), Reported({ arrived_on : U64 })]

Msg : [Woke, Reported]

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
	}

	# The sleeper's message is the trigger for the report, and spawning is what
	# moves the state on, so the line is printed exactly once.
	state = match settled {
		Woke({ arrived_on }) => {
			line = report_line(arrived_on)
			Task.spawn!(
				input,
				|| {
					_ = Stdout.line!(line)
					Reported
				},
			)
			Reporting({ arrived_on: arrived_on })
		}
		other => other
	}

	if input.devices.key_pressed(KeyEscape) or is_reported(state) {
		Err(Exit(0))
	} else {
		Ok({ ..model, state, cycle, elapsed: model.elapsed + input.time.elapsed_seconds })
	}
}

## What the reporting task writes. Built in `update!`, where it is pure, and
## captured by the closure that does the waiting.
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
		Reported =>
			match state {
				Waiting => Waiting
				Woke(when) => Reported(when)
				Reporting(when) => Reported(when)
				Reported(when) => Reported(when)
			}
		}

## Only the printing task's own message ends the run, so the line is out of the
## process before the host tears the app down.
is_reported : State -> Bool
is_reported = |state|
	match state {
		Reported(_) => Bool.True
		_ => Bool.False
	}

expect match apply_message(Waiting, Woke, 18) {
	Woke({ arrived_on }) => arrived_on == 18
	_ => Bool.False
}

## The cycle the sleeper woke on survives the report, so the app still reports
## the cycle it measured rather than the cycle the printing finished on.
expect apply_message(Reporting({ arrived_on: 18 }), Reported, 25) == Reported({ arrived_on: 18 })

expect !(is_reported(Reporting({ arrived_on: 18 })))
expect is_reported(Reported({ arrived_on: 18 }))

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
		Reporting({ arrived_on }) => Str.concat("printing the report for cycle ", U64.to_str(arrived_on))
		Reported({ arrived_on }) => Str.concat("reported cycle ", U64.to_str(arrived_on))
	}
