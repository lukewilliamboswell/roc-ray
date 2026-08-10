app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Color
import rr.Draw
import rr.Program
import rr.Text

## Everything `render!` needs must live here now: it is handed no step, so
## anything read from input or the clock has to be recorded by `update` first.
Model : {
	title : Text.Prepared,
	help : Text.Prepared,
	metrics : Text.Metrics,
	pointer : { x : F32, y : F32 },
	accent_on : Bool,
}

program = { init!, update, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default.with_title("Hello RocRay").with_frame_pacing(Capped(120)),
	|_startup| {
		metrics = Text.metrics!(Text.default_font)
		Ok({
			title: Text.from("Roc :heart: Raylib").size(38).prepare!()?,
			help: Text.from("Move the pointer, click for an accent, ESC exits").size(18).prepare!()?,
			metrics,
			pointer: { x: 400, y: 300 },
			accent_on: Bool.False,
		})
	},
)

## Fold one cycle of observations into the model.
##
## No `!`: this is a pure function, so it cannot read input or exit by itself.
## It is handed everything the host saw and returns the next model plus the work
## it wants done -- here, an `Exit` action on the frame Escape is pressed.
Msg : []

update : Model, Program.Step(Msg) -> Program.Update(Model, Msg)
update = |model, step| {
	input = step.input
	Program.static({ ..model, pointer: input.mouse.position(), accent_on: input.mouse.button_down(Left) })
		.with_actions(if input.key_pressed(KeyEscape) [Program.exit(0)] else [])
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	accent = if model.accent_on Color.from_hex_rgb(0xf94144) else Color.from_hex_rgb(0x2f80ed)
	panel = { x: 120, y: 150, width: 560, height: 300 }
	title_size = model.metrics.measure({ text: "Roc :heart: Raylib", size: 38, spacing: Text.default_spacing })

	frame.clear!(Color.from_hex_rgb(0x0d1425))
	frame.circle_gradient!({ center: { x: 620, y: 90 }, radius: 260, color_inner: Color.with_alpha(accent, 100), color_outer: Color.with_alpha(accent, 0) })
	frame.rounded_rectangle!({ x: panel.x, y: panel.y, width: panel.width, height: panel.height, radius: 22, segments: 12, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x18243b), Color.with_alpha(Color.white, 55), 2) })
	model.title.draw!(frame, { pos: { x: 400, y: 230 }, color: Color.white, align: Text.align_top_center })
	model.help.draw!(frame, { pos: { x: 400, y: 302 }, color: Color.from_hex_rgb(0xa8b4cc), align: Text.align_top_center })
	frame.line!({ start: { x: 400 - title_size.width * 0.5, y: 370 }, end: { x: 400 + title_size.width * 0.5, y: 370 }, stroke: Draw.stroke(Color.with_alpha(accent, 170), 3) })
	frame.circle!({ center: model.pointer, radius: 18, style: Draw.filled_and_outlined(accent, Color.white, 3) })

	Ok({})
}
