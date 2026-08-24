app [Model, program] {
	rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst",
	roc: "nightly-2026-08-23-fb208ba",
}

import rr.App
import rr.Assets
import rr.Audio
import rr.Color
import rr.Capture
import rr.Draw
import rr.Devices
import rr.Math
import rr.Mouse
import rr.Text

## A paint program whose canvas, palette, and brush sound are all generated at
## startup: no image or audio files.
##
## The canvas is one `Assets.Texture`. Painting a cell uploads that one cell with
## `Assets.update_texture_region!` rather than re-sending the whole grid. The
## editor is pure -- it returns the next model and a list of `Edit`s -- so what
## changed and what to do about it can never come apart, and `update!` is the
## thin shell that performs them.
##
## Run with `--record-demo` to paint a deterministic gallery GIF.
PaintState := [Idle, Painted(U64)].{
	is_eq : _
}

Model : {
	texture : Assets.Texture,
	pixels : List(Color.Rgba),
	paint_sound : Audio.Sound,
	palette : U64,
	last_cell : PaintState,
	mouse : Math.Vec2,
	demo : Bool,
	demo_frame : U64,
	ui : Box({ title : Text.Prepared, help : Text.Prepared, palette : Text.Prepared }),
}

program = { init!, update!, render! }

grid_side : U64
grid_side = 16

canvas_x : F32
canvas_x = 72

canvas_y : F32
canvas_y = 72

cell_size : F32
cell_size = 28

canvas_size : F32
canvas_size = U64.to_f32(grid_side) * cell_size

canvas_bounds : Math.Rect
canvas_bounds = Math.rect(canvas_x, canvas_y, canvas_size, canvas_size)

demo_frames : U64
demo_frames = 100

record_demo_flag : Str
record_demo_flag = "--record-demo"

generated_assets_config : List(Str) -> App.Config
generated_assets_config = |args| {
	base = App.default.with_title("RocRay Pixel Workshop").with_frame_pacing(Capped(120))

	if List.contains(args, record_demo_flag) {
		base
			.with_visible(Bool.False)
			.with_output_dir("examples/gallery")
			.with_recording(
				Capture.default
					.with_path("generated_assets.gif")
					.with_format(Gif)
					.with_fps(25)
					.with_max_frames(demo_frames)
					.with_scale(Half)
					.with_timing(FixedStep),
			)
	} else {
		base
	}
}

## The brush is quiet next to the tone it is generated from. Named once, because
## every `Play` edit has to state it: a `Playback` carries volume, pitch, and pan
## together, so a stroke that names only its pitch would play at full volume.
paint_volume : F32
paint_volume = 0.35

palette_color : U64 -> Color.Rgba
palette_color = |index|
	match index {
		0 => Color.from_hex_rgb(0x17202a)
		1 => Color.from_hex_rgb(0x2f80ed)
		2 => Color.from_hex_rgb(0xf9c74f)
		_ => Color.from_hex_rgb(0xf94144)
	}

initial_pixels : List(Color.Rgba)
initial_pixels = List.map_with_index(
	List.repeat(Color.from_hex_rgb(0xf3f0e8), grid_side * grid_side),
	|_color, index| {
		row = index // grid_side
		col = index % grid_side
		if row == col or row + col == grid_side - 1 {
			Color.from_hex_rgb(0x2f80ed)
		} else if row >= 6 and row <= 9 and col >= 6 and col <= 9 {
			Color.from_hex_rgb(0xf9c74f)
		} else {
			Color.from_hex_rgb(0xf3f0e8)
		}
	},
)

