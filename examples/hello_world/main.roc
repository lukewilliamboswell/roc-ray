app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc1/G7CQg3PE51ioJgNENceqkbQSjjX5ULEd2jHbtWBbn9aN.tar.zst", roc: "nightly-2026-08-21-90da19f" }

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
}

Layout : {
	panel : { x : F32, y : F32, width : F32, height : F32 },
	title_size : Draw.TextSize,
}

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default.with_title("Hello RocRay").with_frame_pacing(Capped(120)),
	|_startup| {
		font = Draw.default_font!()
		Ok({
			title: Text.from("Roc :heart: Raylib", font).size(38).prepare!()?,
			help: Text.from("Move the pointer, click for an accent, ESC exits", font).size(18).prepare!()?,
			font,
			layout: solve_layout(font),
			pointer: { x: 400, y: 300 },
			accent_on: Bool.False,
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
		Ok({ ..model, layout, pointer: input.mouse.position(), accent_on: input.mouse.button_down(Left) })
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

	frame.clear!(Color.from_hex_rgb(0x0d1425))
	frame.circle_gradient!({ center: { x: 620, y: 90 }, radius: 260, color_inner: Color.with_alpha(accent, 100), color_outer: Color.with_alpha(accent, 0) })
	frame.rounded_rectangle!({ x: panel.x, y: panel.y, width: panel.width, height: panel.height, radius: 22, segments: 12, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x18243b), Color.with_alpha(Color.white, 55), 2) })
	model.title.draw!(frame, { pos: { x: 400, y: 230 }, color: Color.white, align: Text.align_top_center })
	model.help.draw!(frame, { pos: { x: 400, y: 302 }, color: Color.from_hex_rgb(0xa8b4cc), align: Text.align_top_center })
	frame.line!({ start: { x: 400 - title_size.width * 0.5, y: 370 }, end: { x: 400 + title_size.width * 0.5, y: 370 }, stroke: Draw.stroke(Color.with_alpha(accent, 170), 3) })
	frame.circle!({ center: model.pointer, radius: 18, style: Draw.filled_and_outlined(accent, Color.white, 3) })

	Ok({})
}
