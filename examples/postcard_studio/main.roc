## Create a postcard, move the sun with the mouse, choose a colourway with
## 1-3, and press S to export `postcards/sunrise.png`. Escape quits. Run with
## `--record-demo` to write `examples/gallery/postcard_studio.gif` instead.
##
## This example shows how to draw a large composition into a render texture,
## display a scaled preview, and use a Task for an export that may take time.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc6/7sujbfhDKezq7FAp75Nk4mTkTiPNDH36zmAMyGskmZoy.tar.zst", roc: "nightly-2026-09-27-a3ce7f1" }

import rr.App
import rr.Capture
import rr.Color
import rr.Draw
import rr.Math
import rr.Task
import rr.Text

## State retained between updates: prepared text and the large render texture,
## the selected colourway and sun position, export status, and whether the
## repeatable demo is running. Keeping the render texture here lets `render!`
## draw the same full-resolution postcard before showing its smaller preview.
Model : {

	## Prepared at the poster's size, because that is where they are drawn: the
	## window sees them through the same downscale as everything else.
	card : { title : Text.Prepared, subtitle : Text.Prepared },

	## Interface text, drawn on the window at window size, and deliberately not
	## part of the postcard.
	chrome : { help : Text.Prepared, idle : Text.Prepared, saving : Text.Prepared, saved : Text.Prepared, failed : Text.Prepared },
	poster : Draw.RenderTexture,
	theme : U64,
	sun : Math.Vec2,
	status : Text.Prepared,
	demo : Bool,
}

Msg : [PostcardExported(Try({}, Capture.TextureExportError))]

program = { init!, update!, render! }

## The window, and the poster it is a view of. Everything drawn into the poster
## is in poster coordinates, so the two only meet where the target is blitted.
window_width = 720.F32

window_height = 480.F32

poster_width = 1440.F32

poster_height = 960.F32

## Recording mode. `--record-demo` hides the window, moves the sun and the
## colourway along `demo_sun` and `demo_theme` instead of following the mouse
## and keyboard, and writes a GIF for the README gallery into
## `examples/gallery/`. The recording stops itself after `demo_frames` frames,
## and `update!` exits when it has been written.
record_demo_flag = "--record-demo"

demo_frames = 125.U64

demo_recording : Capture.Recording
demo_recording =
	Capture.default
		.with_path("postcard_studio.gif")
		.with_format(Gif)
		.with_fps(25)
		.with_max_frames(demo_frames)
		.with_scale(Half)
		.with_timing(FixedStep)

## Selects an interactive window that exports into `postcards/`, or a hidden
## one that records the demo into the gallery.
postcard_config : List(Str) -> App.Config
postcard_config = |args| {
	base =
		App.default
			.with_title("RocRay Postcard Studio")
			.with_size({ width: 720, height: 480 })
			.with_frame_pacing(Capped(120))
	if List.contains(args, record_demo_flag) base.with_visible(Bool.False).with_output_dir("examples/gallery") else base.with_output_dir("postcards")
}

## The demo's colourway on a given cycle: each of the three in turn.
demo_theme : U64 -> U64
demo_theme = |cycle| if cycle < 42 0 else if cycle < 84 1 else 2

## The demo's sun on a given cycle: an arc across the sky, dipping in the
## middle, repeated every `demo_frames` cycles.
demo_sun : U64 -> Math.Vec2
demo_sun = |cycle| {
	phase = U64.to_f32(cycle % demo_frames) / U64.to_f32(demo_frames)
	{ x: 110 + phase * 500, y: 145 + F32.abs(phase * 2 - 1) * 90 }
}

## A demo run is over once its recording has been written, or has failed.
demo_finished : Capture.Status -> Try({}, [Exit(I64)])
demo_finished = |status|
	match status {
		Finished(_) => Err(Exit(0))
		Failed(_) => Err(Exit(1))
		_ => Ok({})
	}

