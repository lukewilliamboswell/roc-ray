app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Capture
import rr.Color
import rr.Draw
import rr.Math
import rr.Task
import rr.Text

## A tiny postcard maker: choose a colourway, move the sun, and export the
## composition as `postcards/sunrise.png` at twice the window's resolution.
##
## The postcard is composed once, into an offscreen render target 1440x960, and
## the window shows that target scaled down to fit. Pressing S exports the
## target itself, so the file is the full 1440x960 -- a window cannot be larger
## than the monitor, and a framebuffer capture cannot be larger than the window,
## so an offscreen target is the only way to export output at print size.
##
## The export runs from a task, at a realistic boundary: the editor stays
## responsive while the task parks on the host encoding the image, and the
## outcome arrives as a message on a later cycle.
Model : {

	## Prepared at the poster's size, because that is where they are drawn: the
	## window sees them through the same downscale as everything else.
	card : Box({ title : Text.Prepared, subtitle : Text.Prepared }),

	## Interface text, drawn on the window at window size, and deliberately not
	## part of the postcard.
	chrome : Box({ help : Text.Prepared, idle : Text.Prepared, saving : Text.Prepared, saved : Text.Prepared, failed : Text.Prepared }),
	poster : Draw.RenderTexture,
	theme : U64,
	sun : Math.Vec2,
	status : Text.Prepared,
}

Msg : [PostcardExported(Try({}, Capture.TextureExportError))]

program = { init!, update!, render! }

## The window, and the poster it is a view of. Everything drawn into the poster
## is in poster coordinates, so the two only meet where the target is blitted.
window_width : F32
window_width = 720

window_height : F32
window_height = 480

poster_width : F32
poster_width = 1440

poster_height : F32
poster_height = 960

init! : App.Init(Model, [ResourceLimit, RenderTextureLoadFailed])
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
			card: Box.box({
				title: Text.from("POSTCARD STUDIO", font).size(68).prepare!()?,
				subtitle: Text.from("Wish you were here", font).size(40).prepare!()?,
			}),
			chrome: Box.box({
				help: Text.from("Move the mouse | 1-3 change colour | S exports a 1440x960 PNG | ESC quits", font).size(15).prepare!()?,
				idle,
				saving: Text.from("Exporting postcards/sunrise.png at 1440x960 ...", font).size(16).prepare!()?,
				saved: Text.from("Saved postcards/sunrise.png at 1440x960", font).size(16).prepare!()?,
				failed: Text.from("Could not export the postcard", font).size(16).prepare!()?,
			}),
			poster: Draw.RenderTexture.load!({ width: 1440, height: 960 })?,
			theme: 0,
			sun: { x: 520, y: 170 },
			status: idle,
		})
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices
	chrome = Box.unbox(model.chrome)
	resolved = List.fold(
		program_input.messages,
		model,
		|current, message|
			match message {
				PostcardExported(Ok(_)) => { ..current, status: chrome.saved }
				PostcardExported(Err(_)) => { ..current, status: chrome.failed }
			},
	)

	theme =
		if input.key_pressed(Key1) 0
		else if input.key_pressed(Key2) 1
		else if input.key_pressed(Key3) 2
		else resolved.theme

	# Exports itself once early on as well, so a run with no keyboard -- the
	# headless sweep -- still takes the export path.
	save = input.key_pressed(KeyS) or program_input.time.cycle_count == 3
	next = {
		..resolved,
		theme,
		sun: input.mouse.position(),
		status: if save chrome.saving else resolved.status,
	}

	if save {
		Task.spawn!(program_input, || PostcardExported(Capture.screenshot_texture!(next.poster, "sunrise.png")))
	}

	if input.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		Ok(next)
	}
}

Palette : { sky_top : Color.Rgba, sky_bottom : Color.Rgba, sun : Color.Rgba, sea : Color.Rgba, ink : Color.Rgba }

palette : U64 -> Palette
palette = |theme|
	match theme {
		0 => { sky_top: Color.from_hex_rgb(0x23395d), sky_bottom: Color.from_hex_rgb(0xf4a261), sun: Color.from_hex_rgb(0xffd166), sea: Color.from_hex_rgb(0x1d5b79), ink: Color.from_hex_rgb(0xfff4dd) }
		1 => { sky_top: Color.from_hex_rgb(0x512b58), sky_bottom: Color.from_hex_rgb(0xe07a5f), sun: Color.from_hex_rgb(0xf2cc8f), sea: Color.from_hex_rgb(0x3d405b), ink: Color.white }
		_ => { sky_top: Color.from_hex_rgb(0x0b525b), sky_bottom: Color.from_hex_rgb(0x56cfe1), sun: Color.from_hex_rgb(0xffe66d), sea: Color.from_hex_rgb(0x144552), ink: Color.from_hex_rgb(0xf7fff7) }
	}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ScopeUnavailable, ..])
render! = |model, frame| {
	colors = palette(model.theme)
	card = Box.unbox(model.card)

	# Everything the postcard is made of, drawn at the size it is exported at.
	# The mouse arrives in window coordinates, so it is the one value that has
	# to cross into poster space.
	frame.with_render_texture!(
		model.poster,
		|poster| {
			poster.rectangle_gradient_v!({ x: 0, y: 0, width: poster_width, height: 680, color_top: colors.sky_top, color_bottom: colors.sky_bottom })
			poster.circle_gradient!({ center: { x: model.sun.x * 2, y: model.sun.y * 2 }, radius: 156, color_inner: colors.sun, color_outer: Color.with_alpha(colors.sun, 0) })
			poster.rectangle!({ x: 0, y: 680, width: poster_width, height: poster_height - 680, style: Draw.filled(colors.sea) })

			# A few repeated strokes suggest moving water without needing an
			# image asset.
			List.for_each!(
				[0.U64, 1.U64, 2.U64, 3.U64, 4.U64, 5.U64, 6.U64, 7.U64],
				|index| {
					y = 716 + U64.to_f32(index) * 28
					x = if index % 2 == 0 100 else 184
					poster.line!({ start: { x, y }, end: { x: x + 1120, y }, stroke: Draw.stroke(Color.with_alpha(colors.ink, 65), 4) })
				},
			)

			card.title.draw!(poster, { pos: { x: 84, y: 80 }, color: colors.ink, align: Text.align_top_left })
			card.subtitle.draw!(poster, { pos: { x: 88, y: 172 }, color: Color.with_alpha(colors.ink, 210), align: Text.align_top_left })
			Ok({})
		},
	)?

	# The window is a view of the poster, not a second rendering of it: one
	# composition, shown small and exported large.
	frame.texture!({
		texture: model.poster.texture(),
		source: model.poster.source(),
		dest: Math.rect(0, 0, window_width, window_height),
		origin: Math.zero,
		rotation: 0,
		tint: Color.white,
	})

	chrome = Box.unbox(model.chrome)
	chrome.help.draw!(frame, { pos: { x: 24, y: 446 }, color: colors.ink, align: Text.align_top_left })
	model.status.draw!(frame, { pos: { x: 696, y: 446 }, color: colors.ink, align: Text.align_top_right })

	Ok({})
}
