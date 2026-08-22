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

AppRecording := [NoRecording, Record(RrtCapture.Recording)].{
	is_eq : _
}

## `Delay` uses wall time. Animation and physics should use `input.time`.
import Devices
import Window
import Time
import Audio
import Capture
import Files
import AppHost
import AppTransport

App := [].{

	## Mutually exclusive frame pacing strategy. Config normalization maps a
	## non-positive `Capped` value to `Uncapped` before a Config can be created.
	FramePacing : AppFramePacing

	## Which key, if any, closes the window. `NoExitKey` disables the behaviour.
	ExitKey : Keys.ExitKey

	## Whether the host starts recording before the first frame. `Record` makes
	## an app capture itself with no runtime code, which is how a visualization
	## can be rendered straight to a file.
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
		cursor : Mouse.CursorMode,
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
		with_cursor_mode : Config, Mouse.CursorMode -> Config
		with_cursor_mode = |cfg, value| { ..cfg, cursor: value }

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
		## as the host's `--host-headless` flag, which draws nothing at all, and it
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
		## `Capture.stop!` is called, or when the app exits.
		with_recording : Config, Capture.Recording -> Config
		with_recording = |cfg, value| { ..cfg, recording: Record(value) }

		## Return a config with startup recording disabled.
		without_recording : Config -> Config
		without_recording = |cfg| { ..cfg, recording: NoRecording }

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
		cursor_mode : Config -> Mouse.CursorMode
		cursor_mode = |cfg| cfg.cursor

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
		recording : Config -> [NoRecording, Record(Capture.Recording)]
		recording = |cfg| cfg.recording
	}

	## Opaque, zero-sized authority supplied only while the host runs `init!`.
	##
	## Startup provides one-shot system effects but no input, window, or timing
	## observations. Seed models that require devices with `Devices.empty`; the first
	## `App.Input` supplies the first sampled values. After initialization,
	## change host state by calling effects from `update!`, and ask for deferred
	## work with `App.request!` and `Task.spawn!`.
	Startup : HostHost.Startup

	## Exit the application with the given exit code.
	## The exit happens after startup completes to allow proper cleanup.
	exit! : Startup, I32 => {}
	exit! = |_startup, code| HostHost.exit!(code)

	## Return the complete process argument list supplied by the launcher.
	##
	## The first element is `argv[0]`, followed by application-owned arguments
	## in order. The host removes its reserved `--host-*` switches before this
	## list reaches the app. The value is stable for the process lifetime.
	args! : Startup => List(Str)
	args! = |_startup| HostHost.args!()

	## Read an environment variable by key.
	## Returns Ok with the value if found, or Err NotFound if not set.
	read_env! : Startup, Str => Try(Str, [NotFound, ..])
	read_env! = |_startup, key|
		match HostHost.read_env!(key) {
			Ok(value) => Ok(value)
			Err(NotFound) => Err(NotFound)
		}

	## Read a UTF-8 text file from disk.
	## Call as `App.read_file!(startup, path)`.
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

	## Get varying startup entropy in the inclusive range `[min, max]`.
	##
	## For simulation or gameplay, call this once and initialize the exposed
	## `roc-random` package with, for example,
	## `Random.seed(I32.to_u32_wrap(startup.random_i32!(0, 2000000000)))`.
	## Keep that `Random.State` in the model and use pure `Random.Generator`
	## values during `update`, so draws are reproducible from the initial seed.
	random_i32! : Startup, I32, I32 => I32
	random_i32! = |_startup, min, max| HostHost.random_i32!(min, max)

	## Suggest positive initial window dimensions to the window manager.
	## Returns Err NotSupported on platforms that don't support window resizing.
	## Call as `App.suggest_window_size!(startup, size)`.
	##
	## A running app resizes itself with `Window.suggest_size!`, which reaches
	## the same host call; only this spelling can report a refusal.
	suggest_window_size! : Startup, { width : I32, height : I32 } => Try({}, [InvalidSize, NotSupported, ..])
	suggest_window_size! = |_startup, size|
		if size.width <= 0 or size.height <= 0 {
			Err(InvalidSize)
		} else {
			match HostHost.suggest_window_size!(size) {
				Ok({}) => Ok({})
				Err(NotSupported) => Err(NotSupported)
			}
		}

	## Suggest the smallest window size the user can drag the window down to. Each
	## negative dimension is clamped to `0`, which leaves that axis
	## unconstrained. The minimum only applies to a resizable window, so pair it
	## with `App.default.with_resizable(Bool.True)`.
	## Call as `App.suggest_window_min_size!(startup, size)`.
	suggest_window_min_size! : Startup, { width : I32, height : I32 } => {}
	suggest_window_min_size! = |_startup, size|
		HostHost.suggest_window_min_size!({
			width: if size.width > 0 size.width else 0,
			height: if size.height > 0 size.height else 0,
		})

	## Set raylib's CPU-side frame-rate cap. Values at or below zero render
	## uncapped. This neither selects a software renderer nor controls VSync.
	## Call as `App.set_target_fps!(startup, fps)`.
	##
	## A running app changes the cap with `Window.set_target_fps!`.
	set_target_fps! : Startup, I32 => {}
	set_target_fps! = |_startup, fps| HostHost.set_target_fps!(fps)

	## Set which key closes the window, or `NoExitKey` to stop any key from
	## closing it. raylib defaults to `ExitKey(KeyEscape)`. The window close
	## button is unaffected either way, so an app that disables the exit key
	## should still handle shutdown itself by returning `Err(Exit(code))`.
	## Call as `App.set_exit_key!(startup, NoExitKey)`.
	set_exit_key! : Startup, ExitKey => {}
	set_exit_key! = |_startup, key| HostHost.set_exit_key!(Keys.exit_key_code(key))

	## Read UTF-8 text from the system clipboard.
	## Returns `Err(Unavailable)` when the clipboard is empty, holds non-text
	## content, or the windowing backend refuses the request -- the underlying
	## platform does not distinguish these cases.
	## Call as `App.get_clipboard_text!(startup)`.
	get_clipboard_text! : Startup => Try(Str, [Unavailable, ..])
	get_clipboard_text! = |_startup|
		match HostHost.get_clipboard_text!() {
			Ok(text) => Ok(text)
			Err(Unavailable) => Err(Unavailable)
		}

	## Replace the system clipboard contents with UTF-8 text.
	## Call as `App.set_clipboard_text!(startup, text)`.
	set_clipboard_text! : Startup, Str => {}
	set_clipboard_text! = |_startup, text| HostHost.set_clipboard_text!(text)

	## Apply cursor visibility/capture atomically through one tagged operation.
	set_cursor_mode! : Startup, Mouse.CursorMode => {}
	set_cursor_mode! = |_startup, mode| MouseHost.set_cursor_mode!(Mouse.cursor_mode_code(mode))

	## Set the native operating-system cursor shape.
	set_cursor! : Startup, Mouse.Cursor => {}
	set_cursor! = |_startup, cursor| MouseHost.set_cursor!(Mouse.cursor_code(cursor))

	## Effectful startup callback run after the host has initialized raylib and
	## audio. Return `Ok(model)` to start the app, `Err(Exit(code))` to quit
	## before the first frame, or let other initialization errors propagate.
	InitCallback(model, errors) : Startup => Try(model, [Exit(I64), ..errors])

	## Pure startup configuration chosen from the complete process argv before
	## the host creates its native window. This is where an app can opt into a
	## hidden recording mode based on its own command-line flags.
	ConfigForArgs : List(Str) -> Config

	## Startup configuration paired with an effectful model initializer.
	Init(model, errors) : {
		config : ConfigForArgs,
		run! : InitCallback(model, errors),
	}

	## Default 800x600 window configuration capped at 240 FPS.
	default : Config
	default = {
		title: "RocRay",
		width: default_width,
		height: default_height,
		min_width: 0,
		min_height: 0,
		frame_pacing: Capped(240),
		resizable: Bool.False,
		fullscreen: Bool.False,
		cursor: Visible,
		exit_key: ExitKey(KeyEscape),
		visible: Bool.True,
		output_dir: ".",
		recording: NoRecording,
	}

	## Build initialization from a static startup configuration.
	init : Config, InitCallback(model, errors) -> Init(model, errors)
	init = |config, callback!| { config: |_args| config, run!: callback! }

	## Build initialization from an argv-aware startup configuration.
	init_for_args : ConfigForArgs, InitCallback(model, errors) -> Init(model, errors)
	init_for_args = |config_for_args, callback!| { config: config_for_args, run!: callback! }

	## Everything the host observed since the previous cycle.
	##
	## `messages` contains all request responses received for this cycle, in the
	## order the host observed their responses. Independent asynchronous requests
	## may complete in any order; their submission order does not constrain it.
	## `capture` contains the recording status sampled for this cycle.
	Input(msg) := {
		devices : Devices.Snapshot,
		window : Window.Snapshot,
		time : Time.Cycle,
		messages : List(msg),
		capture : Capture.Status,
	}.{

		## Return the complete structural input for platform-independent libraries.
		fields : Input(msg) -> {
			devices : Devices.Snapshot,
			window : Window.Snapshot,
			time : Time.Cycle,
			messages : List(msg),
			capture : Capture.Status,
		}
		fields = |input| input

		## Build an input by stating every sampled field at once.
		##
		## This is the from-scratch constructor; `for_tests` is the one to reach
		## for when only a field or two matters, since it supplies neutral values
		## for the rest.
		##
		## Pass a structural record written out here. Use `fields` when reading an
		## existing input and the `with_*` receivers when changing one field.
		from_fields : {
			devices : Devices.Snapshot,
			window : Window.Snapshot,
			time : Time.Cycle,
			messages : List(msg),
			capture : Capture.Status,
		} -> Input(msg)
		from_fields = |sampled| Input.(sampled)

		## A neutral input for testing an app's pure update logic from an `expect`.
		##
		## Nothing is pressed, the window is an ordinary focused
		## `default_test_size`, the clock reads zero on its first cycle, no
		## messages arrived, and nothing is recording. Customize it with the
		## `with_*` receivers, which is what makes a test say only the one thing
		## it is about:
		##
		##     expect
		##         input = App.Input.for_tests({}).with_devices(Devices.none.with_key_pressed(KeyEscape))
		##         decide(model, input) == Quit
		##
		## Building the model this is called with is the other half: every host
		## resource an app can hold has a resource-free `stub`
		## (`Draw.Font.stub`, `Audio.Sound.stub`, `Text.Prepared.stub`,
		## `rrt.Texture.stub`, ...), so a `Model` full of assets can be written
		## down in a pure test.
		##
		## `update!` itself is effectful, and an `expect` cannot call it. Keep
		## the decisions in pure functions -- which message to fold in, whether
		## to quit, what to request -- and test those; `update!` is the thin
		## shell that performs them. Assert on requests with
		## `App.request_description`.
		for_tests : {} -> Input(msg)
		for_tests = |{}|
			Input.(
				{
					devices: Devices.none,
					window: { size: App.default_test_size, focused: Bool.True, minimized: Bool.False },
					time: Time.first_cycle,
					messages: [],
					capture: Idle,
				},
			)

		## Replace this input's sampled device snapshot. Build one from `Devices.none`.
		with_devices : Input(msg), Devices.Snapshot -> Input(msg)
		with_devices = |Input.(sampled), devices| Input.({ ..sampled, devices: devices })

		## Replace this input's sampled window geometry and visibility.
		with_window : Input(msg), Window.Snapshot -> Input(msg)
		with_window = |Input.(sampled), window| Input.({ ..sampled, window: window })

		## Replace this input's clock sample. Use it to drive a second cycle:
		## `input.with_time({ ..Time.first_cycle, cycle_count: 1 })`.
		with_time : Input(msg), Time.Cycle -> Input(msg)
		with_time = |Input.(sampled), time| Input.({ ..sampled, time: time })

		## Deliver request responses on this input, in the order the host observed
		## them. These are the app's own messages, not `Request` values.
		with_messages : Input(msg), List(msg) -> Input(msg)
		with_messages = |Input.(sampled), messages| Input.({ ..sampled, messages: messages })

		## Deliver one more request response on this input, after any already there.
		with_message : Input(msg), msg -> Input(msg)
		with_message = |Input.(sampled), message| Input.({ ..sampled, messages: List.append(sampled.messages, message) })

		## Replace this input's sampled recording status.
		with_capture : Input(msg), Capture.Status -> Input(msg)
		with_capture = |Input.(sampled), capture| Input.({ ..sampled, capture: capture })
	}

	## The window size `Input.for_tests` reports. Ordinary rather than special:
	## a test that depends on the size should say so with `with_window`.
	default_test_size : { width : I32, height : I32 }
	default_test_size = { width: 800, height: 600 }

	## Hand the host a request. It is answered on a later `Input.messages`.
	##
	##     App.request!(Files.read_text("save.json", |result| SaveLoaded(result)))
	##
	## Valid during `update!` and inside a task. Every accepted request gets
	## exactly one terminal response, including `Err(Busy)` when the host's
	## in-flight capacity is exhausted.
	request! : Request(msg) => {}
	request! = |request| AppHost.submit_request!(AppTransport.normalize(request))

	## Work for the host to do, answered later. Returning one never blocks.
	##
	## A request owns the typed function that turns its one terminal result into the
	## application's message. The platform retains that function privately until
	## the matching host response arrives. Request tickets are transport-only and
	## are not part of the supported application API.
	##
	## Platform wrappers capture only the response mapper supplied here, never the model
	## or request-only data. The mapper itself retains every value it captures,
	## however, so prefer small stable context or generation values over capturing
	## an entire model for work that may remain pending.
	##
	## `ReadText` returns a UTF-8 `Str` and rejects files above its inline
	## copy limit. `ReadBytes` returns ordinary Roc bytes for files up to the
	## host's 16 MiB per-file limit. The worker allocation becomes a seamless
	## `List(U8)` view, so delivery allocates and copies no payload bytes.
	## `Screenshot` captures the end of the frame that submitted it.
	Request(msg) : AppHost.Request(msg)

	## What a `Request` asks for, with its response mapper left out.
	##
	## A `Request` holds a function, so `==` cannot compare two of them and no test
	## can assert on one directly. `RequestDescription` is the same request as ordinary
	## data -- no functions, no host resources -- so it derives `==` and prints
	## in a failing `expect`.
	RequestDescription : [
		ReadText({ path : Str }),
		ReadBytes({ path : Str }),
		Delay({ millis : U64 }),
		Screenshot({ path : Str }),
		ReadClipboard,
		ListDirectory({ path : Str }),
	]

	## Describe what a request asks the host for, without its response mapper.
	##
	## This is the supported way to assert on the requests an `update` returned:
	##
	##     result = update(model, input)
	##     expect List.map(result.fields().requests, App.request_description) == [
	##         Delay({ millis: 200 }),
	##         ReadText({ path: "save.json" }),
	##     ]
	##
	## Comparing `Request` values themselves is not possible -- each one owns a
	## response-mapping function, and equality cannot inspect a function. Deriving `==`
	## over a union that reaches a host-resource `Box` is refused for its own
	## reason, as a "type does not support equality" error naming every variant.
	## Reducing the request to its request first sidesteps both.
	##
	## Wrapping a request's message with `App.map_request` rewrites only the
	## response mapper, so a mapped request keeps the description it had.
	request_description : Request(msg) -> RequestDescription
	request_description = |request|
		match request {
			ReadText({ path, callback: _ }) => ReadText({ path: path })
			ReadBytes({ path, callback: _ }) => ReadBytes({ path: path })
			Delay({ millis, callback: _ }) => Delay({ millis: millis })
			Screenshot({ path, callback: _ }) => Screenshot({ path: path })
			ReadClipboard({ callback: _ }) => ReadClipboard
			ListDirectory({ path, callback: _ }) => ListDirectory({ path: path })
		}

	## Lift a request's message into an enclosing application's message type.
	##
	## The request still asks the host for exactly the same work; only its
	## response mapper is wrapped. This is the piece that lets a reusable
	## component own requests: the component builds `Request(ChildMsg)` values
	## and the parent submits `App.map_request(request, |inner| Child(inner))`.
	map_request : Request(a), (a -> b) -> Request(b)
	map_request = |request, transform| map_request_impl(request, transform)
}

