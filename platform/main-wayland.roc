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
				run! : Host => Try(model, [Exit(I64), ..]),
			},
			render! : model, Host => Try(model, [Exit(I64), ..]),
		}
	}
	exposes [Draw, Color, Host, Keys, Mouse, Gamepad, Time, Audio, App, Assets, Math, Camera, Sprite, Tilemap, Physics]
	packages {}
	provides {
		"app_config_for_host": app_config_for_host!,
		"init_for_host": init_for_host!,
		"render_for_host": render_for_host!,
		"drop_model_for_host": drop_model_for_host!,
	}
	hosted {
		"roc_assets_load_texture_raw": Assets.load_texture_raw!,
		"roc_assets_generate_color_texture_raw": Assets.generate_color_texture_raw!,
		"roc_assets_generate_checked_texture_raw": Assets.generate_checked_texture_raw!,
		"roc_assets_update_texture_raw": Assets.update_texture_raw!,
		"roc_assets_set_texture_filter_raw": Assets.set_texture_filter_raw!,
		"roc_assets_set_texture_wrap_raw": Assets.set_texture_wrap_raw!,
		"roc_audio_gen_tone_raw": Audio.gen_tone_raw!,
		"roc_audio_gen_sound_raw": Audio.gen_sound_raw!,
		"roc_audio_load_sound_raw": Audio.load_sound_raw!,
		"roc_audio_load_music_raw": Audio.load_music_raw!,
		"roc_audio_play_raw": Audio.play_raw!,
		"roc_audio_stop_raw": Audio.stop_raw!,
		"roc_audio_pause_raw": Audio.pause_raw!,
		"roc_audio_resume_raw": Audio.resume_raw!,
		"roc_audio_is_playing_raw": Audio.is_playing_raw!,
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
		"roc_audio_is_music_playing_raw": Audio.is_music_playing_raw!,
		"roc_audio_seek_music_raw": Audio.seek_music_raw!,
		"roc_audio_music_length_raw": Audio.music_length_raw!,
		"roc_audio_music_time_played_raw": Audio.music_time_played_raw!,
		"roc_audio_set_master_volume_raw": Audio.set_master_volume_raw!,
		"roc_draw_begin_frame": Draw.begin_frame!,
		"roc_draw_begin_scissor_raw": Draw.begin_scissor_raw!,
		"roc_draw_circle_gradient": Draw.circle_gradient!,
		"roc_draw_circle_lines_raw": Draw.circle_lines_raw!,
		"roc_draw_circle_raw": Draw.circle_raw!,
		"roc_draw_clear": Draw.clear!,
		"roc_draw_draw_texture_raw": Draw.draw_texture_raw!,
		"roc_draw_draw_texture_quad_raw": Draw.draw_texture_quad_raw!,
		"roc_draw_end_frame": Draw.end_frame!,
		"roc_draw_end_scissor_raw": Draw.end_scissor_raw!,
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
		"roc_draw_text_aligned_raw": Draw.text_aligned_raw!,
		"roc_draw_text_raw": Draw.text_raw!,
		"roc_draw_triangle_lines_raw": Draw.triangle_lines_raw!,
		"roc_draw_triangle_raw": Draw.triangle_raw!,
		"roc_host_exit": Host.exit!,
		"roc_host_random_i32": Host.random_i32!,
		"roc_host_read_env": Host.read_env_raw!,
		"roc_host_read_file_raw": Host.read_file_raw!,
		"roc_host_set_screen_size": Host.set_screen_size_raw!,
		"roc_host_set_target_fps": Host.set_target_fps!,
		"roc_mouse_show_cursor": Mouse.show_cursor!,
		"roc_mouse_hide_cursor": Mouse.hide_cursor!,
		"roc_mouse_lock_cursor": Mouse.lock_cursor!,
		"roc_mouse_unlock_cursor": Mouse.unlock_cursor!,
		"roc_mouse_set_cursor_raw": Mouse.set_cursor_raw!,
		"roc_tilemap_load_tmx_raw": Tilemap.load_tmx_raw!,
		"roc_draw_begin_camera": Draw.begin_camera!,
		"roc_draw_begin_blend_raw": Draw.begin_blend_raw!,
		"roc_draw_begin_render_texture_raw": Draw.begin_render_texture_raw!,
		"roc_draw_begin_shader_raw": Draw.begin_shader_raw!,
		"roc_draw_end_camera": Draw.end_camera!,
		"roc_draw_end_blend_raw": Draw.end_blend_raw!,
		"roc_draw_end_render_texture_raw": Draw.end_render_texture_raw!,
		"roc_draw_end_shader_raw": Draw.end_shader_raw!,
		"roc_draw_load_render_texture_raw": Draw.load_render_texture_raw!,
		"roc_draw_load_shader_raw": Draw.load_shader_raw!,
		"roc_draw_load_shader_source_raw": Draw.load_shader_source_raw!,
		"roc_draw_shader_location_raw": Draw.shader_location_raw!,
		"roc_draw_set_shader_float_raw": Draw.set_shader_float_raw!,
		"roc_draw_set_shader_int_raw": Draw.set_shader_int_raw!,
		"roc_draw_set_shader_texture_raw": Draw.set_shader_texture_raw!,
		"roc_draw_set_shader_vec2_raw": Draw.set_shader_vec2_raw!,
		"roc_draw_set_shader_vec3_raw": Draw.set_shader_vec3_raw!,
		"roc_draw_set_shader_vec4_raw": Draw.set_shader_vec4_raw!,
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
import Gamepad
import Time
import Audio
import App
import Assets
import Math
import Camera
import Sprite
import Tilemap
import Physics

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

app_config_for_host! : () => App.Config
app_config_for_host! = || program.init!.config

init_for_host! : HostStateFromHost => Try(Box(Model), I64)
init_for_host! = |host_state| {
	host = {
		frame_count: host_state.frame_count,
		timestamp_nanos: host_state.timestamp_nanos,
		frame_time: host_state.frame_time,
		screen: host_state.screen,
		keys: host_state.keys,
		text_input: host_state.text_input,
		gamepads: host_state.gamepads,
		mouse: host_state.mouse,
	}
	match (program.init!.run!)(host) {
		Ok(unboxed_model) => Ok(Box.box(unboxed_model))
		Err(Exit(code)) => Err(code)
		Err(_) => Err(-1)
	}
}

render_for_host! : Box(Model), HostStateFromHost => Try(Box(Model), I64)
render_for_host! = |boxed_model, host_state| {
	host = {
		frame_count: host_state.frame_count,
		timestamp_nanos: host_state.timestamp_nanos,
		frame_time: host_state.frame_time,
		screen: host_state.screen,
		keys: host_state.keys,
		text_input: host_state.text_input,
		gamepads: host_state.gamepads,
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
