app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Color
import rr.Draw
import rr.Text

## The whole app loop, with nothing else in the way: prepare text once in
## `init!`, fold each cycle's input into the model in `update!`, draw the model
## in `render!`, and leave with `Err(Exit(0))`.
##
## `render!` is handed a frame and the model, and no input, so anything it needs
## to know about the pointer or the clock has to be in the model. That is what
## this one holds.
Model : {
	title : Text.Prepared,
	help : Text.Prepared,
	font : Draw.Font,
	layout : Layout,
	pointer : { x : F32, y : F32 },
	accent_on : Bool,

	## Seconds since launch, folded in from `input.time`. `render!` gets no
	## input, so anything that moves has to be read off the model like this.
	elapsed : F32,
}

Layout : {
	panel : { x : F32, y : F32, width : F32, height : F32 },
	title_size : Draw.TextSize,
}

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("Hello RocRay")
		.with_size({ width: 800, height: 600 })
		.with_frame_pacing(Capped(120)),
	|_startup| {
		font = Draw.default_font!()
		Ok({
			title: Text.from("Roc :heart: Raylib", font).size(38).prepare!()?,
			help: Text.from("Move the pointer  -  click for an accent  -  ESC exits", font).size(18).prepare!()?,
			font,
			layout: solve_layout(font),
			pointer: { x: 400, y: 300 },
			accent_on: Bool.False,
			elapsed: 0,
		})
	},
)

## Nothing here waits, so there is no task to spawn and no message to fold in.
## An app that reads a file or fetches a URL gives `Msg` the variants those
## tasks answer with; see the `task_sleep` and `async_read` examples.
Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices
	if input.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		# Solve once for the next model. `render!` consumes this retained layout and
		# the following update can use it for hit testing without any host calls.
		layout = solve_layout(model.font)
		Ok({
			..model,
			layout,
			pointer: input.mouse.position(),
			accent_on: input.mouse.button_down(Left),
			elapsed: model.elapsed + program_input.time.elapsed_seconds,
		})
	}
}

solve_layout : Draw.Font -> Layout
solve_layout = |font| {
	panel: { x: 120, y: 150, width: 560, height: 300 },
	title_size: font.measure({ text: "Roc :heart: Raylib", size: 38, spacing: Text.default_spacing }),
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	accent = if model.accent_on Color.from_hex_rgb(0xf94144) else Color.from_hex_rgb(0x2f80ed)
	panel = model.layout.panel
	title_size = model.layout.title_size
	# One slow sine drives every moving part, so the scene breathes together.
	pulse = 0.5 + 0.5 * F32.sin(model.elapsed * 1.6)

	frame.rectangle_gradient_v!({ x: 0, y: 0, width: 800, height: 600, color_top: Color.from_hex_rgb(0x131f38), color_bottom: Color.from_hex_rgb(0x070b16) })
	frame.circle_gradient!({ center: { x: 620, y: 90 }, radius: 220 + 40 * pulse, color_inner: Color.with_alpha(accent, 90), color_outer: Color.with_alpha(accent, 0) })
	frame.circle_gradient!({ center: { x: 150, y: 540 }, radius: 260, color_inner: Color.with_alpha(Color.from_hex_rgb(0x06d6a0), 45), color_outer: Color.with_alpha(Color.from_hex_rgb(0x06d6a0), 0) })

	# A soft drop shadow, then the panel itself over the top of it.
	frame.rounded_rectangle!({ x: panel.x + 6, y: panel.y + 10, width: panel.width, height: panel.height, radius: 22, segments: 12, style: Draw.filled(Color.with_alpha(Color.black, 90)) })
	frame.rounded_rectangle!({ x: panel.x, y: panel.y, width: panel.width, height: panel.height, radius: 22, segments: 12, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x18243b), Color.with_alpha(Color.white, 55), 2) })

	model.title.draw!(frame, { pos: { x: 400, y: 230 }, color: Color.white, align: Text.align_top_center })
	frame.line!({ start: { x: 400 - title_size.width * 0.5, y: 288 }, end: { x: 400 + title_size.width * 0.5, y: 288 }, stroke: Draw.stroke(Color.with_alpha(accent, 170), 3) })
	model.help.draw!(frame, { pos: { x: 400, y: 310 }, color: Color.from_hex_rgb(0xa8b4cc), align: Text.align_top_center })

	# The pointer gets a halo that pulses with the same clock as the backdrop.
	frame.circle!({ center: model.pointer, radius: 26 + 8 * pulse, style: Draw.filled(Color.with_alpha(accent, 40)) })
	frame.circle!({ center: model.pointer, radius: 18, style: Draw.filled_and_outlined(accent, Color.white, 3) })

	Ok({})
}
