app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Math

Model : {
	target : Draw.RenderTexture,
	shader : Draw.Shader,

	## The uniform's location, resolved once, and the value to write into it.
	## The value lives in the model because `update` computes it; the write
	## happens in `render!` because a uniform is a statement about the draws
	## that follow it, and only `render!` knows where those are.
	time_uniform : Draw.F32Uniform,
	seconds : F32,
}

program = { init!, update, render! }

init! : App.Init(Model, _)
init! = App.init(
	App.default.with_title("RocRay Offscreen Post-processing"),
	|_host| {

		## This source tree example deliberately opts into CWD-relative assets.
		## Packaged applications normally use `Assets.beside_executable("assets")`.
		assets = Assets.Store.open!(Assets.working_directory("examples/post_process/assets"))?
		target = Draw.RenderTexture.load!({ width: 800, height: 600 })?
		shader = Draw.Shader.from_store!(assets, { vertex_path: "", fragment_path: "post_process.fs" })?
		time_uniform = shader.uniform_f32!("time")?
		Ok({ target, shader, time_uniform, seconds: 0 })
	},
)

## The shader clock is the only state this example advances, and the input
## carries it, so `update` reads it off the input and stores it. Writing it into
## the shader is `render!`'s job: the uniform only means anything relative to
## the draws it precedes.
Msg : []

update : Model, App.Input(Msg) -> App.Transition(Model, Msg)
update = |model, program_input|
	App.next({ ..model, seconds: U64.to_f32(program_input.time.simulation_nanos) / 1_000_000_000 })

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ScopeUnavailable, ..])
render! = |model, frame| {
	frame.with_render_texture!(
		model.target,
		|target_frame| {
			# `size!` follows the target, not the window: inside this scope it
			# is the 800x600 framebuffer these coordinates are relative to.
			offscreen = target_frame.size!()
			target_frame.clear!(Color.from_hex_rgb(0x10162f))
			target_frame.text_centered!({ pos: { x: offscreen.width * 0.5, y: 120 }, text: "offscreen + shader", size: 48, color: Color.ray_white })
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

	# Out here the same call answers for the window, which is what the offscreen
	# pass is being stretched across.
	window = frame.size!()
	target_draw = {
		texture: model.target.texture(),
		source: model.target.source(),
		dest: Math.rect(0, 0, window.width, window.height),
		origin: Math.zero,
		rotation: 0,
		tint: Color.white,
	}

	frame.clear!(Color.black)
	frame.with_shader!(
		model.shader,
		|shader_frame| {
			# Inside the scope and before the draw it applies to, which is the
			# whole reason this is here rather than in an command list.
			model.time_uniform.set!(model.seconds)
			shader_frame.texture!(target_draw)
			Ok({})
		},
	)?

	Ok({})
}