map_request_impl : App.Request(a), (a -> b) -> App.Request(b)
map_request_impl = |request, transform|
	match request {
		ReadText({ path, callback }) => ReadText({ path, callback: |result| transform(callback(result)) })
		ReadBytes({ path, callback }) => ReadBytes({ path, callback: |result| transform(callback(result)) })
		Delay({ millis, callback }) => Delay({ millis, callback: |result| transform(callback(result)) })
		Screenshot({ path, callback }) => Screenshot({ path, callback: |result| transform(callback(result)) })
		ReadClipboard({ callback }) => ReadClipboard({ callback: |result| transform(callback(result)) })
		ListDirectory({ path, callback }) => ListDirectory({ path, callback: |result| transform(callback(result)) })
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
expect App.default.with_cursor_mode(Hidden).cursor_mode() == Hidden
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
expect App.default.with_recording(RrtCapture.default).recording() == Record(RrtCapture.default)

## `kind` code for a finished small-file read. Mirrored in `src/host_native.zig`.
completion_small_file_read : U8
completion_small_file_read = 0

## `kind` code for an elapsed delay. Mirrored in `src/host_native.zig`.
completion_delay : U8
completion_delay = 1

## `kind` code for a serviced screenshot. Mirrored in `src/host_native.zig`.
completion_screenshot_finished : U8
completion_screenshot_finished = 2

## `kind` code for a clipboard read. Mirrored in `src/host_native.zig`.
completion_clipboard_read : U8
completion_clipboard_read = 3

## `kind` code for an ordinary byte-list read. Mirrored in
## `src/host_native.zig`.
completion_file_read : U8
completion_file_read = 4

## `kind` code for a serviced directory listing. Mirrored in `src/host_native.zig`.
completion_dir_listed : U8
completion_dir_listed = 5

## `kind` code for a small-file read request. Mirrored in `src/host_native.zig`.
request_read_small_file : U8
request_read_small_file = 0

## `kind` code for a delay request. Mirrored in `src/host_native.zig`.
request_delay : U8
request_delay = 1

## `kind` code for a screenshot request. Mirrored in `src/host_native.zig`.
request_screenshot : U8
request_screenshot = 2

## `kind` code for a clipboard-read request. Mirrored in `src/host_native.zig`.
request_read_clipboard : U8
request_read_clipboard = 3

## `kind` code for an ordinary byte-list read request. Mirrored in `src/host_native.zig`.
request_read_file : U8
request_read_file = 4

## `kind` code for a directory listing request. Mirrored in `src/host_native.zig`.
request_list_dir : U8
request_list_dir = 5

## Entry kinds in an encoded listing. Mirrored in `src/host_native.zig`.
dir_entry_file : U8
dir_entry_file = 1

dir_entry_dir : U8
dir_entry_dir = 2

## The host refused to list the path because it is not a directory. Mirrored in
## `src/host_native.zig`.
read_err_not_a_directory : U8
read_err_not_a_directory = 7

## Decode the host's listing-error code. Mirrored in `src/host_native.zig`.
list_error : U8 -> Files.ListError
list_error = |code|
	if code == 1 {
		NotFound
	} else if code == read_err_busy {
		Busy
	} else if code == 4 {
		Unavailable
	} else if code == read_err_too_large {
		TooLarge
	} else if code == read_err_not_a_directory {
		NotADirectory
	} else {
		ReadFailed
	}

## Decode a listing's bytes into entries.
##
## The encoding is one entry after another, each a kind byte, the entry's name,
## and a NUL. A name cannot contain a NUL on any platform the host runs on, so
## the terminator is unambiguous and the whole listing is one host allocation
## that reached Roc without being copied.
##
## Truncated input -- a kind byte with no terminator after it -- ends the
## listing rather than being guessed at. The host writes the terminator, so
## that cannot happen; answering with the entries that were whole is what keeps
## this total.
decode_listing : List(U8) -> List(Files.Entry)
decode_listing = |bytes| decode_entries(bytes, 0, [])

decode_entries : List(U8), U64, List(Files.Entry) -> List(Files.Entry)
decode_entries = |bytes, at, found|
	if at >= List.len(bytes) {
		found
	} else {
		match List.get(bytes, at) {
			Err(_) => found
			Ok(code) =>
				match index_of_nul(bytes, at + 1) {
					Err(_) => found
					Ok(end) =>
						decode_entries(
							bytes,
							end + 1,
							List.append(found, { name: entry_name(bytes, at + 1, end), kind: entry_kind(code) }),
						)
					}
			}
	}

## Copy one entry's name out of the listing.
##
## The copy is the point. A sublist of a host-delivered list is a seamless view
## onto the host's buffer, so a name retained that way would pin the whole
## listing for as long as the app held it. `release_excess_capacity` gives the
## name storage of its own -- and it has to happen before `from_utf8_lossy`,
## which may share the storage it is given.
entry_name : List(U8), U64, U64 -> Str
entry_name = |bytes, start, end|
	Str.from_utf8_lossy(List.release_excess_capacity(List.sublist(bytes, { start: start, len: end - start })))

entry_kind : U8 -> Files.EntryKind
entry_kind = |code|
	if code == dir_entry_file {
		File
	} else if code == dir_entry_dir {
		Dir
	} else {
		Other
	}

index_of_nul : List(U8), U64 -> Try(U64, [NotFound])
index_of_nul = |bytes, at|
	match List.get(bytes, at) {
		Err(_) => Err(NotFound)
		Ok(byte) =>
			if byte == 0 {
				Ok(at)
			} else {
				index_of_nul(bytes, at + 1)
			}
		}

## Decode the host's clipboard-error code. Mirrored in `src/host_native.zig`.
##
## Named rather than spelled inline, so the same code path every other decoder
## takes is testable the same way they are.
clipboard_error : U8 -> [Unavailable, TooLarge, Busy]
clipboard_error = |code|
	if code == read_err_too_large {
		TooLarge
	} else if code == read_err_busy {
		Busy
	} else {
		Unavailable
	}

## `status` code for a running recording. Mirrored in `src/capture.zig`.
capture_status_active : U8
capture_status_active = 1

## `status` code for a recording that stopped early. Mirrored in `src/capture.zig`.
capture_status_failed : U8
capture_status_failed = 2

## `status` code for a recording that ran to its end and wrote its file.
## Mirrored in `src/capture.zig`.
capture_status_finished : U8
capture_status_finished = 3

## Error code for content the host declined to copy into a `Str`.
## Mirrored in `src/host_native.zig`.
read_err_too_large : U8
read_err_too_large = 5

## Error code for work the host would not start. Mirrored in
## `src/host_native.zig`.
read_err_busy : U8
read_err_busy = 3

## Error code for bytes that cannot become a `Str`. Mirrored in
## `src/host_native.zig`.
read_err_not_utf8 : U8
read_err_not_utf8 = 6

## Decode the host's read-error code for a byte-list read. Mirrored in
## `src/host_native.zig`.
read_error : U8 -> Files.ReadBytesError
read_error = |code|
	if code == 1 {
		NotFound
	} else if code == read_err_busy {
		Busy
	} else if code == 4 {
		Unavailable
	} else if code == read_err_too_large {
		TooLarge
	} else {
		ReadFailed
	}

## Decode the host's read-error code for a string-delivered read.
##
## The same codes plus one, rather than a second table: the two reads fail for
## the same reasons and only differ in what they were asked to produce.
small_file_error : U8 -> Files.ReadTextError
small_file_error = |code|
	if code == read_err_not_utf8 {
		NotUtf8
	} else {
		match read_error(code) {
			NotFound => NotFound
			Busy => Busy
			Unavailable => Unavailable
			TooLarge => TooLarge
			ReadFailed => ReadFailed
		}
	}

## Decode the host's capture-error code for a screenshot.
##
## These are `src/capture.zig`'s codes, the same ones `Capture.screenshot!`
## names, so a path that escapes the output directory is still reported as the
## sandbox refusing it rather than as a failed write.
screenshot_error : U8 -> Capture.ScreenshotError
screenshot_error = |code|
	match code {
		1 => PathInvalid
		2 => PathEscapesOutputDir
		3 => AlreadyPending
		7 => WriteFailed
		10 => Busy
		11 => Unavailable
		_ => WriteFailed
	}

## Name every failure code a recording can latch -- a start the host refused as
## well as a running recording that stopped early.
capture_failure : U8 -> Capture.FailureReason
capture_failure = |code|
	match code {
		1 => PathInvalid
		2 => PathEscapesOutputDir
		3 => AlreadyRecording
		5 => UnsupportedFormat
		6 => BudgetExceeded
		7 => OutOfMemory
		8 => WriteFailed
		9 => EncodeFailed
		_ => Unknown
	}

## A component's own message type, which knows nothing about the application
## that embeds it.
string_result_message : Try(Str, Files.ReadTextError) -> Str
string_result_message = |result|
	match result {
		Ok(contents) => contents
		Err(_) => "failed"
	}

unit_result_message : Try({}, [Busy]) -> Str
unit_result_message = |result|
	match result {
		Ok({}) => "elapsed"
		Err(Busy) => "busy"
	}

ChildMessage : [Loaded(Str), LoadFailed, Elapsed, Overloaded]

## The embedding application's message type, which wraps the component's.
ParentMessage : [Child(ChildMessage)]

child_small_file_message : Try(Str, Files.ReadTextError) -> ChildMessage
child_small_file_message = |result|
	match result {
		Ok(contents) => Loaded(contents)
		Err(_) => LoadFailed
	}

child_delay_message : Try({}, [Busy]) -> ChildMessage
child_delay_message = |result|
	match result {
		Ok({}) => Elapsed
		Err(Busy) => Overloaded
	}

## What a component asks for, before its parent knows anything about it.
child_requests : List(App.Request(ChildMessage))
child_requests = [
	Time.delay(9, child_delay_message),
	Files.read_text("child.txt", child_small_file_message),
]

parent_requests : List(App.Request(ParentMessage))
parent_requests = List.map(child_requests, |request| App.map_request(request, |child| Child(child)))

## `map_request` touches only the messages. The requests' work and order are
## the component's.
expect List.map(parent_requests, App.request_description) == [Delay({ millis: 9 }), ReadText({ path: "child.txt" })]

## `RequestDescription` is ordinary data, so `==` works on it where it cannot work on a
## `Request`. This is the assertion an app's own tests are meant to make.
expect App.request_description(Files.read_text("save.json", string_result_message)) == ReadText({ path: "save.json" })
expect App.request_description(Files.read_bytes("level.bin", |_| "file")) == ReadBytes({ path: "level.bin" })
expect App.request_description(Time.delay(250, unit_result_message)) == Delay({ millis: 250 })
expect App.request_description(Capture.screenshot("scene.png", |_| "screenshot")) == Screenshot({ path: "scene.png" })
expect App.request_description(Window.read_clipboard(|_| "clipboard")) == ReadClipboard
expect App.request_description(Files.list("assets", |_| "listed")) == ListDirectory({ path: "assets" })

# --- Directory listings -----------------------------------------------------

## The encoding the host writes, spelled out: a kind byte, a name, a NUL, and
## the next entry straight after it.
listing_sample : List(U8)
listing_sample =
	List.concat(
		List.concat([dir_entry_file], List.concat(Str.to_utf8("a.txt"), [0])),
		List.concat([dir_entry_dir], List.concat(Str.to_utf8("nested"), [0])),
	)

expect
	decode_listing(listing_sample)
		== [
			{ name: "a.txt", kind: File },
			{ name: "nested", kind: Dir },
		]

## An empty directory is no bytes, which is no entries rather than a failure.
expect decode_listing([]) == []

## An entry kind the host has not defined is `Other` rather than a crash: it is
## how symbolic links, devices and sockets already arrive.
expect decode_listing([9, 120, 0]) == [{ name: "x", kind: Other }]

## A name that is not UTF-8 still names something, so it is replaced rather than
## dropped -- a walk that skipped such entries would silently miss files.
expect List.len(decode_listing([dir_entry_file, 0xff, 0])) == 1

## A truncated listing ends at the last whole entry. The host always writes the
## terminator, so this is about `decode_listing` being total, not about input
## that occurs.
expect decode_listing(List.concat(listing_sample, [dir_entry_file, 122])) == decode_listing(listing_sample)

## An entry with an empty name is still an entry.
expect decode_listing([dir_entry_dir, 0]) == [{ name: "", kind: Dir }]

expect list_error(1) == NotFound
expect list_error(read_err_not_a_directory) == NotADirectory
expect list_error(read_err_busy) == Busy
expect list_error(4) == Unavailable
expect list_error(read_err_too_large) == TooLarge
expect list_error(2) == ReadFailed

## Every code the host can send decodes to something, and only `0` means success
## -- which never reaches here.
expect List.all([1, 2, 3, 4, 5, 6, 7, 8, 200], |code| list_error_is_named(code))

list_error_is_named : U8 -> Bool
list_error_is_named = |code|
	match list_error(code) {
		NotFound => Bool.True
		NotADirectory => Bool.True
		Busy => Bool.True
		Unavailable => Bool.True
		TooLarge => Bool.True
		ReadFailed => Bool.True
	}

## The equality discriminates, rather than agreeing with everything.
expect App.request_description(Time.delay(250, unit_result_message)) != Delay({ millis: 251 })
expect App.request_description(Files.read_text("a.txt", string_result_message)) != App.request_description(Files.read_text("b.txt", string_result_message))

## Mapping rewrites the response mapper and nothing else, so the description is an identity
## a parent can assert on without knowing the component's message type.
expect App.request_description(App.map_request(Time.delay(250, unit_result_message), |inner| Loaded(inner))) == Delay({ millis: 250 })
expect App.request_description(App.map_request(Window.read_clipboard(|_| "clipboard"), |inner| Loaded(inner))) == ReadClipboard

## A file is arbitrary bytes and a `Str` is UTF-8. Only the read that answers
## with a string can report this, which is why the two reads no longer share one
## error type.
expect small_file_error(read_err_not_utf8) == NotUtf8
expect small_file_error(1) == NotFound
expect small_file_error(2) == ReadFailed
expect small_file_error(4) == Unavailable
expect small_file_error(read_err_too_large) == TooLarge
expect read_error(1) == NotFound
expect read_error(2) == ReadFailed
expect read_error(4) == Unavailable
expect read_error(read_err_too_large) == TooLarge
expect screenshot_error(2) == PathEscapesOutputDir
expect screenshot_error(99) == WriteFailed
expect screenshot_error(3) == AlreadyPending
expect clipboard_error(4) == Unavailable

## Another process decides how much text the clipboard holds, so the host
## thread refuses to copy an unbounded one rather than stalling on it.
expect clipboard_error(read_err_too_large) == TooLarge

## Saturation is its own answer everywhere it can happen. A clipboard the host
## would not read yet is not an `Unavailable` one, and a screenshot it would
## not start is not one this app already had outstanding. Each of those would
## send an app looking for a fault that is not there, instead of asking again
## next cycle.
expect clipboard_error(read_err_busy) == Busy
expect small_file_error(read_err_busy) == Busy
expect read_error(read_err_busy) == Busy
expect screenshot_error(10) == Busy

## A screenshot the worker had no room for is refused rather than encoded on
## the host. Both of these mean the file was not written, and the
## difference between them is whether asking again is worth anything.
expect screenshot_error(11) == Unavailable

# --- Constructing a Input, so a pure test can exercise an app's update logic ------

## A component's model and message, so the recipe `Input.for_tests` documents is
## exercised here rather than only described. `counter_step` is the pure core
## an app keeps behind its effectful `update!`: it folds the messages in and
## decides what to do, and `update!` performs the decision.
CounterModel : { ticks : U64, quitting : Bool }

CounterMessage : [Tick]

CounterStep : [Quit, Continue(CounterModel, List(App.RequestDescription))]

fresh_counter : CounterModel
fresh_counter = { ticks: 0, quitting: Bool.False }

counter_step : CounterModel, App.Input(CounterMessage) -> CounterStep
counter_step = |model, input| {
	ticked = List.fold(input.messages, model, |acc, _message| { ..acc, ticks: acc.ticks + 1 })
	if input.devices.key_pressed(KeyEscape) {
		Quit
	} else {
		Continue(ticked, [App.request_description(Time.delay(16, |_result| Tick))])
	}
}

## The neutral input, named once so the assertions below read as differences
## from it rather than as a dozen separate constructions.
neutral_input : App.Input(CounterMessage)
neutral_input = App.Input.for_tests({})

## Every field of the neutral input, stated. A default nobody can see is a
## default nobody can rely on.
expect neutral_input.messages == []
expect neutral_input.capture == Idle
expect neutral_input.time == Time.first_cycle
expect neutral_input.window == { size: { width: 800, height: 600 }, focused: Bool.True, minimized: Bool.False }
expect !(neutral_input.devices.key_pressed(KeyEscape))
expect !(neutral_input.devices.mouse.button_down(Left))
expect neutral_input.devices.gamepad(One) == Disconnected

## The neutral input is `Devices.none`, so it is writable: this is the property
## that makes "SPACE was pressed this input" expressible at all.
expect neutral_input.with_devices(Devices.none.with_key_pressed(KeySpace)).devices.key_pressed(KeySpace)

## Each `with_*` replaces one field and leaves the rest of the sample alone.
expect neutral_input.with_messages([Tick, Tick]).messages == [Tick, Tick]
expect neutral_input.with_message(Tick).with_message(Tick).messages == [Tick, Tick]
expect neutral_input.with_time({ ..Time.first_cycle, cycle_count: 7, elapsed_seconds: 0.25 }).time.cycle_count == 7
expect neutral_input.with_window({ size: { width: 320, height: 240 }, focused: Bool.False, minimized: Bool.True }).window.size == { width: 320, height: 240 }
expect neutral_input.with_capture(Active({ frames: 3, dropped: 0 })).capture == Active({ frames: 3, dropped: 0 })
expect neutral_input.with_messages([Tick]).window == neutral_input.window
expect neutral_input.with_capture(Finished({ frames: 30, bytes: 4096 })).time == neutral_input.time

## `from_fields` states the whole sample at once, for a test that would rather
## write every field down than start from `for_tests` and override.
expect
	App.Input.from_fields({
		devices: Devices.none.with_key_pressed(KeyEscape),
		window: { size: { width: 320, height: 240 }, focused: Bool.False, minimized: Bool.True },
		time: Time.first_cycle,
		messages: [Tick],
		capture: Idle,
	})
		.messages
		== [Tick]

## Escape decides to shut down.
expect counter_step(fresh_counter, neutral_input.with_devices(Devices.none.with_key_pressed(KeyEscape))) == Quit

## An ordinary input asks for one delay.
expect counter_step(fresh_counter, neutral_input) == Continue(fresh_counter, [Delay({ millis: 16 })])

## Delivered messages are folded in, in the order the input carries them.
expect counter_step(fresh_counter, neutral_input.with_messages([Tick, Tick, Tick])) == Continue({ ticks: 3, quitting: Bool.False }, [Delay({ millis: 16 })])
