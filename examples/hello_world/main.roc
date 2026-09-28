## A minimal RocRay app with animated drawing and pointer input.
##
## Move the pointer, hold the left mouse button to change the accent colour,
## and press Escape to quit. This example introduces the three app functions:
## `init!` creates the starting state, `update!` responds to each `Input`, and
## `render!` draws the current state into a `Frame`.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc6/7sujbfhDKezq7FAp75Nk4mTkTiPNDH36zmAMyGskmZoy.tar.zst", roc: "nightly-2026-09-27-a3ce7f1" }

import rr.App
import rr.Color
import rr.Draw
import rr.Text

## State kept between host cycles: prepared text that can be reused, plus the
## latest pointer position, button state, and elapsed time needed to draw the
## next frame.
Model : {
	title : Text.Prepared,
	help : Text.Prepared,

	## How wide the title is drawn, measured once so `render!` can underline it.
	title_width : F32,
	pointer : { x : F32, y : F32 },
	accent_on : Bool,

	## Seconds since launch, folded in from `input.time`. `render!` gets no
	## input, so anything that moves has to be read off the model like this.
	elapsed : F32,
}

## The words on the panel. Named once, because `init!` both prepares and
## measures the title.
title_text = "Roc :heart: Raylib"

title_size = 38.F32

program = { init!, update!, render! }

## `App.default` already ends the app when you press Escape, so this app never
## checks for Escape itself.
init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("Hello RocRay")
		.with_size({ width: 800, height: 600 })
		.with_frame_pacing(Capped(120)),
	|_io| {
		font = Draw.default_font!()
		Ok({
			title: Text.from(title_text, font).size(title_size).prepare!()?,
			help: Text.from("Move the pointer  -  hold to turn red  -  Escape quits", font).size(18).prepare!()?,
			title_width: font.measure({ text: title_text, size: title_size, spacing: Text.default_spacing }).width,
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

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, _io| {
	devices = input.devices
	Ok({
		..model,
		pointer: devices.mouse.position(),
		accent_on: devices.mouse.button_down(Left),
		elapsed: model.elapsed + input.time.elapsed_seconds,
	})
}

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |model, frame| {
	# Everything is placed relative to the size of the window being drawn to,
	# so nothing here repeats the 800 x 600 from the config.
	size = frame.size!()
	center_x = size.width * 0.5
	panel = { x: center_x - 280, y: size.height * 0.5 - 150, width: 560, height: 300 }

	accent = if model.accent_on Color.from_hex_rgb(0xf94144) else Color.from_hex_rgb(0x2f80ed)
	# One slow sine drives every moving part, so the scene breathes together.
	pulse = 0.5 + 0.5 * F32.sin(model.elapsed * 1.6)

	frame.rectangle_gradient_v!({ x: 0, y: 0, width: size.width, height: size.height, color_top: Color.from_hex_rgb(0x131f38), color_bottom: Color.from_hex_rgb(0x070b16) })
	frame.circle_gradient!({ center: { x: size.width - 180, y: 90 }, radius: 220 + 40 * pulse, color_inner: Color.with_alpha(accent, 90), color_outer: Color.with_alpha(accent, 0) })
	frame.circle_gradient!({ center: { x: 150, y: size.height - 60 }, radius: 260, color_inner: Color.with_alpha(Color.from_hex_rgb(0x06d6a0), 45), color_outer: Color.with_alpha(Color.from_hex_rgb(0x06d6a0), 0) })

	# A soft drop shadow, then the panel itself over the top of it.
	frame.rounded_rectangle!({ x: panel.x + 6, y: panel.y + 10, width: panel.width, height: panel.height, radius: 22, segments: 12, style: Draw.filled(Color.with_alpha(Color.black, 90)) })
	frame.rounded_rectangle!({ x: panel.x, y: panel.y, width: panel.width, height: panel.height, radius: 22, segments: 12, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x18243b), Color.with_alpha(Color.white, 55), 2) })

	model.title.draw!(frame, { pos: { x: center_x, y: panel.y + 80 }, color: Color.white, align: (Top, Center) })
	half_title = model.title_width * 0.5
	frame.line!({ start: { x: center_x - half_title, y: panel.y + 138 }, end: { x: center_x + half_title, y: panel.y + 138 }, stroke: Draw.stroke(Color.with_alpha(accent, 170), 3) })
	model.help.draw!(frame, { pos: { x: center_x, y: panel.y + 160 }, color: Color.from_hex_rgb(0xa8b4cc), align: (Top, Center) })

	# The pointer gets a halo that pulses with the same clock as the backdrop.
	frame.circle!({ center: model.pointer, radius: 26 + 8 * pulse, style: Draw.filled(Color.with_alpha(accent, 40)) })
	frame.circle!({ center: model.pointer, radius: 18, style: Draw.filled_and_outlined(accent, Color.white, 3) })

	Ok({})
}