init! : App.Init(Model, [PixelCountMismatch, ResourceLimit, SoundGenerationFailed, TextureGenerationFailed])
init! = App.init_for_args(
	generated_assets_config,
	|startup| {
		font = Draw.default_font!()
		texture = Assets.generate_color_texture!({ width: 16, height: 16, color: Color.white })?
		Assets.update_texture!(texture, initial_pixels)?
		Assets.set_texture_filter!(texture, Point)
		Assets.set_texture_wrap!(texture, Clamp)
		paint_sound = Audio.gen_tone!({ freq: 520, ms: 35 })?
		Ok({
			texture,
			pixels: initial_pixels,
			paint_sound,
			palette: 1,
			last_cell: Idle,
			mouse: { x: 0, y: 0 },
			demo: List.contains(App.args!(startup), record_demo_flag),
			demo_frame: 0,
			ui: Box.box({
				title: Text.from("Pixel Workshop", font).size(26).prepare!()?,
				help: Text.from("Drag to paint  |  1-4 pick a colour  |  C restores the design  |  ESC quits", font).size(14).prepare!()?,
				palette: Text.from("Palette", font).size(22).prepare!()?,
			}),
		})
	},
)

palette_from_input : U64, Devices.Snapshot -> U64
palette_from_input = |current, input|
	if input.key_pressed(Key1) 0 else if input.key_pressed(Key2) 1 else if input.key_pressed(Key3) 2 else if input.key_pressed(Key4) 3 else current

## Paints a deterministic ribbon through the editor's normal device-input
## path, changing colour as it crosses each quarter of the grid.
demo_input : U64 -> Devices.Snapshot
demo_input = |frame| {
	cell = frame % (grid_side * grid_side)
	row = cell // grid_side
	zigzag_col = cell % grid_side
	col = if row % 2 == 0 zigzag_col else grid_side - 1 - zigzag_col
	point = {
		x: canvas_x + (U64.to_f32(col) + 0.5) * cell_size,
		y: canvas_y + (U64.to_f32(row) + 0.5) * cell_size,
	}
	palette_key = match (frame // 25) % 4 {
		0 => Key2
		1 => Key3
		2 => Key4
		_ => Key1
	}

	Devices.none
		.with_mouse_position(point)
		.with_mouse_button_down(Left)
		.with_key_pressed(palette_key)
}

cell_at : Math.Vec2 -> Try(U64, [Outside])
cell_at = |point| {
	if !(canvas_bounds.contains(point)) {
		Err(Outside)
	} else {
		column = F32.to_u64_try((point.x - canvas_x) / cell_size)
		row = F32.to_u64_try((point.y - canvas_y) / cell_size)
		match (column, row) {
			(Ok(col), Ok(line)) =>
				if col < grid_side and line < grid_side Ok(line * grid_side + col) else Err(Outside)
			_ => Err(Outside)
		}
	}
}

## A step of the editor: the canvas it produced, and the work that makes the
## canvas visible and audible.
##
## The pixels live in the model and on the GPU, so every branch that changes them
## has to emit the matching upload; returning both together is what keeps the
## two from drifting apart. The edits are data so the editor stays pure;
## `update!` performs them.
Edit : [
	Upload(List(Color.Rgba)),
	UploadRegion(Assets.Region),
	Play(Audio.Playback),
]

Edited : {
	model : Model,
	edits : List(Edit),
}

