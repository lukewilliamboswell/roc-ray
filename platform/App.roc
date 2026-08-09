## Application startup configuration and model initialization.
##
## Use `App.init` when startup needs effects such as loading host-owned assets.
## The callback runs after the window, renderer, and audio device are ready.
import HostHost
import Keys
import Mouse
import MouseHost
import rrt.Capture as RrtCapture

AppFramePacing := [VSync, Capped(I32), Uncapped].{
	is_eq : _
}

AppCursorMode := [CursorVisible, CursorHidden].{
	is_eq : _
}

AppRecording := [NoRecording, Record(RrtCapture.Recording)].{
	is_eq : _
}

App := [].{

	## Mutually exclusive frame pacing strategy. Config normalization maps a
	## non-positive `Capped` value to `Uncapped` before a Config can be created.
	FramePacing : AppFramePacing

	## Initial native cursor mode.
	CursorMode : AppCursorMode

	## Which key, if any, closes the window. `NoExitKey` disables the behaviour.
	ExitKey : Keys.ExitKey

	## Whether the host starts recording before the first frame. `Record` makes
	## an app capture itself with no runtime code, which is how a visualization
	## can be rendered straight to a file.
	Recording : AppRecording

	## Validated startup configuration. Its fields cannot be updated directly;
	## use its receiver updates so startup invariants are preserved.
	Config :: {
		title : Str,
		width : I32,
		height : I32,
		min_width : I32,
		min_height : I32,
		frame_pacing : AppFramePacing,
		resizable : Bool,
		fullscreen : Bool,
		cursor : AppCursorMode,
		exit_key : Keys.ExitKey,
		visible : Bool,
		output_dir : Str,
		recording : AppRecording,
	}.{

		## Return a config with a different window title.
		with_title : Config, Str -> Config
		with_title = |cfg, value| { ..cfg, title: value }

		## Return a config with different initial logical dimensions. Each
		## non-positive dimension independently falls back to the 800x600 default.
		with_size : Config, { width : I32, height : I32 } -> Config
		with_size = |cfg, dims| {
			..cfg,
			width: normalize_dimension(dims.width, default_width),
			height: normalize_dimension(dims.height, default_height),
		}

		## Return a config with a minimum window size the user cannot shrink
		## past. Each negative dimension is clamped to `0`, which means "no
		## limit" in that axis. A minimum only takes effect on a resizable
		## window, so pair this with `with_resizable(Bool.True)`.
		with_min_size : Config, { width : I32, height : I32 } -> Config
		with_min_size = |cfg, dims| {
			..cfg,
			min_width: normalize_min_dimension(dims.width),
			min_height: normalize_min_dimension(dims.height),
		}

		## Return a config with a validated frame-pacing strategy.
		with_frame_pacing : Config, FramePacing -> Config
		with_frame_pacing = |cfg, value| { ..cfg, frame_pacing: normalize_pacing(value) }

		## Return a config with a different exit key. `NoExitKey` stops any key
		## from closing the window; the window close button still works.
		with_exit_key : Config, ExitKey -> Config
		with_exit_key = |cfg, value| { ..cfg, exit_key: value }

		## Return a config with a different initial cursor mode.
		with_cursor : Config, CursorMode -> Config
		with_cursor = |cfg, value| { ..cfg, cursor: value }

		## Return a config that enables or disables native window resizing.
		with_resizable : Config, Bool -> Config
		with_resizable = |cfg, value| { ..cfg, resizable: value }

		## Return a config that starts in or out of fullscreen mode.
		with_fullscreen : Config, Bool -> Config
		with_fullscreen = |cfg, value| { ..cfg, fullscreen: value }

		## Return a config whose window is shown or hidden at startup.
		##
		## A hidden window still renders on the GPU, so `Capture` works exactly
		## as it does with a visible one -- useful for rendering a chart or a
		## short clip to a file without a window appearing. This is not the same
		## as the host's `--headless` flag, which draws nothing at all, and it
		## still needs a display server (wrap it in `xvfb-run` on a machine
		## without one).
		with_visible : Config, Bool -> Config
		with_visible = |cfg, value| { ..cfg, visible: value }

		## Return a config whose captures are written under a different
		## directory, created on first use.
		##
		## Every `Capture` path resolves beneath this directory, and one that
		## would escape it -- an absolute path, or one containing `..` -- is
		## refused rather than rewritten. The directory itself is the app
		## author's choice and is used as given, so it may be absolute; what it
		## bounds is where the paths an app computes at runtime can reach. An
		## empty value means the working directory.
		with_output_dir : Config, Str -> Config
		with_output_dir = |cfg, value| { ..cfg, output_dir: value }

		## Return a config that starts recording before the first frame.
		##
		## The recording finalizes when it reaches its frame cap, when
		## a `Capture.stop` action is applied, or when the app exits.
		with_recording : Config, Recording -> Config
		with_recording = |cfg, value| { ..cfg, recording: value }

		## Inspect the window title.
		title : Config -> Str
		title = |cfg| cfg.title

		## Inspect the initial logical window dimensions.
		size : Config -> { width : I32, height : I32 }
		size = |cfg| { width: cfg.width, height: cfg.height }

		## Inspect the minimum window size. A `0` in either axis means the
		## window is unconstrained in that direction.
		min_size : Config -> { width : I32, height : I32 }
		min_size = |cfg| { width: cfg.min_width, height: cfg.min_height }

		## Inspect the selected frame-pacing strategy.
		frame_pacing : Config -> FramePacing
		frame_pacing = |cfg| cfg.frame_pacing

		## Inspect the selected initial cursor mode.
		cursor : Config -> CursorMode
		cursor = |cfg| cfg.cursor

		## Inspect whether the window is natively resizable.
		resizable : Config -> Bool
		resizable = |cfg| cfg.resizable

		## Inspect whether the window starts fullscreen.
		fullscreen : Config -> Bool
		fullscreen = |cfg| cfg.fullscreen

		## Inspect the selected exit key.
		exit_key : Config -> ExitKey
		exit_key = |cfg| cfg.exit_key

		## Inspect whether the window is shown at startup.
		visible : Config -> Bool
		visible = |cfg| cfg.visible

		## Inspect the directory captures are written under.
		output_dir : Config -> Str
		output_dir = |cfg| cfg.output_dir

		## Inspect whether the app records itself from startup.
		recording : Config -> Recording
		recording = |cfg| cfg.recording
	}

	## Opaque, zero-sized authority supplied only while the host runs `init!`.
	##
	## Startup provides one-shot system effects but no input, window, or timing
	## observations. Seed models that require input with `Input.empty`; the first
	## `Program.Step` supplies the first sampled values. After initialization,
	## request effects with `Program.Action` or `Program.Task` values.
	Startup :: HostHost.Startup.{

		## Wrap the host's startup token. Internal to the platform adapter.
		from_host : HostHost.Startup -> Startup
		from_host = |startup| Startup.(startup)

		## Exit the application with the given exit code.
		## The exit happens after startup completes to allow proper cleanup.
		exit! : Startup, I32 => {}
		exit! = |_startup, code| HostHost.exit!(code)

		## Read an environment variable by key.
		## Returns Ok with the value if found, or Err NotFound if not set.
		read_env! : Startup, Str => Try(Str, [NotFound, ..])
		read_env! = |_startup, key|
			match HostHost.read_env!(key) {
				Ok(value) => Ok(value)
				Err(NotFound) => Err(NotFound)
			}

		## Read a UTF-8 text file from disk.
		## Receiver form: `startup.read_file!(path)`.
		read_file! : Startup, Str => Try(Str, [NotFound, ReadFailed, ..])
		read_file! = |_startup, path| {
			result = HostHost.read_file!(path)
			if result.ok {
				Ok(result.contents)
			} else if result.err == 1 {
				Err(NotFound)
			} else {
				Err(ReadFailed)
			}
		}

		## Get a random integer in the range [min, max] (both endpoints included).
		## The generator is seeded once at startup, so sequences differ between runs.
		## Derive other ranges/floats from this, e.g. a random direction with
		## `if startup.random_i32!(0, 1) == 0 -1 else 1`.
		random_i32! : Startup, I32, I32 => I32
		random_i32! = |_startup, min, max| HostHost.random_i32!(min, max)

		## Set the window/screen size to positive integer dimensions.
		## Returns Err NotSupported on platforms that don't support window resizing.
		## Receiver form: `startup.set_screen_size!(size)`.
		set_screen_size! : Startup, { width : I32, height : I32 } => Try({}, [InvalidSize, NotSupported, ..])
		set_screen_size! = |_startup, size|
			if size.width <= 0 or size.height <= 0 {
				Err(InvalidSize)
			} else {
				match HostHost.set_screen_size!(size) {
					Ok({}) => Ok({})
					Err(NotSupported) => Err(NotSupported)
				}
			}

		## Set the smallest window size the user can drag the window down to. Each
		## negative dimension is clamped to `0`, which leaves that axis
		## unconstrained. The minimum only applies to a resizable window, so pair it
		## with `App.default.with_resizable(Bool.True)`.
		## Receiver form: `startup.set_window_min_size!(size)`.
		set_window_min_size! : Startup, { width : I32, height : I32 } => {}
		set_window_min_size! = |_startup, size|
			HostHost.set_window_min_size!({
				width: if size.width > 0 size.width else 0,
				height: if size.height > 0 size.height else 0,
			})

		## Set raylib's CPU-side frame-rate cap. Values at or below zero render
		## uncapped. This neither selects a software renderer nor controls VSync.
		## Receiver form: `startup.set_target_fps!(fps)`.
		set_target_fps! : Startup, I32 => {}
		set_target_fps! = |_startup, fps| HostHost.set_target_fps!(fps)

		## Set which key closes the window, or `NoExitKey` to stop any key from
		## closing it. raylib defaults to `ExitKey(KeyEscape)`. The window close
		## button is unaffected either way, so an app that disables the exit key
		## should still handle shutdown through `Program.exit`.
		## Receiver form: `startup.set_exit_key!(NoExitKey)`.
		set_exit_key! : Startup, ExitKey => {}
		set_exit_key! = |_startup, key| HostHost.set_exit_key!(Keys.exit_key_code(key))

		## Read UTF-8 text from the system clipboard.
		## Returns `Err(Unavailable)` when the clipboard is empty, holds non-text
		## content, or the windowing backend refuses the request -- the underlying
		## platform does not distinguish these cases.
		## Receiver form: `startup.get_clipboard_text!()`.
		get_clipboard_text! : Startup => Try(Str, [Unavailable, ..])
		get_clipboard_text! = |_startup|
			match HostHost.get_clipboard_text!() {
				Ok(text) => Ok(text)
				Err(Unavailable) => Err(Unavailable)
			}

		## Replace the system clipboard contents with UTF-8 text.
		## Receiver form: `startup.set_clipboard_text!(text)`.
		set_clipboard_text! : Startup, Str => {}
		set_clipboard_text! = |_startup, text| HostHost.set_clipboard_text!(text)

		## Apply cursor visibility/capture atomically through one tagged operation.
		set_cursor_mode! : Startup, Mouse.CursorMode => {}
		set_cursor_mode! = |_startup, mode| MouseHost.set_cursor_mode!(Mouse.cursor_mode_code(mode))

		## Set the native operating-system cursor shape.
		set_cursor! : Startup, Mouse.Cursor => {}
		set_cursor! = |_startup, cursor| MouseHost.set_cursor!(Mouse.cursor_code(cursor))
	}

	## Effectful startup callback run after the host has initialized raylib and
	## audio. Return `Ok(model)` to start the app, `Err(Exit(code))` to quit
	## before the first frame, or let other initialization errors propagate.
	InitCallback(model, errors) : Startup => Try(model, [Exit(I64), ..errors])

	## Startup configuration paired with an effectful model initializer.
	Init(model, errors) : {
		config : Config,
		run! : InitCallback(model, errors),
	}

	## Default 800x600 window configuration capped at 240 FPS.
	default : Config
	default = {
		title: "Roc + Raylib",
		width: default_width,
		height: default_height,
		min_width: 0,
		min_height: 0,
		frame_pacing: Capped(240),
		resizable: Bool.False,
		fullscreen: Bool.False,
		cursor: CursorVisible,
		exit_key: ExitKey(KeyEscape),
		visible: Bool.True,
		output_dir: ".",
		recording: NoRecording,
	}

	## Build app initialization from pure startup config plus the effectful
	## callback that creates the first model after raylib/audio are ready.
	init : Config, InitCallback(model, errors) -> Init(model, errors)
	init = |cfg, callback!| { config: cfg, run!: callback! }

}

