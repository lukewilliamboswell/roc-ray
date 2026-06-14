app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Host
import rr.Sprite

Model : {
	texture : Assets.Texture,
	angle : F32,
	animation : Sprite.Animation,
}

program = { init!, render! }

screen_w : F32
screen_w = 800

screen_h : F32
screen_h = 600

asset_path : Str
asset_path = "examples/assets/checker.bmp"

init! : App.Init(Model)
init! = App.init(
	{
		title: "RocRay Sprites",
		width: 800,
		height: 600,
		target_fps: 120,
		resizable: Bool.False,
		fullscreen: Bool.False,
		vsync: Bool.False,
		cursor_visible: Bool.True,
	},
	|_host| {
		match Assets.load_texture!(asset_path) {
			Ok(texture) => Ok({ texture, angle: 0, animation: Sprite.animation({ frame_count: 4, fps: 6 }) })
			Err(_) => Err(Exit(1))
		}
	},
)

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	next_angle = model.angle + host.frame_time * 60
	next_animation = Sprite.step(model.animation, host.frame_time)
	frame_row = next_animation.frame // 2
	frame_col = next_animation.frame % 2
	frame_source = Sprite.sheet_frame({ frame_size: { x: 4, y: 4 }, row: frame_row, col: frame_col })

	main_sprite = Sprite.with_rotation(
		Sprite.with_origin_center(
			Sprite.with_scale(
				Sprite.with_pos(
					Sprite.with_source(Sprite.from_texture(model.texture), frame_source),
					{ x: screen_w * 0.5, y: 260 },
				),
				18,
			),
		),
		next_angle,
	)

	top_left = Sprite.with_scale(
		Sprite.with_pos(
			Sprite.with_source(Sprite.from_texture(model.texture), Sprite.sheet_frame({ frame_size: { x: 4, y: 4 }, row: 0, col: 0 })),
			{ x: 90, y: 395 },
		),
		24,
	)

	bottom_right = Sprite.with_tint(
		Sprite.with_rotation(
			Sprite.with_origin_center(
				Sprite.with_scale(
					Sprite.with_pos(
						Sprite.with_source(Sprite.from_texture(model.texture), Sprite.sheet_frame({ frame_size: { x: 4, y: 4 }, row: 1, col: 1 })),
						{ x: screen_w - 138, y: 443 },
					),
					24,
				),
			),
			next_angle * -1.5,
		),
		Color.with_alpha(Color.purple, 210),
	)

	Draw.draw!(
		Color.ray_white,
		|| {
			Sprite.draw!(main_sprite)
			Sprite.draw!(top_left)
			Sprite.draw!(bottom_right)
			Draw.text!({ pos: { x: screen_w * 0.5, y: 52 }, text: "Sprites", size: 42, spacing: Draw.default_spacing, color: Color.dark_gray, font: Draw.default_font, align: Draw.align_top_center })
			Draw.text!({ pos: { x: 90, y: 504 }, text: "source rect", size: 20, spacing: Draw.default_spacing, color: Color.gray, font: Draw.default_font, align: Draw.align_top_left })
			Draw.text!({ pos: { x: screen_w - 90, y: 504 }, text: "rotation + tint", size: 20, spacing: Draw.default_spacing, color: Color.gray, font: Draw.default_font, align: Draw.align_top_right })
		},
	)

	Ok({ texture: model.texture, angle: next_angle, animation: next_animation })
}