update_editor : Model, Devices.Snapshot -> Edited
update_editor = |model, input| {
	palette = palette_from_input(model.palette, input)
	base = { ..model, palette }

	if input.key_pressed(KeyC) {
		{
			model: { ..base, pixels: initial_pixels, last_cell: Idle },
			edits: [
				Upload(initial_pixels),
				paint(base.paint_sound, 0.7),
			],
		}
	} else if input.mouse.button_down(Left) {
		match cell_at(input.mouse.position()) {
			Err(_) => { model: { ..base, last_cell: Idle }, edits: [] }
			Ok(index) =>
				if base.last_cell == Painted(index) {
					{ model: base, edits: [] }
				} else {
					match base.pixels.set(index, palette_color(palette)) {
						Err(_) => { model: base, edits: [] }
						Ok(pixels) => {
							{
								model: { ..base, pixels, last_cell: Painted(index) },
								edits: [
									# One cell changed, so one cell is uploaded.
									# Re-uploading the whole canvas would send
									# 256 pixels to say something about one.
									UploadRegion({
										x: U64.to_i32_wrap(index % grid_side),
										y: U64.to_i32_wrap(index // grid_side),
										width: 1,
										height: 1,
										pixels: [palette_color(palette)],
									}),
									paint(base.paint_sound, 0.8 + U64.to_f32(palette) * 0.18),
								],
							}
						}
					}
				}
			}
	} else {
		{ model: { ..base, last_cell: Idle }, edits: [] }
	}
}

## One brush stroke, at the pitch this stroke chose.
##
## Pitch and playback travel as a single `Playback`, so a stroke can no longer be
## heard at the previous stroke's pitch.
paint : Audio.Sound, F32 -> Edit
paint = |sound, pitch|
	Play(sound.playback().with_volume(paint_volume).with_pitch(pitch))

## The shared surface palette for the workshop's chrome. The four paint
## colours are the artwork; everything around them stays quiet.
theme : { bg : Color.Rgba, panel : Color.Rgba, edge : Color.Rgba, ink : Color.Rgba, muted : Color.Rgba, faint : Color.Rgba, accent : Color.Rgba }
theme = {
	bg: Color.from_hex_rgb(0x0e1420),
	panel: Color.from_hex_rgb(0x161f31),
	edge: Color.from_hex_rgb(0x25314b),
	ink: Color.from_hex_rgb(0xe6ecf5),
	muted: Color.from_hex_rgb(0x8fa0bd),
	faint: Color.from_hex_rgb(0x5c6b87),
	accent: Color.from_hex_rgb(0x4c8dff),
}

## Where one palette swatch sits, so the drawing and the hover test agree.
swatch_bounds : U64 -> Math.Rect
swatch_bounds = |index| Math.rect(610, 180 + U64.to_f32(index) * 70, 118, 50)

draw_swatch! : Draw.Frame, U64, U64, Math.Vec2 => {}
draw_swatch! = |frame, index, selected, mouse| {
	bounds = swatch_bounds(index)
	chosen = index == selected
	hovered = bounds.contains(mouse)
	edge = if chosen Color.white else if hovered Color.with_alpha(Color.white, 150) else theme.edge
	# The selected swatch gets a lit ring outside it as well as a bright edge,
	# so which colour the brush carries survives a glance.
	if chosen {
		frame.rounded_rectangle!({ x: bounds.x - 5, y: bounds.y - 5, width: bounds.width + 10, height: bounds.height + 10, radius: 11, segments: 8, style: Draw.outlined(theme.accent, 2) })
	}
	frame.rounded_rectangle!({ x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height, radius: 8, segments: 8, style: Draw.filled_and_outlined(palette_color(index), edge, if chosen 3 else 2) })
	frame.text_centered!({ pos: { x: 752, y: bounds.y + 25 }, text: U64.to_str(index + 1), size: 20, color: if chosen theme.ink else theme.faint })
}

## Perform one edit. A mismatched upload is a programmer error -- the editor
## built pixels that do not fit the texture it also built -- so it stops the app
## rather than becoming a state the model has to carry.
perform_edit! : Assets.Texture, Edit => {}
perform_edit! = |texture, edit| {
	result =
		match edit {
			Upload(pixels) => Assets.update_texture!(texture, pixels)
			UploadRegion(region) => Assets.update_texture_region!(texture, region)
			Play(playback) => {
				playback.play!()
				Ok({})
			}
		}
	match result {
		Ok({}) => {}
		Err(_) => crash "generated_assets: a texture upload did not fit its texture"
	}
}

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = if model.demo demo_input(model.demo_frame) else program_input.devices

	next = update_editor(model, input)
	for edit in next.edits {
		perform_edit!(next.model.texture, edit)
	}

	mouse = input.mouse.position()
	Mouse.set_cursor!(
		match cell_at(mouse) {
			Ok(_) => Crosshair
			Err(_) => Arrow
		},
	)

	exit =
		if model.demo {
			match program_input.capture {
				Finished(_) => Err(Exit(0))
				Failed(_) => Err(Exit(1))
				_ => Ok({})
			}
		} else if input.key_pressed(KeyEscape) {
			Err(Exit(0))
		} else {
			Ok({})
		}

	match exit {
		Err(code) => Err(code)
		Ok({}) => Ok({ ..next.model, mouse, demo_frame: model.demo_frame + 1 })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	ui = Box.unbox(model.ui)

	frame.clear!(theme.bg)
	ui.title.draw!(frame, { pos: { x: canvas_x, y: 12 }, color: theme.ink, align: Text.align_top_left })
	frame.text_at!({ pos: { x: canvas_x, y: 42 }, text: "Canvas, palette and brush sound all generated at startup", size: 13, color: theme.muted })

	# A card under the canvas, so the pixel art sits on a surface instead of
	# floating on the background.
	frame.rounded_rectangle!({ x: canvas_bounds.x - 14, y: canvas_bounds.y - 14, width: canvas_bounds.width + 28, height: canvas_bounds.height + 28, radius: 12, segments: 8, style: Draw.filled_and_outlined(theme.panel, theme.edge, 1) })
	frame.texture!({
		texture: model.texture,
		source: { x: 0, y: 0, width: model.texture.width, height: model.texture.height },
		dest: canvas_bounds,
		origin: Math.zero,
		rotation: 0,
		tint: Color.white,
	})
	frame.rectangle!({ x: canvas_bounds.x - 2, y: canvas_bounds.y - 2, width: canvas_bounds.width + 4, height: canvas_bounds.height + 4, style: Draw.outlined(theme.edge, 2) })

	match cell_at(model.mouse) {
		Err(_) => {}
		Ok(index) => {
			col = index % grid_side
			row = index // grid_side
			frame.rectangle!({ x: canvas_x + U64.to_f32(col) * cell_size, y: canvas_y + U64.to_f32(row) * cell_size, width: cell_size, height: cell_size, style: Draw.outlined(Color.white, 2) })
		}
	}

	frame.rounded_rectangle!({ x: 594, y: 108, width: 150, height: 348, radius: 12, segments: 8, style: Draw.filled_and_outlined(theme.panel, theme.edge, 1) })
	ui.palette.draw!(frame, { pos: { x: 610, y: 126 }, color: theme.ink, align: Text.align_top_left })
	draw_swatch!(frame, 0, model.palette, model.mouse)
	draw_swatch!(frame, 1, model.palette, model.mouse)
	draw_swatch!(frame, 2, model.palette, model.mouse)
	draw_swatch!(frame, 3, model.palette, model.mouse)
	ui.help.draw!(frame, { pos: { x: canvas_x, y: 562 }, color: theme.faint, align: Text.align_top_left })

	Ok({})
}

## Every swatch stays inside the palette panel, which is what makes the hover
## test against the same rectangle honest.
expect swatch_bounds(0).x >= 594 and swatch_bounds(3).y + swatch_bounds(3).height <= 456

expect palette_from_input(0, Devices.none.with_key_pressed(Key3)) == 2
expect palette_from_input(2, Devices.none) == 2

## The canvas maps the pointer to a cell index; anything off it is `Outside`,
## which is also what switches the cursor back to an arrow.
expect cell_at({ x: canvas_x + cell_size * 1.5, y: canvas_y + cell_size * 2.5 }) == Ok(2 * grid_side + 1)
expect cell_at({ x: canvas_x - 1, y: canvas_y }) == Err(Outside)
expect cell_at({ x: canvas_x + canvas_size, y: canvas_y }) == Err(Outside)
