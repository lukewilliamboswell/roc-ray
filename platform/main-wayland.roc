platform ""
	requires {
		[Model : model, Msg : msg] for program : {
			init! : {
				config : List(Str) -> App.Config,
				run! : App.Startup => Try(model, [Exit(I64), ..]),
			},
			update : model, Program.Step(msg) -> Program.Update(model, msg),
			render! : model, Draw.Frame => Try({}, [Exit(I64), ..]),
		}
	}
	exposes [Draw, Text, Color, Input, Window, Keys, Mouse, Gamepad, Time, Audio, App, Assets, Math, Camera, Sprite, Tilemap, Physics, Capture, Program, Random]
	packages {
		rrt: "../types/main.roc",
		rand: "https://github.com/kili-ilo/roc-random/releases/download/0.9.2/2ZXLX8WRqrosGu1V3VL5aXqgtfTRvJmjFPx8a26ecVmc.tar.zst",
	}
	provides {
		"app_config_for_host": app_config_for_host!,
		"init_for_host": init_for_host!,
		"update_for_host": update_for_host!,
		"render_for_host": render_for_host!,
		"drop_model_for_host": drop_model_for_host!,
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
		"roc_draw_draw_texture_quad_raw": DrawHost.draw_texture_quad!,
		"roc_draw_end_scissor_raw": DrawHost.end_scissor!,
		"roc_draw_fps": DrawHost.fps!,
		"roc_draw_font_metrics_raw": DrawHost.font_metrics!,
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
		"roc_capture_set_virtual_mouse": CaptureHost.set_virtual_mouse!,
		"roc_capture_start_recording": CaptureHost.start_recording!,
		"roc_capture_stop_recording": CaptureHost.stop_recording!,
		"roc_host_exit": HostHost.exit!,
		"roc_host_args": HostHost.args!,
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
		"roc_draw_load_shader_source_raw": DrawHost.load_shader_source!,
		"roc_draw_load_store_shader_raw": DrawHost.load_store_shader!,
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
		x64glibc: { inputs: ["Scrt1.o", "crti.o", "libhost.a", "libraylib.a", "libmsf_gif.a", "libvpx.a", "libm.so", app, "libc.so", "crtn.o"] },
	}

import Draw
import DrawHost
import Text
import Color
import Input
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
import Program
import Random

## Internal type for the host boundary, carrying one cycle of sampled input.
## Keep this layout-compatible with the public `Input.Snapshot` record; the
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
## Unions do not cross this boundary, so task results and recording state arrive
## as flat records. The host owns each pending callback envelope and returns it
## with its raw terminal result; Roc invokes it before rebuilding `Program.Step`.
StepFromHost(msg) : {
	input : InputFromHost,
	window : Window.Snapshot,
	time : Time.Frame,
	completed : List(Program.CompletionEnvelope(msg)),
	capture : Program.CaptureFromHost,
}

app_config_for_host! : () => AppConfig.HostConfig
app_config_for_host! = || AppConfig.to_host({}, (program.init!.config)(HostHost.args!()))

## Reshape the flat sampled input into the public `Input.Snapshot` record.
##
## Only `gamepads.available` is renamed; the compiler may optimize the rest of
## this into a direct pass-through, which is why the two layouts are kept
## deliberately compatible.
input_from_raw : InputFromHost -> Input.Snapshot
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

## Rebuild a public `Program.Step` after resolving private host completions.
step_from_raw : InputFromHost, Window.Snapshot, Time.Frame, Program.CaptureFromHost, List(msg) -> Program.Step(msg)
step_from_raw = |input, window, time, capture, messages| {
	input: input_from_raw(input),
	window,
	time,
	messages,
	capture: Program.capture_from_host(capture),
}

## Run the app's startup callback with the platform's startup authority.
##
## No input, window, or timing observations have been sampled at this point.
init_for_host! : () => Try(Box(Model), I64)
init_for_host! = ||
	match (program.init!.run!)(App.Startup.from_host(HostHost.Startup.for_host)) {
		Ok(model) => Ok(Box.box(model))
		Err(Exit(code)) => Err(code)
		Err(_) => Err(-1)
	}

