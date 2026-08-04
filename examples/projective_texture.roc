app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Host

Model : {
	texture : Assets.Texture,
	quad : Draw.ProjectiveQuad,
}

program = { init!, render! }

init! : App.Init(Model, [ResourceLimit, TextureGenerationFailed, NonFiniteQuad, DegenerateQuad, NonConvexQuad, ProjectiveHorizon])
init! = App.init(
	App.default.with_title("Projective Texture").with_frame_pacing(Capped(120)),
	|_host| {
		texture = Assets.Texture.generate_checked!({
			width: 512,
			height: 512,
			checks_x: 10,
			checks_y: 10,
			color_a: Color.from_hex_rgb(0xd9edf7),
			color_b: Color.from_hex_rgb(0x27445b),
		})?
		texture.set_filter!(Bilinear)
		quad = Draw.ProjectiveQuad.from_corners({
			top_left: { x: 130, y: 90 },
			bottom_left: { x: 75, y: 525 },
			bottom_right: { x: 725, y: 475 },
			top_right: { x: 610, y: 155 },
		})?
		Ok({ texture, quad })
	},
)

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, _host, frame| {
	frame.clear!(Color.from_hex_rgb(0x101827))
	frame.projective_texture!({
		texture: model.texture,
		source: model.texture.rect(),
		quad: model.quad,
		tint: Color.white,
	})
	frame.text_centered!({
		pos: { x: 400, y: 565 },
		text: "Exact planar projection",
		size: 20,
		color: Color.ray_white,
	})
	Ok(model)
}
