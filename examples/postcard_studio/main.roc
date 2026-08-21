app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Capture
import rr.Color
import rr.Draw
import rr.Math
import rr.Text

## A tiny postcard maker: choose a colourway, move the sun, and export the
## composition as `postcards/sunrise.png`.
##
## The screenshot request is used at a realistic boundary: the editor stays
## responsive while the host encodes the current frame, then reports the
## result back as a message.
Model : {
	copy : Box({ title : Text.Prepared, subtitle : Text.Prepared, help : Text.Prepared, idle : Text.Prepared, saving : Text.Prepared, saved : Text.Prepared, failed : Text.Prepared }),
	theme : U64,
	sun : Math.Vec2,
	status : Text.Prepared,
}

Msg : [PostcardSaved(Try({}, Capture.ScreenshotError))]

program = { init!, update, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("RocRay Postcard Studio")
		.with_size({ width: 720, height: 480 })
		.with_output_dir("postcards")
		.with_frame_pacing(Capped(120)),
	|_startup| {
		font = Draw.default_font!()
		idle = Text.from("Ready to export", font).size(16).prepare!()?
		Ok({
			copy: Box.box({
				title: Text.from("POSTCARD STUDIO", font).size(34).prepare!()?,
				subtitle: Text.from("Wish you were here", font).size(20).prepare!()?,
				help: Text.from("Move the mouse | 1-3 change colour | S exports PNG | ESC quits", font).size(15).prepare!()?,
				idle,
				saving: Text.from("Exporting postcards/sunrise.png ...", font).size(16).prepare!()?,
				saved: Text.from("Saved postcards/sunrise.png", font).size(16).prepare!()?,
				failed: Text.from("Could not export the postcard", font).size(16).prepare!()?,
			}),
			theme: 0,
			sun: { x: 520, y: 170 },
			status: idle,
		})
	},
)

update : Model, App.Input(Msg) -> App.Transition(Model, Msg)
update = |model, program_input| {
	input = program_input.devices
	copy = Box.unbox(model.copy)
	resolved = List.fold(
		program_input.messages,
		model,
		|current, message|
			match message {
				PostcardSaved(Ok(_)) => { ..current, status: copy.saved }
				PostcardSaved(Err(_)) => { ..current, status: copy.failed }
			},
	)

	theme =
		if input.key_pressed(Key1) 0
		else if input.key_pressed(Key2) 1
		else if input.key_pressed(Key3) 2
		else resolved.theme

	save = input.key_pressed(KeyS)
	next = {
		..resolved,
		theme,
		sun: input.mouse.position(),
		status: if save copy.saving else resolved.status,
	}

	App.next(next)
		.with_commands(if input.key_pressed(KeyEscape) [App.exit(0)] else [])
		.with_requests(if save [Capture.screenshot("sunrise.png", |result| PostcardSaved(result))] else [])
}

Palette : { sky_top : Color.Rgba, sky_bottom : Color.Rgba, sun : Color.Rgba, sea : Color.Rgba, ink : Color.Rgba }

palette : U64 -> Palette
palette = |theme|
	match theme {
		0 => { sky_top: Color.from_hex_rgb(0x23395d), sky_bottom: Color.from_hex_rgb(0xf4a261), sun: Color.from_hex_rgb(0xffd166), sea: Color.from_hex_rgb(0x1d5b79), ink: Color.from_hex_rgb(0xfff4dd) }
		1 => { sky_top: Color.from_hex_rgb(0x512b58), sky_bottom: Color.from_hex_rgb(0xe07a5f), sun: Color.from_hex_rgb(0xf2cc8f), sea: Color.from_hex_rgb(0x3d405b), ink: Color.white }
		_ => { sky_top: Color.from_hex_rgb(0x0b525b), sky_bottom: Color.from_hex_rgb(0x56cfe1), sun: Color.from_hex_rgb(0xffe66d), sea: Color.from_hex_rgb(0x144552), ink: Color.from_hex_rgb(0xf7fff7) }
	}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	colors = palette(model.theme)
	frame.rectangle_gradient_v!({ x: 0, y: 0, width: 720, height: 340, color_top: colors.sky_top, color_bottom: colors.sky_bottom })
	frame.circle_gradient!({ center: model.sun, radius: 78, color_inner: colors.sun, color_outer: Color.with_alpha(colors.sun, 0) })
	frame.rectangle!({ x: 0, y: 340, width: 720, height: 140, style: Draw.filled(colors.sea) })

	# A few repeated strokes suggest moving water without needing an image asset.
	List.for_each!(
		[0.U64, 1.U64, 2.U64, 3.U64, 4.U64, 5.U64, 6.U64, 7.U64],
		|index| {
			y = 358 + U64.to_f32(index) * 14
			x = if index % 2 == 0 50 else 92
			frame.line!({ start: { x, y }, end: { x: x + 560, y }, stroke: Draw.stroke(Color.with_alpha(colors.ink, 65), 2) })
		},
	)

	copy = Box.unbox(model.copy)
	copy.title.draw!(frame, { pos: { x: 42, y: 40 }, color: colors.ink, align: Text.align_top_left })
	copy.subtitle.draw!(frame, { pos: { x: 44, y: 86 }, color: Color.with_alpha(colors.ink, 210), align: Text.align_top_left })
	copy.help.draw!(frame, { pos: { x: 24, y: 446 }, color: colors.ink, align: Text.align_top_left })
	model.status.draw!(frame, { pos: { x: 696, y: 446 }, color: colors.ink, align: Text.align_top_right })

	Ok({})
}
