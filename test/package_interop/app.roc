app [Model, program] {
	rr: platform "../../platform/main.roc",
	adapter: "input_adapter/main.roc",
}

import rr.App
import rr.Color
import rr.Draw
import rr.Input
import rr.Keys
import rr.Program
import adapter.Input as Events

## Everything the view needs, derived in `update` from values that came through
## the package. `render!` only draws, so the round trip has to survive being
## stored in the model rather than being re-read from a snapshot.
Model : {
	started : U64,
	label : Str,
	clicked : Bool,
	padded : Bool,
	age : F32,
}

program = { init!, update, render! }

## `init!` receives an `App.Startup`: authority, with nothing sampled yet. The
## first `Step` supplies the clock, so `started` is latched there.
init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|_startup| Ok({ started: 0, label: "idle", clicked: Bool.False, padded: Bool.False, age: 0 }),
)

## `input` is the platform's nominal `Input.Snapshot`; `KeyW` is the platform's
## re-exported `KeyboardKey`. The event comes back carrying that same key type,
## and the platform's `Keys.key_code` accepts it -- a full round trip through a
## package that only ever depended on `roc-ray-types`.
label_for : Input.Snapshot -> Str
label_for = |input|
	match Events.key_event(input, KeyW) {
		KeyDown(key) => if Keys.key_code(key) == 87 "W held" else "other key"
		Click(_) => "click"
		Pad(_) => "pad"
		Nothing => "idle"
	}

## Every call below hands a value obtained through the RocRay platform to a
## package that only ever depended on `roc-ray-types`. This compiles only if the
## platform's re-exports and the package's own types are the same nominals.
Msg : []

update : Model, Program.Step(Msg) -> Try(Program.Next(Model, Msg), [Exit(I64), ..])
update = |model, step| {
	input = step.input

	# `input.mouse` and `input.gamepads` are package-owned nominals reached
	# through the platform's snapshot.
	clicked = match Events.click_event(input.mouse) {
		Click(_) => Bool.True
		_ => Bool.False
	}
	padded = match Events.pad_event(input.gamepads, One) {
		Pad(_) => Bool.True
		_ => Bool.False
	}

	# Timing is its own observation now, so the package gets it from
	# `step.time` rather than from the input snapshot.
	started = if step.time.frame_count == 0 step.time.timestamp_nanos else model.started

	Ok({
		model: {
			started,
			label: label_for(input),
			clicked,
			padded,
			age: Events.age_seconds(started, step.time.timestamp_nanos),
		},
		actions: if input.key_pressed(KeyQ) [Program.exit(0)] else [],
		tasks: [],
	})
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(if model.clicked Color.blue else Color.ray_white)
	frame.text_at!({ pos: { x: 10, y: 10 }, text: model.label, size: 20, color: Color.black })
	frame.text_at!({ pos: { x: 10, y: 40 }, text: F32.to_str(model.age), size: 20, color: Color.black })
	frame.text_at!({ pos: { x: 10, y: 70 }, text: if model.padded "pad" else "no pad", size: 20, color: Color.black })
	Ok({})
}
