platform ""
	requires {
		[Model : model] for program : {
			init! : {
				config : {
					title : Str,
					width : I32,
					height : I32,
					target_fps : I32,
					resizable : Bool,
					fullscreen : Bool,
					vsync : Bool,
					cursor_visible : Bool,
				},
				run! : Host => Try(model, [Exit(I64)]),
			},
			render! : model, Host => Try(model, [Exit(I64), ..]),
		}
	}
	exposes [Draw, Color, Host, Keys, Mouse, Time, Audio, App, Assets, Math, Camera, Sprite, Tilemap, Physics]
	packages {}
	provides {
		"app_config_for_host": app_config_for_host!,
		"init_for_host": init_for_host!,
		"render_for_host": render_for_host!,
		"drop_model_for_host": drop_model_for_host!,
	}
	hosted {
		"roc_assets_load_texture_raw": Assets.load_texture_raw!,
		"roc_audio_gen_tone_raw": Audio.gen_tone_raw!,
		"roc_audio_gen_sound_raw": Audio.gen_sound_raw!,
		"roc_audio_load_sound_raw": Audio.load_sound_raw!,
		"roc_audio_load_music_raw": Audio.load_music_raw!,
		"roc_audio_play_raw": Audio.play_raw!,
		"roc_audio_set_volume_raw": Audio.set_volume_raw!,
		"roc_audio_set_pitch_raw": Audio.set_pitch_raw!,
		"roc_audio_set_pan_raw": Audio.set_pan_raw!,
		"roc_audio_play_music_raw": Audio.play_music_raw!,
		"roc_audio_stop_music_raw": Audio.stop_music_raw!,
		"roc_audio_pause_music_raw": Audio.pause_music_raw!,
		"roc_audio_resume_music_raw": Audio.resume_music_raw!,
		"roc_audio_set_music_volume_raw": Audio.set_music_volume_raw!,
		"roc_audio_set_music_pitch_raw": Audio.set_music_pitch_raw!,
		"roc_audio_set_music_pan_raw": Audio.set_music_pan_raw!,
		"roc_audio_set_music_looping_raw": Audio.set_music_looping_raw!,
		"roc_draw_begin_frame": Draw.begin_frame!,
		"roc_draw_circle_gradient": Draw.circle_gradient!,
		"roc_draw_circle_lines_raw": Draw.circle_lines_raw!,
		"roc_draw_circle_raw": Draw.circle_raw!,
		"roc_draw_clear": Draw.clear!,
		"roc_draw_draw_texture_raw": Draw.draw_texture_raw!,
		"roc_draw_end_frame": Draw.end_frame!,
		"roc_draw_fps": Draw.fps!,
		"roc_draw_line_raw": Draw.line_raw!,
		"roc_draw_load_font_raw": Draw.load_font_raw!,
		"roc_draw_measure_text_raw": Draw.measure_text_raw!,
		"roc_draw_polygon_lines_raw": Draw.polygon_lines_raw!,
		"roc_draw_polygon_raw": Draw.polygon_raw!,
		"roc_draw_rectangle_gradient_h": Draw.rectangle_gradient_h!,
		"roc_draw_rectangle_gradient_v": Draw.rectangle_gradient_v!,
		"roc_draw_rectangle_lines_raw": Draw.rectangle_lines_raw!,
		"roc_draw_rectangle_raw": Draw.rectangle_raw!,
		"roc_draw_rounded_rectangle_lines_raw": Draw.rounded_rectangle_lines_raw!,
		"roc_draw_rounded_rectangle_raw": Draw.rounded_rectangle_raw!,
		"roc_draw_text_raw": Draw.text_raw!,
		"roc_draw_triangle_lines_raw": Draw.triangle_lines_raw!,
		"roc_draw_triangle_raw": Draw.triangle_raw!,
		"roc_host_exit": Host.exit!,
		"roc_host_get_screen_size": Host.get_screen_size!,
		"roc_host_random_i32": Host.random_i32!,
		"roc_host_read_env": Host.read_env!,
		"roc_host_read_file_raw": Host.read_file_raw!,
		"roc_host_set_screen_size": Host.set_screen_size!,
		"roc_host_set_target_fps": Host.set_target_fps!,
		"roc_tilemap_load_tmx_raw": Tilemap.load_tmx_raw!,
		"roc_draw_begin_camera": Draw.begin_camera!,
		"roc_draw_end_camera": Draw.end_camera!,
	}
	targets: {
		inputs_dir: "targets/",
		x64glibc: { inputs: ["Scrt1.o", "crti.o", "libhost.a", "libraylib.a", "libm.so", app, "libc.so", "crtn.o"] },
	}

import Draw
import Color
import Host
import Keys
import Mouse
import Time
import Audio
import App
import Assets
import Math
import Camera
import Sprite
import Tilemap
import Physics

## TODO: roc glue currently undercounts direct function fields in generated
## records when they are mixed with non-function data. The generated
## __AnonStruct57 and __AnonStruct70 size assertions are patched to include
## the function pointers.
## Re-run glue without that patch once the upstream glue bug is fixed.

## Internal type for host boundary.
## Keep this layout-compatible with the public Host record; the compiler may
## optimize the reshaping below into a direct pass-through.
HostStateFromHost : {
	frame_count : U64,
	timestamp_nanos : U64, ## monotonic clock, nanoseconds since window init
	frame_time : F32, ## seconds since previous frame (0 on first frame)
	keys : List(U8), ## 349 bytes, held state, one per raylib key code 0-348
	keys_pressed : List(U8), ## 349 bytes, pressed-this-frame (edge) state
	keys_released : List(U8), ## 349 bytes, released-this-frame (edge) state
	mouse : {
		buttons : List(U8), ## 7 bytes, held state, one per raylib mouse button code 0-6
		buttons_pressed : List(U8), ## 7 bytes, pressed-this-frame (edge) state
		buttons_released : List(U8), ## 7 bytes, released-this-frame (edge) state
		wheel : F32,
		x : F32,
		y : F32,
		left : Bool,
		middle : Bool,
		right : Bool,
	},
}

app_config_for_host! : () => App.Config
app_config_for_host! = || program.init!.config

init_for_host! : HostStateFromHost => Try(Box(Model), I64)
init_for_host! = |host_state| {
	host = {
		frame_count: host_state.frame_count,
		timestamp_nanos: host_state.timestamp_nanos,
		frame_time: host_state.frame_time,
		keys: host_state.keys,
		keys_pressed: host_state.keys_pressed,
		keys_released: host_state.keys_released,
		mouse: host_state.mouse,
	}
	match (program.init!.run!)(host) {
		Ok(unboxed_model) => Ok(Box.box(unboxed_model))
		Err(Exit(code)) => Err(code)
	}
}

render_for_host! : Box(Model), HostStateFromHost => Try(Box(Model), I64)
render_for_host! = |boxed_model, host_state| {
	host = {
		frame_count: host_state.frame_count,
		timestamp_nanos: host_state.timestamp_nanos,
		frame_time: host_state.frame_time,
		keys: host_state.keys,
		keys_pressed: host_state.keys_pressed,
		keys_released: host_state.keys_released,
		mouse: host_state.mouse,
	}
	match (program.render!)(Box.unbox(boxed_model), host) {
		Ok(unboxed_model) => Ok(Box.box(unboxed_model))
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
