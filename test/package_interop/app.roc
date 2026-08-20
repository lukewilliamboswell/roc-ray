app [Model, program] {
	rr: platform "../../platform/main.roc",
	adapter: "input_adapter/main.roc",
	rrt: "../../types/main.roc",
	roc: "nightly-2026-08-19-edec830",
}

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Input
import rr.Keys
import rr.Math
import rr.Program
import rrt.Font
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
	font : Draw.Font,
	layout : { label : Draw.TextSize, label_pos : { x : F32, y : F32 } },
	layout_passes : U64,

	## A host-owned texture named through the *platform*, never through `rrt`.
	## It reaches this field only by passing through `Events.describe` and
	## `Events.retained`, both of which are typed `rrt.Texture`.
	swatch : Draw.Texture,

	## What the package measured on the way through.
	swatch_aspect : F32,
}

program = { init!, update, render! }

## `init!` receives an `App.Startup`: authority, with nothing sampled yet. The
## first `Step` supplies the clock, so `started` is latched there.
##
## The texture is generated here and immediately handed to the package. Only the
## platform could have produced it and only the platform can upload to it, but
## the package can hold and measure it -- the whole point of the split.
init! : App.Init(Model, [TextureGenerationFailed, ResourceLimit])
init! = App.init(
	App.static_config(App.default),
	|_startup| {
		font = Draw.default_font!()
		label = "idle"
		sized = Events.describe(Assets.generate_color_texture!({ width: 8, height: 4, color: Color.blue })?)
		Ok({
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
		})
	},
)

## This is the UI package boundary: it needs only the pure measurable-font
## contract, so layout can run during update without host authority.
solve_layout : font, Str -> { label : Draw.TextSize, label_pos : { x : F32, y : F32 } } where [font.base_size : font -> F32, font.line_spacing : font -> F32, font.glyphs : font -> List(Draw.GlyphMetrics), font.get_glyph_index : font, U32 -> U64]
solve_layout = |font, label| {
	label_size = Font.measure(font, { text: label, size: 20, spacing: Draw.default_spacing })
	{ label: label_size, label_pos: { x: 10, y: 10 } }
}

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

update : Model, Program.Step(Msg) -> Program.Update(Model, Msg)
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

	Program.static({
		started,
		label: next_label,
		clicked,
		padded,
		age: Events.age_seconds(started, step.time.timestamp_nanos),
		font: model.font,
		layout,
		layout_passes: model.layout_passes + 1,
		swatch: Events.retained(sized),
		swatch_aspect: sized.aspect,
	})
		.with_actions(if input.key_pressed(KeyQ) [Program.exit(0)] else [])
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(if model.clicked Color.blue else Color.ray_white)
	frame.text!({ pos: model.layout.label_pos, text: model.label, size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_top_left })
	frame.text_at!({ pos: { x: 10, y: 40 }, text: F32.to_str(model.age), size: 20, color: Color.black })
	frame.text_at!({ pos: { x: 10, y: 70 }, text: if model.padded "pad" else "no pad", size: 20, color: Color.black })

	# The last step of the round trip: a texture that has been through a
	# package-typed function every cycle since `init!` goes back to the host,
	# through a platform call that accepts nothing but the platform's own type.
	frame.texture!(Draw.texture_at(model.swatch, { x: 10, y: 100 }))
	frame.text_at!({ pos: { x: 10, y: 130 }, text: F32.to_str(model.swatch_aspect), size: 20, color: Color.black })
	Ok({})
}
