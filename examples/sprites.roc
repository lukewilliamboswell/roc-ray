app [Model, program] { rr: platform "../platform/main-default.roc" }

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

init! : App.Init(Model, [ResourceLimit, TextureLoadFailed])
init! = App.init(
	App.title("RocRay Sprites").then(App.frame_pacing(Capped(120))).config(),
	|_host| {
		texture = Assets.Texture.load!(asset_path)?
		Ok({ texture, angle: 0, animation: Sprite.animation({ frame_count: 4, fps: 6 }) })
	},
)

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, host, frame| {
	next_angle = model.angle + host.frame_time * 60
	next_animation = Sprite.step(model.animation, host.frame_time)
	frame_row = next_animation.frame // 2
	frame_col = next_animation.frame % 2
	frame_source = Sprite.sheet_frame({ frame_size: { x: 4, y: 4 }, row: frame_row, col: frame_col })

	main_sprite = Sprite.from_texture(model.texture)
		.source(
			frame_source,
		)
		.pos(
			{ x: screen_w * 0.5, y: 260 },
		)
		.scale(
			18,
		)
		.centered()
		.rotation(
			next_angle,
		)

	top_left = Sprite.from_texture(model.texture)
		.source(
			Sprite.sheet_frame({ frame_size: { x: 4, y: 4 }, row: 0, col: 0 }),
		)
		.pos(
			{ x: 90, y: 395 },
		)
		.scale(
			24,
		)

	bottom_right = Sprite.from_texture(model.texture)
		.source(
			Sprite.sheet_frame({ frame_size: { x: 4, y: 4 }, row: 1, col: 1 }),
		)
		.pos(
			{ x: screen_w - 138, y: 443 },
		)
		.scale(
			24,
		)
		.centered()
		.rotation(
			next_angle * -1.5,
		)
		.tint(
			Color.with_alpha(Color.purple, 210),
		)

	frame.clear!(Color.ray_white)
	main_sprite.draw!(frame)
	top_left.draw!(frame)
	bottom_right.draw!(frame)
	frame.text!({ pos: { x: screen_w * 0.5, y: 52 }, text: "Sprites", size: 42, spacing: Draw.default_spacing, color: Color.dark_gray, font: Draw.default_font, align: Draw.align_top_center })
	frame.text!({ pos: { x: 90, y: 504 }, text: "source rect", size: 20, spacing: Draw.default_spacing, color: Color.gray, font: Draw.default_font, align: Draw.align_top_left })
	frame.text!({ pos: { x: screen_w - 90, y: 504 }, text: "rotation + tint", size: 20, spacing: Draw.default_spacing, color: Color.gray, font: Draw.default_font, align: Draw.align_top_right })

	Ok({ ..model, angle: next_angle, animation: next_animation })
}
