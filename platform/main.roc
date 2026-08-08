platform ""
	requires {
		[Model : model] for program : {
			init! : {
				config : App.Config,
				run! : Host => Try(model, [Exit(I64), ..]),
			},
			update : model, Program.Step -> Try(Program.Next(model), [Exit(I64), ..]),
			render! : model, Draw.Frame => Try({}, [Exit(I64), ..]),
		}
	}
	exposes [Draw, Text, Color, Host, Keys, Mouse, Gamepad, Time, Audio, App, Assets, Math, Camera, Sprite, Tilemap, Physics, Capture, Program, Random]
	packages {
		rrt: "../types/main.roc",
	}
	provides {
		"app_config_for_host": app_config_for_host!,
		"init_for_host": init_for_host!,
		"update_for_host": update_for_host!,
		"render_for_host": render_for_host!,
		"drop_model_for_host": drop_model_for_host!,
	}
	hosted {
		"roc_assets_load_texture_raw": AssetsHost.load_texture!,
		"roc_assets_generate_color_texture_raw": AssetsHost.generate_color_texture!,
		"roc_assets_generate_checked_texture_raw": AssetsHost.generate_checked_texture!,
		"roc_assets_update_texture_raw": AssetsHost.update_texture!,
		"roc_assets_set_texture_filter_raw": AssetsHost.set_texture_filter!,
		"roc_assets_set_texture_wrap_raw": AssetsHost.set_texture_wrap!,
		"roc_audio_gen_tone_raw": AudioHost.gen_tone!,
		"roc_audio_gen_sound_raw": AudioHost.gen_sound!,
		"roc_audio_load_sound_raw": AudioHost.load_sound!,
		"roc_audio_load_music_raw": AudioHost.load_music!,
		"roc_audio_play_raw": AudioHost.play_sound!,
		"roc_audio_stop_raw": AudioHost.stop_sound!,
		"roc_audio_pause_raw": AudioHost.pause_sound!,
		"roc_audio_resume_raw": AudioHost.resume_sound!,
		"roc_audio_is_playing_raw": AudioHost.is_sound_playing!,
		"roc_audio_set_volume_raw": AudioHost.set_sound_volume!,
		"roc_audio_set_pitch_raw": AudioHost.set_sound_pitch!,
		"roc_audio_set_pan_raw": AudioHost.set_sound_pan!,
		"roc_audio_play_music_raw": AudioHost.play_music!,
		"roc_audio_stop_music_raw": AudioHost.stop_music!,
		"roc_audio_pause_music_raw": AudioHost.pause_music!,
		"roc_audio_resume_music_raw": AudioHost.resume_music!,
		"roc_audio_set_music_volume_raw": AudioHost.set_music_volume!,
		"roc_audio_set_music_pitch_raw": AudioHost.set_music_pitch!,
		"roc_audio_set_music_pan_raw": AudioHost.set_music_pan!,
		"roc_audio_set_music_looping_raw": AudioHost.set_music_looping!,
		"roc_audio_is_music_playing_raw": AudioHost.is_music_playing!,
		"roc_audio_seek_music_raw": AudioHost.seek_music!,
		"roc_audio_music_length_raw": AudioHost.music_length!,
		"roc_audio_music_time_played_raw": AudioHost.music_time_played!,
		"roc_audio_set_master_volume_raw": AudioHost.set_master_volume!,
		"roc_draw_begin_scissor_raw": DrawHost.begin_scissor!,
		"roc_draw_circle_gradient": DrawHost.circle_gradient!,
		"roc_draw_circle_lines_raw": DrawHost.circle_lines!,
		"roc_draw_circle_raw": DrawHost.circle!,
		"roc_draw_clear": DrawHost.clear!,
		"roc_draw_draw_texture_raw": DrawHost.draw_texture!,
		"roc_draw_draw_texture_quad_raw": DrawHost.draw_texture_quad!,
		"roc_draw_end_scissor_raw": DrawHost.end_scissor!,
		"roc_draw_fps": DrawHost.fps!,
		"roc_draw_line_raw": DrawHost.line!,
		"roc_draw_load_font_raw": DrawHost.load_font!,
		"roc_draw_measure_text_raw": DrawHost.measure_text!,
		"roc_draw_prepare_text_raw": DrawHost.prepare_text!,
		"roc_draw_draw_prepared_text_raw": DrawHost.draw_prepared_text!,
		"roc_draw_polygon_lines_raw": DrawHost.polygon_lines!,
		"roc_draw_polygon_raw": DrawHost.polygon!,
		"roc_draw_rectangle_gradient_h": DrawHost.rectangle_gradient_h!,
		"roc_draw_rectangle_gradient_v": DrawHost.rectangle_gradient_v!,
		"roc_draw_rectangle_lines_raw": DrawHost.rectangle_lines!,
		"roc_draw_rectangle_raw": DrawHost.rectangle!,
		"roc_draw_rounded_rectangle_lines_raw": DrawHost.rounded_rectangle_lines!,
		"roc_draw_rounded_rectangle_raw": DrawHost.rounded_rectangle!,
		"roc_draw_text_aligned_raw": DrawHost.text_aligned!,
		"roc_draw_text_raw": DrawHost.text!,
		"roc_draw_triangle_lines_raw": DrawHost.triangle_lines!,
		"roc_draw_triangle_raw": DrawHost.triangle!,
		"roc_capture_screenshot": CaptureHost.screenshot!,
		"roc_capture_set_virtual_mouse": CaptureHost.set_virtual_mouse!,
		"roc_capture_start_recording": CaptureHost.start_recording!,
		"roc_capture_stop_recording": CaptureHost.stop_recording!,
		"roc_capture_recording_status": CaptureHost.recording_status!,
		"roc_host_exit": HostHost.exit!,
		"roc_host_get_clipboard_text": HostHost.get_clipboard_text!,
		"roc_host_random_i32": HostHost.random_i32!,
		"roc_host_read_env": HostHost.read_env!,
		"roc_host_read_file_raw": HostHost.read_file!,
		"roc_host_set_clipboard_text": HostHost.set_clipboard_text!,
		"roc_host_set_exit_key": HostHost.set_exit_key!,
		"roc_host_set_screen_size": HostHost.set_screen_size!,
		"roc_host_set_target_fps": HostHost.set_target_fps!,
		"roc_host_set_window_min_size": HostHost.set_window_min_size!,
		"roc_mouse_set_cursor_mode_raw": MouseHost.set_cursor_mode!,
		"roc_mouse_set_cursor_raw": MouseHost.set_cursor!,
		"roc_tilemap_load_tmx_raw": TilemapHost.load_tmx!,
		"roc_tilemap_draw_raw": TilemapHost.draw!,
		"roc_draw_begin_camera": DrawHost.begin_camera!,
		"roc_draw_begin_blend_raw": DrawHost.begin_blend!,
		"roc_draw_begin_render_texture_raw": DrawHost.begin_render_texture!,
		"roc_draw_begin_shader_raw": DrawHost.begin_shader!,
		"roc_draw_end_camera": DrawHost.end_camera!,
		"roc_draw_end_blend_raw": DrawHost.end_blend!,
		"roc_draw_end_render_texture_raw": DrawHost.end_render_texture!,
		"roc_draw_end_shader_raw": DrawHost.end_shader!,
		"roc_draw_load_render_texture_raw": DrawHost.load_render_texture!,
		"roc_draw_load_shader_raw": DrawHost.load_shader!,
		"roc_draw_load_shader_source_raw": DrawHost.load_shader_source!,
		"roc_draw_shader_location_raw": DrawHost.shader_location!,
		"roc_draw_set_shader_float_raw": DrawHost.set_shader_float!,
		"roc_draw_set_shader_int_raw": DrawHost.set_shader_int!,
		"roc_draw_set_shader_texture_raw": DrawHost.set_shader_texture!,
		"roc_draw_set_shader_vec2_raw": DrawHost.set_shader_vec2!,
		"roc_draw_set_shader_vec3_raw": DrawHost.set_shader_vec3!,
		"roc_draw_set_shader_vec4_raw": DrawHost.set_shader_vec4!,
	}
	targets: {
		inputs_dir: "targets/",
		x64mac: { inputs: ["libhost.a", "libraylib.a", "libmsf_gif.a", "libvpx.a", app] },
		arm64mac: { inputs: ["libhost.a", "libraylib.a", "libmsf_gif.a", "libvpx.a", app] },
		x64glibc: { inputs: ["Scrt1.o", "crti.o", "libhost.a", "libraylib.a", "libmsf_gif.a", "libvpx.a", "libm.so", "libX11.so", app, "libc.so", "crtn.o"] },
		x64win: { inputs: ["host.lib", "raylib.lib", "msf_gif.lib", "vpx.lib", "gdi32.lib", "user32.lib", "winmm.lib", "opengl32.lib", "shell32.lib", app] },
	}

