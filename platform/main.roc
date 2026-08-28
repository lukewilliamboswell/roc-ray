## RocRay is a platform for games, visualizations, and other frame-oriented
## Roc applications.
##
## An app provides `init!`, `update!`, and `render!`. `init!` creates the first
## model. Each host cycle, `update!` folds one `App.Input` into the next model;
## `render!` may then draw that model through a `Draw.Frame`.
##
## Host-state effects are legal in `init!`, `update!`, and tasks. Drawing is
## legal only in `render!`. Waiting effects are legal in `init!`, where they
## block startup, and in tasks, where they park the task. Each effect documents
## its exact phases. A phase violation stops the app as a programmer error.
##
## Start with `App`, then use `Draw`, `Devices`, `Assets`, `Audio`, and `Task`
## as needed. Complete examples are available in the repository.
##
## This app opens a window, draws a circle, and exits on Escape:
##
## ```roc
## app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-23-fb208ba" }
##
## import rr.App
## import rr.Color
## import rr.Draw
##
## Model : { frames : U64 }
##
## Msg : []
##
## program = { init!, update!, render! }
##
## init! : App.Init(Model, [])
## init! = App.init(App.default.with_title("Hello"), |_startup| Ok({ frames: 0 }))
##
## update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
## update! = |model, input|
##     if input.devices.key_pressed(KeyEscape) {
##         Err(Exit(0))
##     } else {
##         Ok({ frames: model.frames + 1 })
##     }
##
## render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
## render! = |_model, frame| {
##     frame.clear!(Color.black)
##     frame.circle!({ center: { x: 400, y: 300 }, radius: 40, style: Draw.filled(Color.red) })
##     Ok({})
## }
## ```
##
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
	exposes [App, Devices, Files, Draw, Text, Color, Window, Keys, Mouse, Gamepad, Time, Audio, Assets, Math, Camera, Sprite, Tilemap, Physics, Capture, Random, Task, Http, Udp, Url, Stdout, Stderr, Sqlite, Cmd, Trace]
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
		"roc_assets_open_store_raw": HostABI.assets_open_store!,
		"roc_assets_load_store_texture_raw": HostABI.assets_load_store_texture!,
		"roc_assets_load_texture_bytes_raw": HostABI.assets_load_texture_bytes!,
		"roc_assets_generate_color_texture_raw": HostABI.assets_generate_color_texture!,
		"roc_assets_generate_checked_texture_raw": HostABI.assets_generate_checked_texture!,
		"roc_assets_update_texture_raw": HostABI.assets_update_texture!,
		"roc_assets_update_texture_region_raw": HostABI.assets_update_texture_region!,
		"roc_assets_set_texture_filter_raw": HostABI.assets_set_texture_filter!,
		"roc_assets_set_texture_wrap_raw": HostABI.assets_set_texture_wrap!,
		"roc_audio_gen_tone_raw": HostABI.audio_gen_tone!,
		"roc_audio_gen_sound_raw": HostABI.audio_gen_sound!,
		"roc_audio_load_sound_raw": HostABI.audio_load_sound!,
		"roc_audio_load_music_raw": HostABI.audio_load_music!,
		"roc_audio_play_raw": HostABI.audio_play_sound!,
		"roc_audio_stop_raw": HostABI.audio_stop_sound!,
		"roc_audio_pause_raw": HostABI.audio_pause_sound!,
		"roc_audio_resume_raw": HostABI.audio_resume_sound!,
		"roc_audio_is_playing_raw": HostABI.audio_is_sound_playing!,
		"roc_audio_set_volume_raw": HostABI.audio_set_sound_volume!,
		"roc_audio_set_pitch_raw": HostABI.audio_set_sound_pitch!,
		"roc_audio_set_pan_raw": HostABI.audio_set_sound_pan!,
		"roc_audio_play_music_raw": HostABI.audio_play_music!,
		"roc_audio_stop_music_raw": HostABI.audio_stop_music!,
		"roc_audio_pause_music_raw": HostABI.audio_pause_music!,
		"roc_audio_resume_music_raw": HostABI.audio_resume_music!,
		"roc_audio_set_music_volume_raw": HostABI.audio_set_music_volume!,
		"roc_audio_set_music_pitch_raw": HostABI.audio_set_music_pitch!,
		"roc_audio_set_music_pan_raw": HostABI.audio_set_music_pan!,
		"roc_audio_set_music_looping_raw": HostABI.audio_set_music_looping!,
		"roc_audio_is_music_playing_raw": HostABI.audio_is_music_playing!,
		"roc_audio_seek_music_raw": HostABI.audio_seek_music!,
		"roc_audio_music_length_raw": HostABI.audio_music_length!,
		"roc_audio_music_time_played_raw": HostABI.audio_music_time_played!,
		"roc_audio_set_master_volume_raw": HostABI.audio_set_master_volume!,
		"roc_draw_begin_scissor_raw": HostABI.draw_begin_scissor!,
		"roc_draw_circle_gradient": HostABI.draw_circle_gradient!,
		"roc_draw_circle_lines_raw": HostABI.draw_circle_lines!,
		"roc_draw_circle_raw": HostABI.draw_circle!,
		"roc_draw_clear": HostABI.draw_clear!,
		"roc_draw_draw_texture_raw": HostABI.draw_draw_texture!,
		"roc_draw_draw_texture_instances_raw": HostABI.draw_draw_texture_instances!,
		"roc_draw_draw_texture_quad_raw": HostABI.draw_draw_texture_quad!,
		"roc_draw_end_scissor_raw": HostABI.draw_end_scissor!,
		"roc_draw_fps": HostABI.draw_fps!,
		"roc_draw_default_font_raw": HostABI.draw_default_font!,
		"roc_draw_startup_default_font_raw": HostABI.draw_startup_default_font!,
		"roc_draw_font_metrics_raw": HostABI.draw_font_metrics!,
		"roc_draw_frame_size": HostABI.draw_frame_size!,
		"roc_draw_line_raw": HostABI.draw_line!,
		"roc_draw_load_font_bytes_raw": HostABI.draw_load_font_bytes!,
		"roc_draw_load_store_font_raw": HostABI.draw_load_store_font!,
		"roc_draw_prepare_text_raw": HostABI.draw_prepare_text!,
		"roc_draw_draw_prepared_text_raw": HostABI.draw_draw_prepared_text!,
		"roc_draw_polygon_lines_raw": HostABI.draw_polygon_lines!,
		"roc_draw_polygon_raw": HostABI.draw_polygon!,
		"roc_draw_rectangle_gradient_h": HostABI.draw_rectangle_gradient_h!,
		"roc_draw_rectangle_gradient_v": HostABI.draw_rectangle_gradient_v!,
		"roc_draw_rectangle_lines_raw": HostABI.draw_rectangle_lines!,
		"roc_draw_rectangle_raw": HostABI.draw_rectangle!,
		"roc_draw_rounded_rectangle_lines_raw": HostABI.draw_rounded_rectangle_lines!,
		"roc_draw_rounded_rectangle_raw": HostABI.draw_rounded_rectangle!,
		"roc_draw_text_raw": HostABI.draw_text!,
		"roc_draw_triangle_lines_raw": HostABI.draw_triangle_lines!,
		"roc_draw_triangle_raw": HostABI.draw_triangle!,
		"roc_files_read_text": HostABI.files_read_text!,
		"roc_files_read_bytes": HostABI.files_read_bytes!,
		"roc_files_list": HostABI.files_list!,
		"roc_files_metadata": HostABI.files_metadata!,
		"roc_files_write_text": HostABI.files_write_text!,
		"roc_files_write_bytes": HostABI.files_write_bytes!,
		"roc_capture_set_virtual_mouse": HostABI.capture_set_virtual_mouse!,
		"roc_capture_set_virtual_keys": HostABI.capture_set_virtual_keys!,
		"roc_capture_set_virtual_text": HostABI.capture_set_virtual_text!,
		"roc_capture_start_recording": HostABI.capture_start_recording!,
		"roc_capture_stop_recording": HostABI.capture_stop_recording!,
		"roc_capture_screenshot": HostABI.capture_screenshot!,
		"roc_capture_screenshot_texture": HostABI.capture_screenshot_texture!,
		"roc_capture_pixel_at": HostABI.capture_pixel_at!,
		"roc_capture_read_region": HostABI.capture_read_region!,
		"roc_app_exit": HostABI.app_exit!,
		"roc_app_args": HostABI.app_args!,
		"roc_app_read_env": HostABI.app_read_env!,
		"roc_app_read_file_raw": HostABI.app_read_file!,
		"roc_random_entropy": HostABI.random_entropy!,
		"roc_random_i32": HostABI.random_i32!,
		"roc_keys_set_exit_key": HostABI.keys_set_exit_key!,
		"roc_window_read_clipboard": HostABI.window_read_clipboard!,
		"roc_window_set_clipboard_text": HostABI.window_set_clipboard_text!,
		"roc_window_suggest_size": HostABI.window_suggest_size!,
		"roc_window_set_target_fps": HostABI.window_set_target_fps!,
		"roc_window_suggest_min_size": HostABI.window_suggest_min_size!,
		"roc_window_scale_dpi": HostABI.window_scale_dpi!,
		"roc_window_monitors": HostABI.window_monitors!,
		"roc_window_suggest_position": HostABI.window_suggest_position!,
		"roc_window_suggest_monitor": HostABI.window_suggest_monitor!,
		"roc_mouse_set_cursor_mode_raw": HostABI.mouse_set_cursor_mode!,
		"roc_mouse_set_cursor_raw": HostABI.mouse_set_cursor!,
		"roc_task_sleep": HostABI.task_sleep!,
		"roc_task_spawn": HostABI.task_spawn!,
		"roc_tilemap_load_tmx_raw": HostABI.tilemap_load_tmx!,
		"roc_tilemap_draw_raw": HostABI.tilemap_draw!,
		"roc_draw_begin_camera": HostABI.draw_begin_camera!,
		"roc_draw_begin_blend_raw": HostABI.draw_begin_blend!,
		"roc_draw_begin_render_texture_raw": HostABI.draw_begin_render_texture!,
		"roc_draw_begin_shader_raw": HostABI.draw_begin_shader!,
		"roc_draw_end_camera": HostABI.draw_end_camera!,
		"roc_draw_end_blend_raw": HostABI.draw_end_blend!,
		"roc_draw_end_render_texture_raw": HostABI.draw_end_render_texture!,
		"roc_draw_end_shader_raw": HostABI.draw_end_shader!,
		"roc_draw_load_render_texture_raw": HostABI.draw_load_render_texture!,
		"roc_draw_load_shader_source_raw": HostABI.draw_load_shader_source!,
		"roc_draw_load_store_shader_raw": HostABI.draw_load_store_shader!,
		"roc_draw_shader_location_raw": HostABI.draw_shader_location!,
		"roc_draw_set_shader_float_raw": HostABI.draw_set_shader_float!,
		"roc_draw_set_shader_int_raw": HostABI.draw_set_shader_int!,
		"roc_draw_set_shader_texture_raw": HostABI.draw_set_shader_texture!,
		"roc_draw_set_shader_vec2_raw": HostABI.draw_set_shader_vec2!,
		"roc_draw_set_shader_vec3_raw": HostABI.draw_set_shader_vec3!,
		"roc_draw_set_shader_vec4_raw": HostABI.draw_set_shader_vec4!,
		"roc_http_send": HostABI.http_send!,
		"roc_time_now": HostABI.time_now!,
		"roc_stdio_write_text": HostABI.stdio_write_text!,
		"roc_stdio_write_line": HostABI.stdio_write_line!,
		"roc_stdio_write_bytes": HostABI.stdio_write_bytes!,
		"roc_udp_bind": HostABI.udp_bind!,
		"roc_udp_send": HostABI.udp_send!,
		"roc_udp_receive": HostABI.udp_receive!,
		"roc_sqlite_open": HostABI.sqlite_open!,
		"roc_sqlite_close": HostABI.sqlite_close!,
		"roc_sqlite_prepare": HostABI.sqlite_prepare!,
		"roc_sqlite_run_stmt": HostABI.sqlite_run_stmt!,
		"roc_sqlite_run_once": HostABI.sqlite_run_once!,
		"roc_sqlite_exec_script": HostABI.sqlite_exec_script!,
		"roc_cmd_run": HostABI.cmd_run!,
		"roc_trace_mark": HostABI.trace_mark!,
		"roc_trace_begin": HostABI.trace_begin!,
		"roc_trace_end": HostABI.trace_end!,
		"roc_trace_sample_i64": HostABI.trace_sample_i64!,
		"roc_trace_sample_f64": HostABI.trace_sample_f64!,
	}
	targets: {
		inputs_dir: "targets/",
		x64mac: { inputs: ["libhost.a", "libraylib.a", "libmsf_gif.a", "libvpx.a", "libsqlite3.a", app] },
		arm64mac: { inputs: ["libhost.a", "libraylib.a", "libmsf_gif.a", "libvpx.a", "libsqlite3.a", app] },
		x64glibc: { inputs: ["Scrt1.o", "crti.o", "libhost.a", "libraylib.a", "libmsf_gif.a", "libvpx.a", "libsqlite3.a", "libm.so", "libX11.so", app, "libc.so", "crtn.o"] },
		x64win: { inputs: ["host.lib", "raylib.lib", "msf_gif.lib", "vpx.lib", "sqlite3.lib", "gdi32.lib", "user32.lib", "winmm.lib", "opengl32.lib", "shell32.lib", "ws2_32.lib", "crypt32.lib", "shlwapi.lib", "bcryptprimitives.lib", app] },
	}

