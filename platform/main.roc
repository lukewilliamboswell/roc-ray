platform ""
	requires {
		[Model : model] for program : {
			init! : {
				config : App.Config,
				run! : Host => Try(model, [Exit(I64), ..]),
			},
			render! : model, Host, Draw.Frame => Try(model, [Exit(I64), ..]),
		}
	}
	exposes [Draw, Text, Color, Host, Keys, Mouse, Gamepad, Time, Audio, App, Assets, Math, Camera, Sprite, Tilemap, Physics]
	packages {
		rrt: "../package/main.roc",
	}
	provides {
		"app_config_for_host": app_config_for_host!,
		"init_for_host": init_for_host!,
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
		x64mac: { inputs: ["libhost.a", "libraylib.a", app] },
		arm64mac: { inputs: ["libhost.a", "libraylib.a", app] },
		x64glibc: { inputs: ["Scrt1.o", "crti.o", "libhost.a", "libraylib.a", "libm.so", "libX11.so", app, "libc.so", "crtn.o"] },
		x64win: { inputs: ["host.lib", "raylib.lib", "gdi32.lib", "user32.lib", "winmm.lib", "opengl32.lib", "shell32.lib", app] },
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
import Assets
import AssetsHost
import Math
import Camera
import Sprite
import Tilemap
import TilemapHost
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

app_config_for_host! : () => AppConfig.HostConfig
app_config_for_host! = || AppConfig.to_host({}, program.init!.config)

init_for_host! : HostStateFromHost => Try(Box(Model), I64)
init_for_host! = |host_state| {
	host = {
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
		gamepads: {
			connected: host_state.gamepads.available,
			buttons: host_state.gamepads.buttons,
			axes: host_state.gamepads.axes,
		},
		mouse: host_state.mouse,
	}
	frame = Draw.Frame.from_host(DrawHost.Frame.for_host)
	match (program.render!)(Box.unbox(boxed_model), host, frame) {
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
