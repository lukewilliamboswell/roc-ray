## Draw a scene to a texture, then apply a shader that changes the finished
## image before it appears on screen.
##
## Press Escape to quit. This example shows drawing in stages, combining light
## additively, and changing a shader setting before using it.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Math

## State kept between updates: the offscreen drawing target, shader, and its
## prepared time setting, plus the elapsed time that animates the scene. These
## resources are created once and reused for every frame.
Model : {
	target : Draw.RenderTexture,
	shader : Draw.Shader,

	## The uniform's location, resolved once, and the value to write into it.
	## The value lives in the model because `update!` computes it; the write
	## happens in `render!` because a uniform is a statement about the draws
	## that follow it, and only `render!` knows where those are.
	time_uniform : Draw.F32Uniform,
	seconds : F32,
}

program = { init!, update!, render! }

init! : App.Init(Model, _)
init! = App.init(
	App.default.with_title("RocRay Offscreen Post-processing").with_size({ width: 800, height: 600 }),
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

## Nothing here waits, so there is no task to spawn and no message to fold in.
## The shader clock is the only state this example advances, and the input
## carries it, so `update!` reads it off the input and stores it. Writing it into
## the shader is `render!`'s job: the uniform only means anything relative to
## the draws it precedes.
Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input|
	if program_input.devices.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		Ok({ ..model, seconds: U64.to_f32(program_input.time.simulation_nanos) / 1_000_000_000 })
	}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ScopeUnavailable, ..])
render! = |model, frame| {
	frame.with_render_texture!(
		model.target,
		|target_frame| {
			# `size!` follows the target, not the window: inside this scope it
			# is the 800x600 framebuffer these coordinates are relative to.
			offscreen = target_frame.size!()
			center = { x: offscreen.width * 0.5, y: offscreen.height * 0.62 }
			target_frame.rectangle_gradient_v!({ x: 0, y: 0, width: offscreen.width, height: offscreen.height, color_top: Color.from_hex_rgb(0x1a1140), color_bottom: Color.from_hex_rgb(0x060716) })
			target_frame.text_centered!({ pos: { x: center.x, y: 96 }, text: "offscreen + shader", size: 48, color: Color.ray_white })
			target_frame.text_centered!({ pos: { x: center.x, y: 152 }, text: "render texture -> additive blend -> fragment shader   (ESC quits)", size: 18, color: Color.from_hex_rgb(0x9d8fd0) })
			target_frame.with_blend_mode!(
				Draw.additive_blend,
				|blend_frame| {
					# Three lobes on a shared orbit. Additive blending is what
					# turns their overlaps into the bright core in the middle.
					lobe!(blend_frame, center, model.seconds, 0, Color.from_hex_rgb(0x2f6bff))
					lobe!(blend_frame, center, model.seconds, 2.0943952, Color.from_hex_rgb(0xff3366))
					lobe!(blend_frame, center, model.seconds, 4.1887903, Color.from_hex_rgb(0x18d69b))
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
			# whole reason this is here rather than in `update!`.
			model.time_uniform.set!(model.seconds)
			shader_frame.texture!(target_draw)
			Ok({})
		},
	)?

	Ok({})
}

## One orbiting lobe, drawn as a soft radial gradient so the additive overlaps
## fall off smoothly instead of banding at a hard circle edge.
lobe! : Draw.Frame, Math.Vec2, F32, F32, Color.Rgba => {}
lobe! = |frame, center, seconds, phase, color| {
	angle = seconds * 0.7 + phase
	pos = { x: center.x + 110 * F32.cos(angle), y: center.y + 70 * F32.sin(angle * 1.3) }
	frame.circle_gradient!({ center: pos, radius: 150, color_inner: Color.with_alpha(color, 170), color_outer: Color.with_alpha(color, 0) })
}
