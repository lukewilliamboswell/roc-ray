app [Model, program] {
	rr: platform "../../platform/main.roc",
	roc: "nightly-2026-09-06-d85e877",
}

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Devices
import rr.Keys
import rr.Math
import rr.Font
import Api as Events

## Every resource type is named through the sole platform dependency.
Model : {
	resources : Events.Resources,
	started : U64,
	label : Str,
	clicked : Bool,
	padded : Bool,
	age : F32,
	font : Font,
	layout : { label : Draw.TextSize, label_pos : { x : F32, y : F32 } },
	layout_passes : U64,
	swatch : Draw.Texture,
	swatch_aspect : F32,
	pulse : Events.Pulse,
}

program = { init!, update!, render! }

init! : App.Init(Model, [TextureGenerationFailed, ResourceLimit])
init! = App.init(
	App.default,
	|_startup| {
		font = Draw.default_font!()
		label = "idle"
		sized = Events.describe(Assets.generate_color_texture!({ width: 8, height: 4, color: Color.blue })?)
		Ok({
			resources: Events.resource_stubs,
			started: 0,
			label,
			clicked: Bool.False,
			padded: Bool.False,
			age: 0,
			font,
			layout: solve_layout(font, label),
			layout_passes: 1,
			swatch: Events.retained(sized),
			swatch_aspect: sized.aspect,
			pulse: { cycle: 0, messages: 0, clicked: Bool.False },
		})
	},
)

solve_layout : Font, Str -> { label : Draw.TextSize, label_pos : { x : F32, y : F32 } }
solve_layout = |font, label| {
	label_size = Font.measure(font, { text: label, size: 20, spacing: Draw.default_spacing })
	{ label: label_size, label_pos: { x: 10, y: 10 } }
}

label_for : Devices.Snapshot -> Str
label_for = |input|
	match Events.key_event(input, KeyW) {
		KeyDown(key) => if Keys.key_code(key) == 87 "W held" else "other key"
		Click(_) => "click"
		Pad(_) => "pad"
		Nothing => "idle"
	}

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices

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
	# `program_input.time` rather than from the input snapshot.
	started = if program_input.time.cycle_count == 0 program_input.time.simulation_nanos else model.started
	label = label_for(input)

	# Interaction resolves against the retained previous layout. The next layout
	# is then solved exactly once and stored for render and the following update.
	label_bounds = { x: model.layout.label_pos.x, y: model.layout.label_pos.y, width: model.layout.label.width, height: model.layout.label.height }
	label_clicked = input.mouse.button_pressed(Left) and Math.contains(label_bounds, input.mouse.position())
	next_label = if label_clicked "label click" else label
	layout = solve_layout(model.font, next_label)

	# The texture makes the same round trip in pure code, once per cycle, so the
	# identity is exercised where a host resource is only being moved rather than
	# created -- a reference the package took and gave back has to still be the
	# one the host owns.
	sized = Events.describe(model.swatch)

	if input.key_pressed(KeyQ) {
		Err(Exit(0))
	} else {
		Ok({
			resources: Events.retain_resources(model.resources),
			started,
			label: next_label,
			clicked,
			padded,
			age: Events.age_seconds(started, program_input.time.simulation_nanos),
			font: model.font,
			layout,
			layout_passes: model.layout_passes + 1,
			swatch: Events.retained(sized),
			swatch_aspect: sized.aspect,
			pulse: Events.pulse(program_input),
		})
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(if model.clicked Color.blue else Color.ray_white)
	frame.text!({ pos: model.layout.label_pos, text: model.label, size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font })
	frame.text_at!({ pos: { x: 10, y: 40 }, text: F32.to_str(model.age), size: 20, color: Color.black })
	frame.text_at!({ pos: { x: 10, y: 70 }, text: if model.padded "pad" else "no pad", size: 20, color: Color.black })

	# The last step of the round trip: a texture that has been through a
	# package-typed function every cycle since `init!` goes back to the host,
	# through a platform call that accepts nothing but the platform's own type.
	frame.texture!(Draw.texture_at(model.swatch, { x: 10, y: 100 }))
	frame.text_at!({ pos: { x: 10, y: 130 }, text: F32.to_str(model.swatch_aspect), size: 20, color: Color.black })
	frame.text_at!({ pos: { x: 10, y: 160 }, text: U64.to_str(model.pulse.cycle), size: 20, color: Color.black })
	Ok({})
}

## Input construction remains pure after moving the nominal into App.
expect {
	input : App.Input(U64)
	input = App.Input.for_tests({}).with_messages([3, 7])
	Events.pulse(input).messages == 2
}

expect {
	input : App.Input(U64)
	input = App.Input.for_tests({}).with_message(3).with_message(7)
	input.messages == [3, 7]
}
