app [Model, program] { rr: platform "../platform/main-default.roc" }

import rr.App
import rr.Color
import rr.Draw
import rr.Host
import rr.Math

Model : {
	target : Draw.RenderTexture,
	shader : Draw.Shader,
	time : Draw.F32Uniform,
}

program = { init!, render! }

screen_w : F32
screen_w = 800

screen_h : F32
screen_h = 600

init! : App.Init(Model, [RenderTextureLoadFailed, ResourceLimit, ShaderLoadFailed, UniformNotFound])
init! = App.init(
	App.default.with_title("RocRay Offscreen Post-processing"),
	|_host| {
		target = Draw.RenderTexture.load!({ width: 800, height: 600 })?
		shader = Draw.Shader.load!({ vertex_path: "", fragment_path: "examples/assets/post_process.fs" })?
		time = shader.uniform_f32!("time")?
		Ok({ target, shader, time })
	},
)

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, host, frame| {
	seconds = U64.to_f32(host.timestamp_nanos) / 1_000_000_000
	model.time.set!(seconds)

	frame.with_render_texture!(
		model.target,
		|target_frame| {
			target_frame.clear!(Color.from_hex_rgb(0x10162f))
			target_frame.text_centered!({ pos: { x: screen_w * 0.5, y: 120 }, text: "offscreen + shader", size: 48, color: Color.ray_white })
			target_frame.with_blend_mode!(
				Draw.additive_blend,
				|blend_frame| {
					blend_frame.circle!({ center: { x: 330, y: 330 }, radius: 120, style: Draw.filled(Color.with_alpha(Color.blue, 180)) })
					blend_frame.circle!({ center: { x: 470, y: 330 }, radius: 120, style: Draw.filled(Color.with_alpha(Color.red, 180)) })
				},
			)
		},
	)

	target_draw = {
		texture: model.target.texture(),
		source: model.target.source(),
		dest: Math.rect(0, 0, screen_w, screen_h),
		origin: Math.zero,
		rotation: 0,
		tint: Color.white,
	}

	frame.clear!(Color.black)
	frame.with_shader!(model.shader, |shader_frame| shader_frame.texture!(target_draw))

	Ok(model)
}
