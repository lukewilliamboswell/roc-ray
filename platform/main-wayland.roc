platform ""
	requires {
		[Model : model, Msg : msg] for program : {
			init! : {
				config : List(Str) -> App.Config,
				run! : App.Startup => Try(model, [Exit(I64), ..]),
			},
			update! : model, App.Input(msg) => Try(model, [Exit(I64), ..]),
			render! : model, Draw.Frame => Try({}, [Exit(I64), ..]),
		}
	}
	exposes [App, Devices, Files, Draw, Text, Color, Window, Keys, Mouse, Gamepad, Time, Audio, Assets, Math, Camera, Sprite, Tilemap, Physics, Capture, RequestQueue, Random, Task, Http, Url]
	packages {
		rrt: "../types/main.roc",
		rand: "https://github.com/kili-ilo/roc-random/releases/download/0.9.2/2ZXLX8WRqrosGu1V3VL5aXqgtfTRvJmjFPx8a26ecVmc.tar.zst",
		http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	}
	provides {
		"app_config_for_host": app_config_for_host!,
		"init_for_host": init_for_host!,
		"update_for_host": update_for_host!,
		"render_for_host": render_for_host!,
		"drop_model_for_host": drop_model_for_host!,
		"run_task_for_host": run_task_for_host!,
	}
	hosted {
		"roc_assets_open_store_raw": AssetsHost.open_store!,
		"roc_assets_load_store_texture_raw": AssetsHost.load_store_texture!,
		"roc_assets_load_texture_bytes_raw": AssetsHost.load_texture_bytes!,
		"roc_assets_generate_color_texture_raw": AssetsHost.generate_color_texture!,
		"roc_assets_generate_checked_texture_raw": AssetsHost.generate_checked_texture!,
		"roc_assets_update_texture_raw": AssetsHost.update_texture!,
		"roc_assets_update_texture_region_raw": AssetsHost.update_texture_region!,
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
		"roc_draw_draw_texture_instances_raw": DrawHost.draw_texture_instances!,
		"roc_draw_draw_texture_quad_raw": DrawHost.draw_texture_quad!,
		"roc_draw_end_scissor_raw": DrawHost.end_scissor!,
		"roc_draw_fps": DrawHost.fps!,
		"roc_draw_font_metrics_raw": DrawHost.font_metrics!,
		"roc_draw_frame_size": DrawHost.frame_size!,
		"roc_draw_line_raw": DrawHost.line!,
		"roc_draw_load_font_bytes_raw": DrawHost.load_font_bytes!,
		"roc_draw_load_store_font_raw": DrawHost.load_store_font!,
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
		"roc_files_read_text": FilesHost.read_text!,
		"roc_files_read_bytes": FilesHost.read_bytes!,
		"roc_files_list": FilesHost.list!,
		"roc_capture_set_virtual_mouse": CaptureHost.set_virtual_mouse!,
		"roc_capture_start_recording": CaptureHost.start_recording!,
		"roc_capture_stop_recording": CaptureHost.stop_recording!,
		"roc_capture_screenshot": CaptureHost.screenshot!,
		"roc_host_exit": HostHost.exit!,
		"roc_host_args": HostHost.args!,
		"roc_host_get_clipboard_text": HostHost.get_clipboard_text!,
		"roc_host_read_clipboard": HostHost.read_clipboard!,
		"roc_host_random_i32": HostHost.random_i32!,
		"roc_host_read_env": HostHost.read_env!,
		"roc_host_read_file_raw": HostHost.read_file!,
		"roc_host_set_clipboard_text": HostHost.set_clipboard_text!,
		"roc_host_set_exit_key": HostHost.set_exit_key!,
		"roc_host_suggest_window_size": HostHost.suggest_window_size!,
		"roc_host_set_target_fps": HostHost.set_target_fps!,
		"roc_host_suggest_window_min_size": HostHost.suggest_window_min_size!,
		"roc_mouse_set_cursor_mode_raw": MouseHost.set_cursor_mode!,
		"roc_mouse_set_cursor_raw": MouseHost.set_cursor!,
		"roc_task_sleep": TaskHost.sleep!,
		"roc_task_spawn": TaskHost.spawn!,
		"roc_app_submit_request": AppHost.submit_request!,
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
		"roc_draw_load_shader_source_raw": DrawHost.load_shader_source!,
		"roc_draw_load_store_shader_raw": DrawHost.load_store_shader!,
		"roc_draw_shader_location_raw": DrawHost.shader_location!,
		"roc_draw_set_shader_float_raw": DrawHost.set_shader_float!,
		"roc_draw_set_shader_int_raw": DrawHost.set_shader_int!,
		"roc_draw_set_shader_texture_raw": DrawHost.set_shader_texture!,
		"roc_draw_set_shader_vec2_raw": DrawHost.set_shader_vec2!,
		"roc_draw_set_shader_vec3_raw": DrawHost.set_shader_vec3!,
		"roc_draw_set_shader_vec4_raw": DrawHost.set_shader_vec4!,
		"roc_http_send": HttpHost.send!,
	}
	targets: {
		inputs_dir: "targets/",
		x64glibc: { inputs: ["Scrt1.o", "crti.o", "libhost.a", "libraylib.a", "libmsf_gif.a", "libvpx.a", "libm.so", app, "libc.so", "crtn.o"] },
	}

