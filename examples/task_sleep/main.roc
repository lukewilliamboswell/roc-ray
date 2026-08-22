app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Task
import rr.Color
import rr.Draw
import rr.Text

## A task that waits without stalling the frame.
##
## On the first cycle `update!` spawns one task: an effectful closure that calls
## `Task.sleep!(300)` and then answers `Woke`. The host runs it on its
## own coroutine stack; the sleep parks that stack, the frame loop keeps going,
## and the closure's return value arrives on `Input.messages` ~18 cycles later
## at 60 Hz. Meanwhile the circle keeps orbiting.
Model : {
	state : [Waiting, Woke({ arrived_on : U64 })],
	cycle : U64,
	elapsed : F32,
	title : Text.Prepared,
}

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
	state = List.fold(input.messages, model.state, |current, message| apply_message(current, message, cycle))
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
	if input.devices.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		Ok({ ..model, state, cycle, elapsed: model.elapsed + input.time.elapsed_seconds })
	}
}

apply_message : [Waiting, Woke({ arrived_on : U64 })], Msg, U64 -> [Waiting, Woke({ arrived_on : U64 })]
apply_message = |state, message, cycle|
	match message {
		Woke =>
			match state {
				Waiting => Woke({ arrived_on: cycle })
				Woke(already) => Woke(already)
			}
		}

expect match apply_message(Waiting, Woke, 18) {
	Woke({ arrived_on }) => arrived_on == 18
	Waiting => Bool.False
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x121420))
	model.title.draw!(frame, { pos: { x: 40, y: 40 }, color: Color.white, align: Text.align_top_left })
	frame.text_at!({ pos: { x: 40, y: 92 }, text: Str.concat("cycle ", U64.to_str(model.cycle)), size: 20, color: Color.from_hex_rgb(0x88c0d0) })
	frame.text_at!({ pos: { x: 40, y: 120 }, text: describe(model.state), size: 20, color: Color.from_hex_rgb(0xa3be8c) })
	frame.circle!({ center: { x: 400 + 220 * F32.cos(model.elapsed * 2), y: 300 + 120 * F32.sin(model.elapsed * 2) }, radius: 26, style: Draw.filled(Color.from_hex_rgb(0x5e81ac)) })
	Ok({})
}

describe : [Waiting, Woke({ arrived_on : U64 })] -> Str
describe = |state|
	match state {
		Waiting => Str.concat(Str.concat("task sleeping ", U64.to_str(sleep_millis)), " ms...")
		Woke({ arrived_on }) => Str.concat(Str.concat("task finished: message arrived on cycle ", U64.to_str(arrived_on)), " (spawned on cycle 0)")
	}
