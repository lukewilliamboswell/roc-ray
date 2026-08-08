app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.9.0/3sKTYuHvxSV77dDyZrxuUYgfrAarL6ZtasWMPeH32udh.tar.zst" }

import rr.App
import rr.Color
import rr.Draw
import rr.Math
import rr.Program

Model : {
	target : Draw.RenderTexture,
	shader : Draw.Shader,
	time : Draw.F32Uniform,
}

program = { init!, update, render! }

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

## The shader clock is the only state this example advances, and the step
## carries it -- so the uniform write is returned as an action rather than done
## mid-draw. Actions are applied before `render!` runs, so the shader still sees
## this frame's clock.
update : Model, Program.Step -> Try(Program.Next(Model), [Exit(I64), ..])
update = |model, step|
	Ok({
		model: model,
		actions: [model.time.set(U64.to_f32(step.time.timestamp_nanos) / 1_000_000_000)],
		tasks: [],
	})

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ScopeUnavailable, ..])
render! = |model, frame| {
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
					Ok({})
				},
			)?
			Ok({})
		},
	)?

	target_draw = {
		texture: model.target.texture(),
		source: model.target.source(),
		dest: Math.rect(0, 0, screen_w, screen_h),
		origin: Math.zero,
		rotation: 0,
		tint: Color.white,
	}

	frame.clear!(Color.black)
	frame.with_shader!(
		model.shader,
		|shader_frame| {
			shader_frame.texture!(target_draw)
			Ok({})
		},
	)?

	Ok({})
}