import Draw
import DrawHost
import Text
import Color
import Devices
import Files
import FilesHost
import Window
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
import AppHost
import AppTransport
import RequestQueue
import Random
import TaskHost
import Task
import HttpHost
import Http
import Url

## Internal type for the host boundary, carrying one cycle of sampled input.
## Keep this layout-compatible with the public `Devices.Snapshot` record; the
## compiler may optimize the reshaping below into a direct pass-through.
InputFromHost : {
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
## `window` and `time` are already flat records of scalars, so the public types
## cross the boundary unchanged rather than being mirrored by a second copy that
## could drift. Only `input` needs reshaping, and only to rename one field.
##
## Unions do not cross this boundary, so request results and recording state arrive
## as flat records. The host owns each pending callback envelope and returns it
## with its raw terminal result; Roc invokes it before rebuilding `App.Input`.
InputFromHostCycle(msg) : {
	devices : InputFromHost,
	window : Window.Snapshot,
	time : Time.Cycle,
	responses : List(AppHost.PendingResponse(msg)),
	capture : AppHost.RawCaptureStatus,
}

app_config_for_host! : () => AppConfig.HostConfig
app_config_for_host! = || AppConfig.to_host({}, (program.init!.config)(HostHost.args!()))

## Reshape the flat sampled input into the public `Devices.Snapshot` record.
##
## Only `gamepads.available` is renamed; the compiler may optimize the rest of
## this into a direct pass-through, which is why the two layouts are kept
## deliberately compatible.
input_from_raw : InputFromHost -> Devices.Snapshot
input_from_raw = |raw| {
	keys: raw.keys,
	text_input: raw.text_input,
	gamepads: {
		connected: raw.gamepads.available,
		buttons: raw.gamepads.buttons,
		axes: raw.gamepads.axes,
	},
	mouse: raw.mouse,
}

## Rebuild a public `App.Input` after resolving private host responses.
app_input_from_raw : InputFromHost, Window.Snapshot, Time.Cycle, AppHost.RawCaptureStatus, List(msg) -> App.Input(msg)
app_input_from_raw = |devices, window, time, capture, messages| {
	devices: input_from_raw(devices),
	window,
	time,
	messages,
	capture: AppTransport.capture_status(capture),
}

## Run the app's startup callback with the platform's startup authority.
##
## No input, window, or timing observations have been sampled at this point.
init_for_host! : () => Try(Box(Model), I64)
init_for_host! = ||
	match (program.init!.run!)(HostHost.Startup.for_host) {
		Ok(model) => Ok(Box.box(model))
		Err(Exit(code)) => Err(code)
		Err(_) => Err(-1)
	}

## Advance the model by one cycle.
##
## Called once per fresh host-cycle input, whether or not that cycle presents.
## `update!` is effectful: synchronous host effects run inline, in program
## order, and deferred work reaches the host through the `Task.spawn!` and
## `App.request!` effects while this call is in progress. The separate
## `render_for_host!` callback is optional for the cycle and, when invoked,
## receives this resulting model.
##
## Writing to a collection held in the model is an in-place write. The box
## arrives holding the model's only reference -- measured at refcount 1 on entry
## -- and unboxing here consumes it, so `update!` runs with the model's lists
## uniquely referenced and mutates them rather than copying. Measured on
## `nightly-2026-08-21-90da19f` at under a hundred bytes per frame for a
## million-element `List(F32)` by `test/model_inplace` under
## `scripts/test_model_allocation.py`, which checks that budget. Earlier pins
## copied the whole list every frame; `--characterize` describes that behaviour.
update_for_host! : Box(Model), InputFromHostCycle(Msg) => Try(Box(Model), I64)
update_for_host! = |boxed_model, { devices, window, time, responses, capture }| {
	messages = receive_responses(responses)
	input = app_input_from_raw(devices, window, time, capture, messages)
	model = Box.unbox(boxed_model)
	match (program.update!)(model, input) {
		Ok(next) => Ok(Box.box(next))
		Err(Exit(code)) => Err(code)
		Err(_) => Err(-1)
	}
}

## Run one task to completion on the host's coroutine and hand back its message.
##
## The host calls this from the task's own stack; a waiting effect inside the
## closure parks that stack and this call returns later, after the frame loop
## has gone around as many times as it needed to.
##
## The message comes back wrapped as a response mapper -- the same
## `Box(RawResponse -> Box(msg))` every request callback uses -- so the host
## stages it as an ordinary `PendingResponse` and `receive_responses` delivers
## it with code that already exists.
##
## TODO(compiler): the direct shape -- `task_results : List(Box(msg))` on the
## input, unboxed in a loop -- trips a debug-only postcheck invariant in
## SpecConstr ("known constructor match had no matching branch") whenever
## `Msg : []`. The pinned release nightly builds it; a debug build of the same
## commit aborts. Keep this shape until that invariant is understood upstream,
## then deliver task results directly and drop the wrapper closure.
run_task_for_host! : Box(() => Msg) => Box(AppHost.RawResponse -> Box(Msg))
run_task_for_host! = |boxed| {
	run! = Box.unbox(boxed)
	message = Box.box(run!())
	Box.box(|_raw| message)
}

## Invoke every returned response envelope in the host's observed order.
##
## The host removes an accepted envelope before returning it, so its own ticket
## table detects unknown or duplicate responses. This list is pre-sized and
## preserves that delivery order without intermediate result lists.
receive_responses : List(AppHost.PendingResponse(msg)) -> List(msg)
receive_responses = |responses| {
	var $messages = List.with_capacity(List.len(responses))
	for response in responses {
		$messages = List.append($messages, AppTransport.receive_response(response))
	}
	$messages
}

## Optionally present the current model, then hand the same box back.
##
## Unboxing borrows rather than consumes, so the host's model reference is
## returned unchanged.
render_for_host! : Box(Model) => Try(Box(Model), I64)
render_for_host! = |boxed_model| {
	frame = Draw.Frame.from_host(DrawHost.Frame.for_host)
	model = Box.unbox(boxed_model)
	match (program.render!)(model, frame) {
		Ok({}) => Ok(boxed_model)
		Err(Exit(code)) => Err(code)
		Err(_) => Err(-1)
	}
}

## Drop the final boxed model at host shutdown.
##
## The host owns the model box returned by init!/render! and must release it.
## Box refcounting depends on the Model layout, which only the compiler knows.
## Roc therefore owns the unused argument and decrefs it at scope end.
## TODO: remove once roc glue emits box refcount helpers (roc#9536).
drop_model_for_host! : Box(Model) => {}
drop_model_for_host! = |_boxed_model| {}
