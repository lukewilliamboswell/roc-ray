app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Color
import rr.Draw
import rr.Host
import rr.Program
import rr.Text

## Everything `render!` needs must live here now: it is handed no `Host`, so
## anything read from input or the clock has to be recorded by `update!` first.
Model : {
	title : Text.Prepared,
	help : Text.Prepared,
	pointer : { x : F32, y : F32 },
	accent_on : Bool,
}

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default.with_title("Hello RocRay").with_frame_pacing(Capped(120)),
	|_host|
		Ok({
			title: Text.from("Roc :heart: Raylib").size(38).prepare!()?,
			help: Text.from("Move the pointer, click for an accent, ESC exits").size(18).prepare!()?,
			pointer: { x: 400, y: 300 },
			accent_on: Bool.False,
		}),
)

## Fold one message into the model.
##
## Reading `host` here rather than in `render!` is the whole change: the frame
## snapshot arrives as a message, so the host can record and replay it.
update! : Model, Program.Input => Try({ model : Model, cmds : List(Program.Cmd) }, [Exit(I64), ..])
update! = |model, input|
	match input {
		Frame(host) => {
			if host.key_pressed(KeyEscape) {
				host.exit!(0)
			}
			Ok({
				model: { ..model, pointer: host.mouse.position(), accent_on: host.mouse.button_down(Left) },
				cmds: [],
			})
		}

		_ => Ok({ model: model, cmds: [] })
	}

render! : Model, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, frame| {
	accent = if model.accent_on Color.from_hex_rgb(0xf94144) else Color.from_hex_rgb(0x2f80ed)
	panel = { x: 120, y: 150, width: 560, height: 300 }

	frame.clear!(Color.from_hex_rgb(0x0d1425))
	frame.circle_gradient!({ center: { x: 620, y: 90 }, radius: 260, color_inner: Color.with_alpha(accent, 100), color_outer: Color.with_alpha(accent, 0) })
	frame.rounded_rectangle!({ x: panel.x, y: panel.y, width: panel.width, height: panel.height, radius: 22, segments: 12, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x18243b), Color.with_alpha(Color.white, 55), 2) })
	model.title.draw!(frame, { pos: { x: 400, y: 230 }, color: Color.white, align: Text.align_top_center })
	model.help.draw!(frame, { pos: { x: 400, y: 302 }, color: Color.from_hex_rgb(0xa8b4cc), align: Text.align_top_center })
	frame.line!({ start: { x: 245, y: 370 }, end: { x: 555, y: 370 }, stroke: Draw.stroke(Color.with_alpha(accent, 170), 3) })
	frame.circle!({ center: model.pointer, radius: 18, style: Draw.filled_and_outlined(accent, Color.white, 3) })

	Ok(model)
}