import Draw
import HostABI
import Text
import Color
import Devices
import rrt.Devices as RrtDevices
import Files
import Window
import Keys
import Mouse
import Gamepad
import Time
import Audio
import App
import AppConfig
import Capture
import Assets
import Math
import Camera
import Sprite
import Tilemap
import Physics
import AppTransport
import Random
import Task
import Trace
import Http
import Udp
import Url
import Stdout
import Stderr
import Sqlite
import Cmd

## Internal type for the host boundary, carrying one cycle of sampled input.
## Keep this layout-compatible with the public `Devices.Snapshot` record; the
## compiler may optimize the reshaping below into a direct pass-through.
InputFromHost : {
	keys : List(U8), ## 349 packed state bytes, one per raylib key code 0-348
	text_input : List(U32), ## Unicode codepoints typed this interval, at most 32
	text_input_overflow : Bool, ## whether more than 32 were typed and the rest discarded
	events : List(RrtDevices.RawEvent), ## every event this interval in delivery order, at most 256
	events_overflow : Bool, ## whether more than 256 arrived and the rest were discarded
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
## Unions do not cross this boundary, so the recording state arrives as a flat
## record. Each finished task arrives as an erased thunk holding its message;
## Roc calls it before rebuilding `App.Input`.
##
## `dropped` is the cycle's file drops, already in the public `App.Dropped`
## shape, and `dropped_overflow` says whether the host discarded paths past its
## per-cycle cap.
InputFromHostCycle(msg) : {
	devices : InputFromHost,
	window : Window.Snapshot,
	time : Time.Cycle,
	task_results : List(HostABI.TaskFinishedTask(msg)),
	capture : HostABI.AppRawCaptureStatus,
	dropped : List(App.Dropped),
	dropped_overflow : Bool,
}

app_config_for_host! : () => AppConfig.HostConfig
app_config_for_host! = || AppConfig.to_host({}, (program.init!.config)(HostABI.app_args!()))

## Reshape the flat sampled input into the public `Devices.Snapshot` record.
##
## `gamepads.available` is renamed and the flat event records are decoded into
## the typed `Devices.Event` union -- a union cannot cross the host boundary --
## and the rest passes through unchanged.
input_from_raw : InputFromHost -> Devices.Snapshot
input_from_raw = |raw| {
	keys: raw.keys,
	text_input: raw.text_input,
	text_input_overflow: raw.text_input_overflow,
	events: RrtDevices.events_from_raw(raw.events),
	events_overflow: raw.events_overflow,
	gamepads: {
		connected: raw.gamepads.available,
		buttons: raw.gamepads.buttons,
		axes: raw.gamepads.axes,
	},
	mouse: raw.mouse,
}

## Rebuild a public `App.Input` after unwrapping this cycle's task messages.
app_input_from_raw : InputFromHost, Window.Snapshot, Time.Cycle, HostABI.AppRawCaptureStatus, List(msg), List(App.Dropped), Bool -> App.Input(msg)
app_input_from_raw = |devices, window, time, capture, messages, dropped, dropped_overflow| {
	devices: input_from_raw(devices),
	window,
	time,
	messages,
	capture: AppTransport.capture_status(capture),
	dropped,
	dropped_overflow,
}

## Run the app's startup callback with the platform's startup authority.
##
## No input, window, or timing observations have been sampled at this point.
init_for_host! : () => Try(Box(Model), I64)
init_for_host! = ||
	match (program.init!.run!)(App.Startup.for_host({})) {
		Ok(model) => Ok(Box.box(model))
		Err(Exit(code)) => Err(code)
		Err(_) => Err(-1)
	}

## Advance the model by one cycle.
##
## Called once per fresh host-cycle input, whether or not that cycle presents.
## `update!` is effectful: synchronous host effects run inline, in program
## order, and tasks reach the host through the `Task.spawn!` effect while this
## call is in progress. The separate `render_for_host!` callback is optional
## for the cycle and, when invoked, receives the model this one returns.
##
## Writing to a collection held in the model is an in-place write. The box
## arrives holding the model's only reference -- refcount 1 on entry -- and
## unboxing here consumes it, so `update!` runs with the model's lists uniquely
## referenced and mutates them rather than copying. `test/model_inplace` holds
## that to under a hundred bytes per frame for a million-element `List(F32)`,
## under `scripts/test_model_allocation.py`.
update_for_host! : Box(Model), InputFromHostCycle(Msg) => Try(Box(Model), I64)
update_for_host! = |boxed_model, { devices, window, time, task_results, capture, dropped, dropped_overflow }| {
	messages = receive_task_results(task_results)
	input = app_input_from_raw(devices, window, time, capture, messages, dropped, dropped_overflow)
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
## has gone around as many times as it needed to. This is the only place
## outside `main.roc`'s `requires` block where a task's message type is named,
## which is why every public spawn takes an `App.Input(msg)` witness.
##
## The message comes back wrapped in an erased thunk rather than as a
## `Box(Msg)`, to work around a `roc glue` defect that renders a
## `List(Box(msg))` with a one-word list header while every backend allocates
## and frees it with the two-word refcounted one. `HostABI.TaskFinishedTask` has
## the account.
run_task_for_host! : Box(() => Msg) => Box({} -> Box(Msg))
run_task_for_host! = |boxed| {
	run! = Box.unbox(boxed)
	message = Box.box(run!())
	Box.box(|{}| message)
}

## Unwrap every finished task's message, in the order the tasks completed.
##
## That order becomes `Input.messages`, so it is the order `update!` sees. The
## list is pre-sized and preserves it without intermediate result lists.
receive_task_results : List(HostABI.TaskFinishedTask(msg)) -> List(msg)
receive_task_results = |results| {
	var $messages = List.with_capacity(List.len(results))
	for result in results {
		deliver = Box.unbox(result.deliver)
		$messages = List.append($messages, Box.unbox(deliver({})))
	}
	$messages
}

## Optionally present the current model, then hand the same box back.
##
## Unboxing borrows rather than consumes, so the host's model reference is
## returned unchanged.
render_for_host! : Box(Model) => Try(Box(Model), I64)
render_for_host! = |boxed_model| {
	frame = Draw.Frame.from_host({})
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