import Draw
import DrawHost
import Text
import Color
import Host
import HostHost
import Keys
import Mouse
import MouseHost
import Gamepad
import Time
import Audio
import AudioHost
import App
import AppConfig
import Capture
import CaptureHost
import Assets
import AssetsHost
import Math
import Camera
import Sprite
import Tilemap
import TilemapHost
import Physics
import Program
import Random

## Internal type for host boundary.
## Keep this layout-compatible with the public Host record; the compiler may
## optimize the reshaping below into a direct pass-through.
HostStateFromHost : {
	frame_count : U64,
	timestamp_nanos : U64, ## monotonic clock, nanoseconds since window init
	frame_time : F32, ## seconds since previous frame (0 on first frame)
	screen : { width : I32, height : I32 }, ## logical drawing size for this frame
	keys : List(U8), ## 349 packed state bytes, one per raylib key code 0-348
	text_input : List(U32), ## Unicode codepoints entered this frame
	gamepads : {
		available : List(U8), ## 4 availability bytes
		buttons : List(U8), ## 4 * 18 packed button-state bytes
		axes : List(F32), ## 4 * 6 sampled axis values
	},
	mouse : {
		buttons : List(U8), ## 7 packed state bytes, one per raylib mouse button code 0-6
		left : Bool,
		middle : Bool,
		right : Bool,
		wheel : F32,
		wheel_x : F32,
		wheel_y : F32,
		delta_x : F32,
		delta_y : F32,
		x : F32,
		y : F32,
	},
}