default_width : I32
default_width = 800

default_height : I32
default_height = 600

normalize_pacing : AppFramePacing -> AppFramePacing
normalize_pacing = |value|
	match value {
		Capped(fps) => if fps <= 0 Uncapped else value
		_ => value
	}

normalize_dimension : I32, I32 -> I32
normalize_dimension = |value, fallback| if value > 0 value else fallback

## Unlike `normalize_dimension`, `0` is a meaningful minimum: raylib maps it to
## GLFW_DONT_CARE, leaving that axis unconstrained. Only negatives are clamped.
normalize_min_dimension : I32 -> I32
normalize_min_dimension = |value| if value > 0 value else 0

expect App.default.with_frame_pacing(VSync).frame_pacing() == VSync
expect App.default.with_frame_pacing(Capped(-5)).frame_pacing() == Uncapped
expect App.default.with_cursor(CursorHidden).cursor() == CursorHidden
expect App.default.with_title("Test").title() == "Test"
expect App.default.size() == { width: 800, height: 600 }
expect App.default.with_size({ width: 320, height: 240 }).size() == { width: 320, height: 240 }
expect App.default.with_size({ width: 0, height: -5 }).size() == { width: 800, height: 600 }
expect App.default.with_size({ width: -1, height: 720 }).size() == { width: 800, height: 720 }
expect App.default.min_size() == { width: 0, height: 0 }
expect App.default.with_min_size({ width: 400, height: 300 }).min_size() == { width: 400, height: 300 }
expect App.default.with_min_size({ width: -1, height: -20 }).min_size() == { width: 0, height: 0 }
expect App.default.exit_key() == ExitKey(KeyEscape)
expect App.default.with_exit_key(NoExitKey).exit_key() == NoExitKey
expect App.default.with_resizable(Bool.True).resizable()
expect App.default.with_fullscreen(Bool.True).fullscreen()
expect App.default.visible()
expect !(App.default.with_visible(Bool.False).visible())
expect App.default.output_dir() == "."
expect App.default.with_output_dir("captures").output_dir() == "captures"
expect App.default.recording() == NoRecording
expect App.default.with_recording(Record(RrtCapture.default)).recording() == Record(RrtCapture.default)