## Advance the model by one cycle and hand the host back any work it wants done.
##
## Called once per rendered frame. Applies actions before rendering and returns
## flattened requests for asynchronous host execution. The host assigns private
## tickets while it takes each returned callback envelope into its pending set.
update_for_host! : Box(Model), StepFromHost(Msg) => Try({ model : Box(Model), tasks : List(Program.TaskToHost(Msg)) }, I64)
update_for_host! = |boxed_model, { input, window, time, completed, capture }| {
	messages = resolve_completions(completed)
	step = step_from_raw(input, window, time, capture, messages)
	model = Box.unbox(boxed_model)
	next = (program.update)(model, step)
	next_fields = next.fields()
	# Uploads are the only actions that can be refused, and everything
	# they can be refused for is knowable before any of them run. Check
	# the whole list first so a refusal cannot land after earlier
	# uploads have already changed their textures.
	refuse_unfittable_uploads(next_fields.actions)
	match run_actions!(next_fields.actions, 0) {
		Ok({}) => {
			Ok({
				model: Box.box(next_fields.value),
				tasks: submit_tasks(next_fields.tasks),
			})
		}
		Err(Exit(code)) => Err(code)
		Err(_) => Err(-1)
	}
}

## Invoke every returned completion envelope in the host's observed order.
##
## The host removes an accepted envelope before returning it, so its own ticket
## table detects unknown or duplicate completions. This list is pre-sized and
## preserves that delivery order without intermediate result lists.
resolve_completions : List(Program.CompletionEnvelope(msg)) -> List(msg)
resolve_completions = |completed| {
	var $messages = List.with_capacity(List.len(completed))
	for completion in completed {
		$messages = List.append($messages, Program.complete(completion))
	}
	$messages
}

## Flatten outgoing tasks in one pass. `with_capacity` avoids reallocations;
## each normalized request moves its callback envelope and request-only data to
## the host without retaining the application model in Roc.
submit_tasks : List(Program.Task(msg)) -> List(Program.TaskToHost(msg))
submit_tasks = |requested| {
	var $tasks = List.with_capacity(List.len(requested))
	for task in requested {
		$tasks = List.append($tasks, Program.normalize(task))
	}
	$tasks
}

## Stop the cycle before any of its uploads are applied, if one of them cannot
## be.
##
## Apps can call the same validation through `Program.check_uploads` and defer
## work that does not fit.
refuse_unfittable_uploads : List(Program.Action) -> {}
refuse_unfittable_uploads = |actions|
	match Program.check_uploads(actions) {
		Ok({}) => {}
		Err(PixelCountMismatch) => {
			crash "roc-ray: an UpdateTexture action carried a pixel list that is not exactly width * height for its texture. Check it with Program.check_uploads before returning it."
		}

		Err(RegionOutOfBounds) => {
			crash "roc-ray: an UpdateTextureRegion action named a rectangle that is not inside its texture. Check it with Program.check_uploads before returning it."
		}

		Err(UploadBudgetExceeded) => {
			crash "roc-ray: one cycle's actions ask to upload more than Assets.max_upload_bytes_per_step. Split the work across frames, or check it with Program.check_uploads and defer what does not fit."
		}
	}

## Apply a cycle's actions in order, stopping at the first one that fails.
##
## Index iteration preserves effect order and propagates the first failure.
run_actions! : List(Program.Action), U64 => Try({}, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded, ..])
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
## Actions are interpreted within the platform and do not cross the host ABI.
run_action! : Program.Action => Try({}, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded, ..])
run_action! = |action|
	match action {
		# Deferred rather than immediate, matching `host.exit!`: the host
		# finishes this cycle -- including the draw, and including capturing it
		# -- and shuts down afterwards.
		Exit(code) => Ok(HostHost.exit!(I64.to_i32_wrap(code)))
		SetCursor(cursor) => Ok(MouseHost.set_cursor!(Mouse.cursor_code(cursor)))
		SetCursorMode(mode) => Ok(MouseHost.set_cursor_mode!(Mouse.cursor_mode_code(mode)))
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
		UpdateTexture(request) => Assets.update_texture!(request.texture, request.pixels)
		UpdateTextureRegion(request) => Assets.update_texture_region!(request.texture, request.region)
		SetVirtualMouse(pointer) => Ok(Capture.apply_virtual_mouse!(pointer))
		StartRecording(recording) => Ok(Capture.apply_start!(recording))
		StopRecording => Ok(Capture.apply_stop!())
	}

## Draw the current model, then hand the same box back.
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
