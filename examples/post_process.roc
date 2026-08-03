app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.8.3/E6ZmC6ZncTVFG875Xsf6jP2GuZCtLnncQ1YwVwKtT2J4.tar.zst" }

import rr.App
import rr.Color
import rr.Draw
import rr.Host
import rr.Math

Model : {
	target : Draw.RenderTexture,
	shader : Draw.Shader,
	time : Draw.Uniform,
}

program = { init!, render! }

screen_w : F32
screen_w = 800

screen_h : F32
screen_h = 600

init! : App.Init(Model, [RenderTextureLoadFailed, ShaderLoadFailed, UniformNotFound])
init! = App.init(
	{ ..App.default, title: "RocRay Offscreen Post-processing" },
	|_host| {
		target = Draw.load_render_texture!({ width: 800, height: 600 })?
		shader = Draw.load_shader!({ vertex_path: "", fragment_path: "examples/assets/post_process.fs" })?
		time = Draw.uniform!(shader, "time")?
		Ok({ target, shader, time })
	},
)

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	seconds = U64.to_f32(host.timestamp_nanos) / 1_000_000_000
	Draw.set_uniform_f32!(model.time, seconds)

	Draw.with_render_texture!(
		model.target,
		|| {
			Draw.clear!(Color.from_hex_rgb(0x10162f))
			Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 120 }, text: "offscreen + shader", size: 48, color: Color.ray_white })
			Draw.with_blend_mode!(
				Draw.additive_blend,
				|| {
					Draw.circle!({ center: { x: 330, y: 330 }, radius: 120, style: Draw.filled(Color.with_alpha(Color.blue, 180)) })
					Draw.circle!({ center: { x: 470, y: 330 }, radius: 120, style: Draw.filled(Color.with_alpha(Color.red, 180)) })
				},
			)
		},
	)

	target_draw = {
		texture: Draw.render_texture(model.target),
		source: Draw.render_texture_source(model.target),
		dest: Math.rect(0, 0, screen_w, screen_h),
		origin: Math.zero,
		rotation: 0,
		tint: Color.white,
	}

	Draw.draw!(
		Color.black,
		|| Draw.with_shader!(model.shader, || Draw.texture!(target_draw)),
	)

	Ok(model)
}
