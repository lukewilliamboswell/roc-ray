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
	exposes [Draw, Text, Color, Input, Window, Keys, Mouse, Gamepad, Time, Audio, App, Assets, Math, Camera, Sprite, Tilemap, Physics, Capture, Program, TaskQueue, Random]
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
		"roc_draw_draw_texture_instances_raw": DrawHost.draw_texture_instances!,
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
import TaskQueue
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
##
## Writing to a collection held in the model copies it. The box arrives holding
## the model's only reference -- measured at refcount 1 on entry -- but
## unboxing borrows rather than consumes and the box lives until this scope
## ends, so `update` runs with the model's lists referenced more than once and
## the first write to one allocates a whole new list. Measured at exactly one
## copy per frame for a million-element `List(F32)`, 4,000,000 bytes, by
## `test/model_inplace` under `scripts/test_model_allocation.py`. Writes after
## the first, within the same cycle, are in place: the copy is unique.
update_for_host! : Box(Model), StepFromHost(Msg) => Try({ model : Box(Model), tasks : List(Program.TaskToHost(Msg)) }, I64)
update_for_host! = |boxed_model, { input, window, time, completed, capture }| {
	messages = resolve_completions(completed)
	step = step_from_raw(input, window, time, capture, messages)
	model = Box.unbox(boxed_model)
	next = (program.update)(model, step)
	next_fields = next.fields()
	# A malformed upload is a programmer error, and every one of them is
	# knowable before any action runs. Check the whole list first so the app
	# stops without having applied half a cycle. Running out of upload budget
	# is not one of these: that is a runtime limit, handled in order below.
	refuse_unfittable_uploads(next_fields.actions)
	run_actions!(next_fields.actions, 0, 0)
	Ok({
		model: Box.box(next_fields.value),
		tasks: submit_tasks(next_fields.tasks),
	})
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

## Stop the cycle before any action runs if one of its uploads is malformed.
##
## Only the two programmer errors stop the app. An upload that does not fit in
## the cycle's byte budget is skipped in order by `run_actions!`, along with
## every upload after it, so `Program.check_uploads` stopping at that same first
## refusal reports exactly what the app will get.
refuse_unfittable_uploads : List(Program.Action) -> {}
refuse_unfittable_uploads = |actions|
	match Program.check_uploads(actions) {
		Ok({}) => {}
		Err(PixelCountMismatch) => refuse_upload(PixelCountMismatch)
		Err(RegionOutOfBounds) => refuse_upload(RegionOutOfBounds)
		Err(UploadBudgetExceeded) => {}
	}

## Name the programmer error an upload was refused for, and stop.
##
## These are cheap to find before returning the action -- `Program.check_uploads`
## reports both -- and there is no sensible way to carry on past one: the app
## asked to write pixels somewhere they do not fit.
refuse_upload : [PixelCountMismatch, RegionOutOfBounds] -> {}
refuse_upload = |reason|
	match reason {
		PixelCountMismatch => {
			crash "roc-ray: an UpdateTexture action carried a pixel list that is not exactly width * height for its texture. Check it with Program.check_uploads before returning it."
		}

		RegionOutOfBounds => {
			crash "roc-ray: an UpdateTextureRegion action named a rectangle that is not inside its texture. Check it with Program.check_uploads before returning it."
		}
	}

## Apply a cycle's actions in order, skipping uploads that do not fit.
##
## Index iteration preserves effect order. `charged` is the upload bytes this
## cycle has already spent; `Program.place_upload` decides whether the next
## action fits and carries the running total on. Once an upload has been
## refused the total is past the budget, so every later upload is skipped too
## and its texture keeps the contents it had. Actions that are not uploads run
## regardless, before, between, and after.
run_actions! : List(Program.Action), U64, U64 => {}
run_actions! = |actions, index, charged|
	if index >= List.len(actions) {
		{}
	} else {
		match List.get(actions, index) {
			Ok(action) => {
				placement = Program.place_upload(action, charged)
				if placement.apply {
					run_action!(action)
				} else {
					{}
				}
				run_actions!(actions, index + 1, placement.charged)
			}

			# Unreachable: the index is bounded above.
			Err(_) => {}
		}
	}

## Apply one action through the effect it stands for.
##
## Actions are interpreted within the platform and do not cross the host ABI,
## and none of them reports anything back: an action that could fail either
## stops the app (a malformed upload, refused above) or is silently skipped (an
## upload with no budget left). Outcomes an app needs to observe arrive on a
## later `Step` instead -- `step.capture` for recordings, a task for reads.
run_action! : Program.Action => {}
run_action! = |action|
	match action {
		# Deferred rather than immediate, matching `host.exit!`: the host
		# finishes this cycle -- including the draw, and including capturing it
		# -- and shuts down afterwards.
		Exit(code) => HostHost.exit!(I64.to_i32_wrap(code))
		SetCursor(cursor) => MouseHost.set_cursor!(Mouse.cursor_code(cursor))
		SetCursorMode(mode) => MouseHost.set_cursor_mode!(Mouse.cursor_mode_code(mode))
		SetClipboardText(text) => HostHost.set_clipboard_text!(text)
		SetExitKey(key) => HostHost.set_exit_key!(Keys.exit_key_code(key))
		# A window with no area has no drawing space to report back, so a
		# non-positive dimension is ignored rather than passed on.
		SetWindowSize(size) =>
			if size.width > 0 and size.height > 0 {
				match HostHost.set_screen_size!(size) {
					Ok({}) => {}
					Err(NotSupported) => {}
				}
			} else {
				{}
			}

		SetWindowMinSize(size) =>
			HostHost.set_window_min_size!({
				width: if size.width > 0 size.width else 0,
				height: if size.height > 0 size.height else 0,
			})

		SetTargetFps(fps) => HostHost.set_target_fps!(fps)
		PlaySound(settings) => settings.play!()
		StopSound(sound) => sound.stop!()
		PauseSound(sound) => sound.pause!()
		ResumeSound(sound) => sound.resume!()
		PlayMusic(music) => music.play!()
		StopMusic(music) => music.stop!()
		PauseMusic(music) => music.pause!()
		ResumeMusic(music) => music.resume!()
		SetMusicVolume(request) => request.music.set_volume!(request.volume)
		SetMusicPitch(request) => request.music.set_pitch!(request.pitch)
		SetMusicPan(request) => request.music.set_pan!(request.pan)
		SetMusicLooping(request) => request.music.set_looping!(request.looping)
		SeekMusic(request) => request.music.seek!(request.seconds)
		SetMasterVolume(volume) => Audio.set_master_volume!(volume)
		UpdateTexture(request) => settle_upload(Assets.update_texture!(request.texture, request.pixels))
		UpdateTextureRegion(request) => settle_upload(Assets.update_texture_region!(request.texture, request.region))
		SetTextureFilter(request) => Assets.set_texture_filter!(request.texture, request.filter)
		SetTextureWrap(request) => Assets.set_texture_wrap!(request.texture, request.wrap)
		SetVirtualMouse(pointer) => Capture.apply_virtual_mouse!(pointer)
		StartRecording(recording) => Capture.apply_start!(recording)
		StopRecording => Capture.apply_stop!()
	}

## Take the host's answer to an upload that was already cleared to run.
##
## The host refuses an over-budget upload rather than aborting on one, and this
## cycle's budget gate has already skipped the ones that do not fit, so a
## refusal for budget here means the host's accounting and Roc's disagree by a
## byte somewhere. Skipping is still the answer: a lost upload is never a reason
## to stop the app.
##
## The other two are the programmer errors `refuse_unfittable_uploads` reports.
## Reaching one here means the texture's real dimensions are not the ones the
## `Texture` value carries -- an upload aimed at something that cannot take it.
settle_upload : Try({}, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded, ..]) -> {}
settle_upload = |result|
	match result {
		Ok({}) => {}
		Err(UploadBudgetExceeded) => {}
		Err(RegionOutOfBounds) => refuse_upload(RegionOutOfBounds)
		Err(_) => refuse_upload(PixelCountMismatch)
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