## `PermissionDenied` is in the error list only because `Capture.Writer.start!`
## can return it; the `io` that `init!` receives always has permission to record.
init! : App.Init(Model, [PermissionDenied, ResourceLimit, RenderTextureLoadFailed])
init! = App.init_for_args(
	postcard_config,
	|io| {
		demo = List.contains(io.args!(), record_demo_flag)
		if demo {
			io.capture().start!(demo_recording)?
		}

		font = Draw.default_font!()
		idle = Text.from("Ready to export 1440x960", font).size(14).prepare!()?
		Ok({
			card: {
				title: Text.from("POSTCARD STUDIO", font).size(68).prepare!()?,
				subtitle: Text.from("Wish you were here", font).size(40).prepare!()?,
			},
			chrome: {
				help: Text.from("Mouse moves the sun  |  1-3 colourway  |  S exports  |  ESC quits", font).size(13).prepare!()?,
				idle,
				saving: Text.from("Exporting sunrise.png ...", font).size(14).prepare!()?,
				saved: Text.from("Saved postcards/sunrise.png", font).size(14).prepare!()?,
				failed: Text.from("Export failed", font).size(14).prepare!()?,
			},
			poster: Draw.RenderTexture.load!({ width: 1440, height: 960 })?,
			theme: 0,
			sun: { x: 520, y: 170 },
			status: idle,
			demo,
		})
	},
)

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, io| {
	devices = input.devices
	chrome = model.chrome
	resolved = List.fold(
		input.messages,
		model,
		|current, message|
			match message {
				PostcardExported(Ok(_)) => { ..current, status: chrome.saved }
				PostcardExported(Err(_)) => { ..current, status: chrome.failed }
			},
	)

	cycle = input.time.cycle_count
	theme =
		if resolved.demo demo_theme(cycle)
		else if devices.key_pressed(Key1) 0
		else if devices.key_pressed(Key2) 1
		else if devices.key_pressed(Key3) 2
		else resolved.theme

	save = devices.key_pressed(KeyS)
	sun = if resolved.demo demo_sun(cycle) else devices.mouse.position()
	next = {
		..resolved,
		theme,
		sun,
		status: if save chrome.saving else resolved.status,
	}

	if save {
		Task.spawn!(input, || PostcardExported(io.capture().screenshot_texture!(next.poster, "sunrise.png")))
	}

	if resolved.demo {
		demo_finished(input.capture)?
	}
	Ok(next)
}

## The five colours needed to render one postcard colourway.
Palette := { sky_top : Color.Rgba, sky_bottom : Color.Rgba, sun : Color.Rgba, sea : Color.Rgba, ink : Color.Rgba }.{
	for_theme : U64 -> Palette
	for_theme = |theme|
		match theme {
			0 => { sky_top: Color.from_hex_rgb(0x23395d), sky_bottom: Color.from_hex_rgb(0xf4a261), sun: Color.from_hex_rgb(0xffd166), sea: Color.from_hex_rgb(0x1d5b79), ink: Color.from_hex_rgb(0xfff4dd) }
			1 => { sky_top: Color.from_hex_rgb(0x512b58), sky_bottom: Color.from_hex_rgb(0xe07a5f), sun: Color.from_hex_rgb(0xf2cc8f), sea: Color.from_hex_rgb(0x3d405b), ink: Color.white }
			_ => { sky_top: Color.from_hex_rgb(0x0b525b), sky_bottom: Color.from_hex_rgb(0x56cfe1), sun: Color.from_hex_rgb(0xffe66d), sea: Color.from_hex_rgb(0x144552), ink: Color.from_hex_rgb(0xf7fff7) }
		}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ScopeUnavailable])
render! = |model, frame| {
	colors = Palette.for_theme(model.theme)
	card = model.card

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

			card.title.draw!(poster, { pos: { x: 84, y: 80 }, color: colors.ink })
			card.subtitle.draw!(poster, { pos: { x: 88, y: 172 }, color: Color.with_alpha(colors.ink, 210) })
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

	# A scrim under the chrome, so the controls stay legible over any colourway
	# without a border cutting into the postcard itself.
	frame.rectangle!({ x: 0, y: window_height - 46, width: window_width, height: 46, style: Draw.filled(Color.with_alpha(Color.from_hex_rgb(0x0b1120), 205)) })
	frame.rectangle!({ x: 0, y: window_height - 46, width: window_width, height: 1, style: Draw.filled(Color.with_alpha(colors.ink, 60)) })

	chrome = model.chrome
	chrome.help.draw!(frame, { pos: { x: 24, y: window_height - 23 }, color: Color.with_alpha(colors.ink, 170), align: (Middle, Left) })
	model.status.draw!(frame, { pos: { x: 696, y: window_height - 23 }, color: colors.ink, align: (Middle, Right) })

	Ok({})
}

## The demo shows every colourway, and its sun starts low on the left.
expect demo_theme(0) == 0 and demo_theme(60) == 1 and demo_theme(120) == 2
expect demo_sun(0).x == 110