## Internal type for the host boundary, carrying one cycle of observations.
##
## Unions do not cross this boundary, so completions and the recording state
## arrive as flat records that `Program` decodes. The completion list is empty
## on an ordinary frame.
StepFromHost : {
	snapshot : HostStateFromHost,
	frame_count : U64,
	timestamp_nanos : U64,
	elapsed_seconds : F32,
	completed : List(Program.CompletionFromHost),
	capture : Program.CaptureFromHost,
}

app_config_for_host! : () => AppConfig.HostConfig
app_config_for_host! = || AppConfig.to_host({}, program.init!.config)

## Reshape the flat host snapshot into the public nested `Host` record.
##
## Only `gamepads.available` is renamed; the compiler may optimize the rest of
## this into a direct pass-through, which is why the two layouts are kept
## deliberately compatible.
host_from_raw : HostStateFromHost -> Host
host_from_raw = |host_state| {
	frame_count: host_state.frame_count,
	timestamp_nanos: host_state.timestamp_nanos,
	frame_time: host_state.frame_time,
	screen: host_state.screen,
	keys: host_state.keys,
	text_input: host_state.text_input,
	gamepads: {
		connected: host_state.gamepads.available,
		buttons: host_state.gamepads.buttons,
		axes: host_state.gamepads.axes,
	},
	mouse: host_state.mouse,
}

## Rebuild a `Program.Step` from the host's flat cycle record.
step_from_raw : StepFromHost -> Program.Step
step_from_raw = |raw| {
	input: host_from_raw(raw.snapshot),
	time: {
		frame_count: raw.frame_count,
		timestamp_nanos: raw.timestamp_nanos,
		elapsed_seconds: raw.elapsed_seconds,
	},
	completed: List.map(raw.completed, Program.completion_from_host),
	capture: Program.capture_from_host(raw.capture),
}

init_for_host! : HostStateFromHost => Try(Box(Model), I64)
init_for_host! = |host_state|
	match (program.init!.run!)(host_from_raw(host_state)) {
		Ok(unboxed_model) => Ok(Box.box(unboxed_model))
		Err(Exit(code)) => Err(code)
		Err(_) => Err(-1)
	}

