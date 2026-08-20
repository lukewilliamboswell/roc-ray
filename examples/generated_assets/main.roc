app [Model, program] {
	rr: platform "../../platform/main.roc",
	roc: "nightly-2026-08-19-edec830",
}

import rr.App
import rr.Assets
import rr.Audio
import rr.Color
import rr.Draw
import rr.Input
import rr.Math
import rr.Mouse
import rr.Program
import rr.Text

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
	ui : Box({ title : Text.Prepared, help : Text.Prepared, palette : Text.Prepared }),
}

program = { init!, update, render! }

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

## The brush is quiet next to the tone it is generated from. Named once because
## `init!` applies it to the sound and every `PlaySound` action carries it again:
## a `Playback` states all three settings, so it would otherwise reset to full
## volume the first time a pitch is chosen.
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

init! : App.Init(Model, [PixelCountMismatch, ResourceLimit, SoundGenerationFailed, TextureGenerationFailed, UploadBudgetExceeded])
init! = App.init(
	App.static_config(App.default.with_title("RocRay Pixel Workshop").with_frame_pacing(Capped(120))),
	|_startup| {
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
			ui: Box.box({
				title: Text.from("Pixel Workshop", font).size(34).prepare!()?,
				help: Text.from("Paint with the mouse | 1-4 palette | C restores the design", font).size(17).prepare!()?,
				palette: Text.from("Palette", font).size(22).prepare!()?,
			}),
		})
	},
)

palette_from_input : U64, Input.Snapshot -> U64
palette_from_input = |current, input|
	if input.key_pressed(Key1) 0 else if input.key_pressed(Key2) 1 else if input.key_pressed(Key3) 2 else if input.key_pressed(Key4) 3 else current

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
## has to emit the matching `UpdateTexture`; returning both together is what keeps
## the two from drifting apart.
Edited : {
	model : Model,
	actions : List(Program.Action),
}

update_editor : Model, Input.Snapshot -> Edited
update_editor = |model, input| {
	palette = palette_from_input(model.palette, input)
	base = { ..model, palette }

	if input.key_pressed(KeyC) {
		{
			model: { ..base, pixels: initial_pixels, last_cell: Idle },
			actions: [
				Assets.update_texture(base.texture, initial_pixels),
				paint(base.paint_sound, 0.7),
			],
		}
	} else if input.mouse.button_down(Left) {
		match cell_at(input.mouse.position()) {
			Err(_) => { model: { ..base, last_cell: Idle }, actions: [] }
			Ok(index) =>
				if base.last_cell == Painted(index) {
					{ model: base, actions: [] }
				} else {
					match base.pixels.set(index, palette_color(palette)) {
						Err(_) => { model: base, actions: [] }
						Ok(pixels) => {
							{
								model: { ..base, pixels, last_cell: Painted(index) },
								actions: [
									# One cell changed, so one cell is uploaded.
									# Re-uploading the whole canvas would send
									# 256 pixels to say something about one.
									Assets.update_texture_region(
										base.texture,
										{
											x: U64.to_i32_wrap(index % grid_side),
											y: U64.to_i32_wrap(index // grid_side),
											width: 1,
											height: 1,
											pixels: [palette_color(palette)],
										},
									),
									paint(base.paint_sound, 0.8 + U64.to_f32(palette) * 0.18),
								],
							}
						}
					}
				}
			}
	} else {
		{ model: { ..base, last_cell: Idle }, actions: [] }
	}
}

## One brush stroke, at the pitch this stroke chose.
##
## Pitch and playback travel as a single `Playback`, so a stroke can no longer be
## heard at the previous stroke's pitch.
paint : Audio.Sound, F32 -> Program.Action
paint = |sound, pitch|
	sound.playback().with_volume(paint_volume).with_pitch(pitch).play()

draw_swatch! : Draw.Frame, U64, U64 => {}
draw_swatch! = |frame, index, selected| {
	y = 180 + U64.to_f32(index) * 70
	frame.rounded_rectangle!({ x: 610, y, width: 118, height: 50, radius: 8, segments: 8, style: Draw.filled_and_outlined(palette_color(index), if index == selected Color.white else Color.with_alpha(Color.white, 45), if index == selected 4 else 2) })
	frame.text_centered!({ pos: { x: 752, y: y + 25 }, text: U64.to_str(index + 1), size: 20, color: Color.light_gray })
}

## A mismatched pixel count is no longer this function's problem: the check
## happens where the upload does, when the platform applies the `UpdateTexture`
## action, and a failure ends the cycle exactly as
## `Assets.update_texture!(texture, pixels)?`
## used to. So the error type is the same one every other example has.
Msg : []

update : Model, Program.Step(Msg) -> Program.Update(Model, Msg)
update = |model, step| {
	input = step.input
	exit_actions = if input.key_pressed(KeyEscape) [Program.exit(0)] else []

	next = update_editor(model, input)
	mouse = input.mouse.position()
	cursor = Mouse.set_cursor(
		match cell_at(mouse) {
			Ok(_) => Crosshair
			Err(_) => Arrow
		},
	)

	Program.static({ ..next.model, mouse })
		.with_actions(exit_actions)
		.with_actions(next.actions)
		.with_action(cursor)
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	ui = Box.unbox(model.ui)

	frame.clear!(Color.from_hex_rgb(0x0e1625))
	ui.title.draw!(frame, { pos: { x: canvas_x, y: 24 }, color: Color.white, align: Text.align_top_left })
	frame.texture!({
		texture: model.texture,
		source: { x: 0, y: 0, width: model.texture.width, height: model.texture.height },
		dest: canvas_bounds,
		origin: Math.zero,
		rotation: 0,
		tint: Color.white,
	})
	frame.rectangle!({ x: canvas_bounds.x - 4, y: canvas_bounds.y - 4, width: canvas_bounds.width + 8, height: canvas_bounds.height + 8, style: Draw.outlined(Color.from_hex_rgb(0x7083a8), 4) })

	match cell_at(model.mouse) {
		Err(_) => {}
		Ok(index) => {
			col = index % grid_side
			row = index // grid_side
			frame.rectangle!({ x: canvas_x + U64.to_f32(col) * cell_size, y: canvas_y + U64.to_f32(row) * cell_size, width: cell_size, height: cell_size, style: Draw.outlined(Color.white, 2) })
		}
	}

	ui.palette.draw!(frame, { pos: { x: 610, y: 126 }, color: Color.white, align: Text.align_top_left })
	draw_swatch!(frame, 0, model.palette)
	draw_swatch!(frame, 1, model.palette)
	draw_swatch!(frame, 2, model.palette)
	draw_swatch!(frame, 3, model.palette)
	ui.help.draw!(frame, { pos: { x: canvas_x, y: 558 }, color: Color.from_hex_rgb(0x91a0bd), align: Text.align_top_left })

	Ok({})
}
