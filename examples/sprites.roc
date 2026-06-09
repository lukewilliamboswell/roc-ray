app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Host
import rr.Math

Model : {
	texture : Assets.Texture,
	angle : F32,
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
			Ok(texture) => Ok({ texture, angle: 0 })
			Err(_) => Err(Exit(1))
		}
	},
)

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	next_angle = model.angle + host.frame_time * 60

	main_builder = Draw.TextureDrawBuilder.map2(
		Draw.TextureDrawBuilder.pos({ x: screen_w * 0.5, y: 260 }),
		Draw.TextureDrawBuilder.map2(
			Draw.TextureDrawBuilder.scale(18),
			Draw.TextureDrawBuilder.map2(
				Draw.TextureDrawBuilder.origin_center,
				Draw.TextureDrawBuilder.rotation(next_angle),
				|_, _| {},
			),
			|_, _| {},
		),
		|_, _| {},
	)
	main_sprite = Draw.TextureDrawBuilder.run(main_builder, model.texture)

	top_left = {
		texture: model.texture,
		source: Math.rect(0, 0, 4, 4),
		dest: Math.rect(90, 395, 96, 96),
		origin: Math.zero,
		rotation: 0,
		tint: Color.white,
	}

	bottom_right = {
		texture: model.texture,
		source: Math.rect(4, 4, 4, 4),
		dest: Math.rect(screen_w - 186, 395, 96, 96),
		origin: { x: 48, y: 48 },
		rotation: next_angle * -1.5,
		tint: Color.with_alpha(Color.purple, 210),
	}

	Draw.draw!(
		Color.ray_white,
		|| {
			Draw.texture!(main_sprite)
			Draw.draw_texture!(top_left)
			Draw.draw_texture!(bottom_right)
			Draw.text!({ pos: { x: screen_w * 0.5, y: 52 }, text: "Sprites", size: 42, spacing: Draw.default_spacing, color: Color.dark_gray, font: Draw.default_font, align: Draw.align_top_center })
			Draw.text!({ pos: { x: 90, y: 504 }, text: "source rect", size: 20, spacing: Draw.default_spacing, color: Color.gray, font: Draw.default_font, align: Draw.align_top_left })
			Draw.text!({ pos: { x: screen_w - 90, y: 504 }, text: "rotation + tint", size: 20, spacing: Draw.default_spacing, color: Color.gray, font: Draw.default_font, align: Draw.align_top_right })
		},
	)

	Ok({ texture: model.texture, angle: next_angle })
}