## Advance the model by one cycle and hand the host back any work it wants done.
##
## Called once per rendered frame rather than once per event, so the model is
## boxed and unboxed once regardless of how much happened.
##
## `program.update` is pure, so the work it asked for is done here instead:
## actions are applied immediately, before this returns and therefore before
## anything is drawn, which is exactly where the effects they replace used to
## run. Only tasks -- the work that answers back -- reach the host.
update_for_host! : Box(Model), StepFromHost => Try({ model : Box(Model), tasks : List(Program.TaskToHost) }, I64)
update_for_host! = |boxed_model, raw|
	match (program.update)(Box.unbox(boxed_model), step_from_raw(raw)) {
		Ok(next) =>
			match run_actions!(next.actions, 0) {
				Ok({}) => Ok({ model: Box.box(next.model), tasks: List.map(next.tasks, Program.to_host) })
				Err(Exit(code)) => Err(code)
				Err(_) => Err(-1)
			}

		Err(Exit(code)) => Err(code)
		Err(_) => Err(-1)
	}

## Apply a cycle's actions in order, stopping at the first one that fails.
##
## Walked by index rather than folded because each step is effectful and may
## fail: `texture.update(pixels)` reports a pixel count that does not match the
## texture, and that has to end the cycle the same way `texture.update!(pixels)?`
## ended it when `update!` was effectful.
run_actions! : List(Program.Action), U64 => Try({}, [PixelCountMismatch, ..])
run_actions! = |actions, index|
	if index >= List.len(actions) {
		Ok({})
	} else {
		match List.get(actions, index) {
			Ok(action) => {
				run_action!(action)?
				run_actions!(actions, index + 1)
			}

			# Unreachable: the index is bounded above.
			Err(_) => Ok({})
		}
	}

## Apply one action through the effect it stands for.
##
## This is the whole reason actions need no wire format: the adapter is itself
## effectful, so it can call the platform's existing effects directly and an
## `Action` never has to flatten to scalars or cross the ABI.
run_action! : Program.Action => Try({}, [PixelCountMismatch, ..])
run_action! = |action|
	match action {
		# Deferred rather than immediate, matching `host.exit!`: the host
		# finishes this cycle -- including the draw, and including capturing it
		# -- and shuts down afterwards. `Err(Exit(code))` from `update` is the
		# immediate form.
		Exit(code) => Ok(HostHost.exit!(I64.to_i32_wrap(code)))
		SetCursor(cursor) => Ok(MouseHost.set_cursor!(Mouse.cursor_code(cursor)))
		SetCursorMode(mode) => Ok(MouseHost.set_cursor_mode!(Host.cursor_mode_code(mode)))
		SetClipboardText(text) => Ok(HostHost.set_clipboard_text!(text))
		SetExitKey(key) => Ok(HostHost.set_exit_key!(Keys.exit_key_code(key)))
		SetWindowMinSize(size) =>
			Ok(
				HostHost.set_window_min_size!({
					width: if size.width > 0 size.width else 0,
					height: if size.height > 0 size.height else 0,
				}),
			)

		PlaySound(settings) => Ok(settings.play!())
		SetMusicVolume(request) => Ok(request.music.set_volume!(request.volume))
		UpdateTexture(request) => request.texture.update!(request.pixels)
		SetShaderF32Uniform(request) => Ok(request.uniform.set!(request.value))
		SetVirtualMouse(pointer) => Ok(Capture.set_virtual_mouse!(pointer))
	}

## Draw the current model, then hand the same box back.
##
## `render!` returns `{}` rather than a model: drawing is a view of state, not a
## step of it, and having it return a model invited the two to be confused.
## Unboxing borrows rather than consumes, so the box the host passed in is still
## the live reference and is returned unchanged.
render_for_host! : Box(Model) => Try(Box(Model), I64)
render_for_host! = |boxed_model| {
	frame = Draw.Frame.from_host(DrawHost.Frame.for_host)
	match (program.render!)(Box.unbox(boxed_model), frame) {
		Ok({}) => Ok(boxed_model)
		Err(Exit(code)) => Err(code)
		Err(_) => Err(-1)
	}
}

## Drop the final boxed model at host shutdown.
##
## The host owns the model box returned by init!/render! and must release it.
## Box refcounting depends on the Model layout (a box whose payload contains
## refcounted fields uses a wider allocation header), which only the compiler
## knows -- so we let Roc drop the box here rather than hand-rolling it in the
## host. Roc takes ownership of the unused arg and decrefs it at scope end.
## TODO: remove once roc glue emits box refcount helpers (roc#9536).
drop_model_for_host! : Box(Model) => {}
drop_model_for_host! = |_boxed_model| {}
