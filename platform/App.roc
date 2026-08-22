## The shape of a RocRay program: its three callbacks, its startup
## configuration, and the input each cycle folds in.
##
## An app provides three callbacks:
##
## ```roc
## program = { init!, update!, render! }
## ```
##
## `init!` runs once, after the window, renderer, and audio device are ready.
## It reads startup configuration, loads the resources the app will hold, and
## returns the first model. Use `App.init` to pair a `Config` with it.
##
## `update!` runs once per host cycle. It receives the model and one
## `App.Input`, calls host effects directly, starts tasks, and returns the next
## model -- or `Err(Exit(code))` to stop the app.
##
## `render!` receives that model and a `Draw.Frame`, and draws. It cannot
## change the model or reach host work of any other kind.
##
## Where an effect may be called: the host knows which callback it is inside,
## and every effect documents the phases it is legal in. Three rules cover
## nearly all of them. An effect that changes host state -- the cursor, the
## window, audio, a recording, a loaded resource -- is legal in `init!`,
## `update!`, and tasks, and refused in `render!`. An effect that draws is
## legal only in `render!`, inside the frame scope the host opens around it.
## An effect that waits -- `Files.read_text!`, `Http.send!`, `Task.sleep!` --
## is legal in `init!`, where it blocks startup, and in tasks, where it parks
## the task while the frame loop keeps drawing, and is refused in `update!`
## and `render!`.
##
## Calling an effect from a phase it does not permit is a programmer error, not
## a runtime outcome: it stops the app at once with a message naming the
## effect, the phase it was called from, and where it belongs.
##
## How messages arrive: work that waits belongs on a task.
## `Task.spawn!(input, || ...)`, from `update!` or from another task, hands the
## host an effectful closure to run on its own stack. When the closure returns,
## its value is delivered as a message on `input.messages` in a later cycle, in
## the order the tasks finished. A task cannot read or write the model, so its
## message is the only thing it can say. See `Task`.
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

import Devices
import Window
import Time
import Audio
import Capture
import Files
import AppHost
import AppTransport
import TaskHost

App := [].{

	## Mutually exclusive frame pacing strategy. Config normalization maps a
	## non-positive `Capped` value to `Uncapped` before a Config can be created.
	FramePacing : AppFramePacing

	## Which key, if any, closes the window. `NoExitKey` disables the behaviour.
	ExitKey : Keys.ExitKey

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
		## This is how an app captures itself with no runtime code at all, so a
		## visualization can be rendered straight to a file. The recording
		## finalizes when it reaches its frame cap, when `Capture.stop!` is
		## called, or when the app exits.
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

	## Opaque, zero-sized authority the host supplies only while it runs `init!`.
	##
	## Every effect that takes a `Startup` is legal only in `init!`. Startup
	## provides one-shot system effects but no input, window, or timing
	## observations: seed models that require devices with `Devices.empty`, and
	## the first `App.Input` supplies the first sampled values. After
	## initialization, change host state by calling effects from `update!`, and
	## ask for work that waits with `Task.spawn!`.
	Startup : HostHost.Startup

	## Exit the application with the given exit code.
	##
	## The exit happens after startup completes, so `init!` finishes and the
	## host shuts down in the ordinary way. Legal only in `init!`.
	exit! : Startup, I32 => {}
	exit! = |_startup, code| HostHost.exit!(code)

	## Return the complete process argument list supplied by the launcher.
	##
	## The first element is `argv[0]`, followed by application-owned arguments
	## in order. The host removes its reserved `--host-*` switches before this
	## list reaches the app. The value is stable for the process lifetime.
	##
	## Legal only in `init!`. `App.init_for_args` is the other way to read
	## argv, before the window exists.
	args! : Startup => List(Str)
	args! = |_startup| HostHost.args!()

	## Read an environment variable by key.
	##
	## Answers `Err(NotFound)` when the variable is not set. Legal only in
	## `init!`.
	read_env! : Startup, Str => Try(Str, [NotFound, ..])
	read_env! = |_startup, key|
		match HostHost.read_env!(key) {
			Ok(value) => Ok(value)
			Err(NotFound) => Err(NotFound)
		}

	## Read a UTF-8 text file from disk, blocking until it is read.
	##
	## Call as `App.read_file!(startup, path)`. Legal only in `init!`; use
	## `Files.read_text!` inside a task to read a file while the app runs, and
	## for the fuller error report.
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

	## Draw one number from the operating system's entropy source.
	##
	## This is the only thing in the platform that makes a run differ from the
	## last one by itself, and it is deliberately the app's decision:
	##
	## ```roc
	## seed = Random.seed(U64.to_u32_wrap(startup.entropy!()))
	## ```
	##
	## Keep the returned `Random.State` in the model and draw with pure
	## `Random.Generator` values during `update!`, so the run is reproducible
	## from its seed. A run that must reproduce writes a constant seed instead
	## and never calls this; a run that should vary calls it once. Nothing else
	## about the platform is affected either way, because the generator's state
	## is the model's rather than the host's.
	##
	## The entropy is real in every mode, including headless: determinism comes
	## from an app choosing a fixed seed, not from the host quietly handing out
	## the same "random" number on every run.
	##
	## Legal only in `init!`.
	entropy! : Startup => U64
	entropy! = |_startup| HostHost.entropy!()

	## Get a varying startup number in the inclusive range `[min, max]`.
	##
	## Legal only in `init!`. `entropy!` is the one to seed a generator from:
	## it draws on the operating system rather than on the backend's own
	## generator, and it says what it is for. This remains for a one-off value
	## in a range, such as a jittered start position that nothing else depends
	## on.
	random_i32! : Startup, I32, I32 => I32
	random_i32! = |_startup, min, max| HostHost.random_i32!(min, max)

	## Suggest positive initial window dimensions to the window manager.
	##
	## Answers `Err(NotSupported)` on a target whose windows cannot be resized.
	## Call as `App.suggest_window_size!(startup, size)`. Legal only in `init!`;
	## a running app resizes itself with `Window.suggest_size!`, which reaches
	## the same host call, and only this spelling can report a refusal.
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

	## Suggest the smallest window size the user can drag the window down to.
	##
	## Each negative dimension is clamped to `0`, which leaves that axis
	## unconstrained. The minimum only applies to a resizable window, so pair it
	## with `App.default.with_resizable(Bool.True)`. Call as
	## `App.suggest_window_min_size!(startup, size)`. Legal only in `init!`.
	suggest_window_min_size! : Startup, { width : I32, height : I32 } => {}
	suggest_window_min_size! = |_startup, size|
		HostHost.suggest_window_min_size!({
			width: if size.width > 0 size.width else 0,
			height: if size.height > 0 size.height else 0,
		})

	## Set raylib's CPU-side frame-rate cap.
	##
	## Values at or below zero render uncapped. This neither selects a software
	## renderer nor controls VSync. Call as `App.set_target_fps!(startup, fps)`.
	## Legal only in `init!`; a running app changes the cap with
	## `Window.set_target_fps!`.
	set_target_fps! : Startup, I32 => {}
	set_target_fps! = |_startup, fps| HostHost.set_target_fps!(fps)

	## Set which key closes the window, or `NoExitKey` to stop any key from
	## closing it.
	##
	## raylib defaults to `ExitKey(KeyEscape)`. The window close button is
	## unaffected either way, so an app that disables the exit key should still
	## handle shutdown itself by returning `Err(Exit(code))`. Call as
	## `App.set_exit_key!(startup, NoExitKey)`. Legal only in `init!`.
	set_exit_key! : Startup, ExitKey => {}
	set_exit_key! = |_startup, key| HostHost.set_exit_key!(Keys.exit_key_code(key))

	## Read UTF-8 text from the system clipboard.
	##
	## Answers `Err(Unavailable)` when the clipboard is empty, holds non-text
	## content, or the windowing backend refuses the request -- the underlying
	## platform does not distinguish these cases. Call as
	## `App.get_clipboard_text!(startup)`. Legal only in `init!`; a running app
	## reads the clipboard with `Window.read_clipboard!`, which names the
	## refusals separately.
	get_clipboard_text! : Startup => Try(Str, [Unavailable, ..])
	get_clipboard_text! = |_startup|
		match HostHost.get_clipboard_text!() {
			Ok(text) => Ok(text)
			Err(Unavailable) => Err(Unavailable)
		}

	## Replace the system clipboard contents with UTF-8 text.
	##
	## Call as `App.set_clipboard_text!(startup, text)`. Legal only in `init!`;
	## a running app writes it with `Window.set_clipboard_text!`.
	set_clipboard_text! : Startup, Str => {}
	set_clipboard_text! = |_startup, text| HostHost.set_clipboard_text!(text)

	## Apply cursor visibility and capture atomically through one tagged
	## operation. Legal only in `init!`; `Mouse.set_cursor_mode!` is the same
	## change from `update!` or a task.
	set_cursor_mode! : Startup, Mouse.CursorMode => {}
	set_cursor_mode! = |_startup, mode| MouseHost.set_cursor_mode!(Mouse.cursor_mode_code(mode))

	## Set the native operating-system cursor shape. Legal only in `init!`;
	## `Mouse.set_cursor!` is the same change from `update!` or a task.
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

	## Everything the host observed for one cycle, handed to `update!`.
	##
	## `messages` contains every task message delivered for this cycle, in the
	## order the tasks finished. Independent tasks may finish in any order; the
	## order they were spawned in does not constrain it.
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
		## ```roc
		## expect
		##     input = App.Input.for_tests({}).with_devices(Devices.none.with_key_pressed(KeyEscape))
		##     decide(model, input) == Quit
		## ```
		##
		## Building the model this is called with is the other half: every host
		## resource an app can hold has a resource-free `stub`
		## (`Draw.Font.stub`, `Audio.Sound.stub`, `Text.Prepared.stub`,
		## `rrt.Texture.stub`, ...), so a `Model` full of assets can be written
		## down in a pure test.
		##
		## `update!` itself is effectful, and an `expect` cannot call it. Keep
		## the decisions in pure functions -- which message to fold in, whether
		## to quit, what work to start -- and test those; `update!` is the thin
		## shell that performs them.
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

		## Deliver task messages on this input, in the order the tasks finished.
		with_messages : Input(msg), List(msg) -> Input(msg)
		with_messages = |Input.(sampled), messages| Input.({ ..sampled, messages: messages })

		## Deliver one more task message on this input, after any already there.
		with_message : Input(msg), msg -> Input(msg)
		with_message = |Input.(sampled), message| Input.({ ..sampled, messages: List.append(sampled.messages, message) })

		## Replace this input's sampled recording status.
		with_capture : Input(msg), Capture.Status -> Input(msg)
		with_capture = |Input.(sampled), capture| Input.({ ..sampled, capture: capture })

		## Start a task whose message this input's own type pins.
		##
		## `Task.spawn!(input, || ...)` is the documented form and calls this;
		## `input.spawn!(|| ...)` reads better when the input is already at
		## hand. Both need the input for the same reason: it is the witness
		## that ties the closure's return type to the app's `Msg`. See
		## `Task.spawn!` for what the input is doing there.
		spawn! : Input(msg), (() => msg) => {}
		spawn! = |_input, task!| TaskHost.spawn!(Box.box(task!))

		## Start a task that answers in a component's own message type, wrapped
		## into this input's.
		##
		## `Task.spawn_with!(input, task!, wrap)` is the documented form and
		## calls this. See it for the component idiom this exists for.
		spawn_with! : Input(msg), (() => a), (a -> msg) => {}
		spawn_with! = |input, task!, wrap| Input.spawn!(input, || wrap(task!()))
	}

	## The window size `Input.for_tests` reports. Ordinary rather than special:
	## a test that depends on the size should say so with `with_window`.
	default_test_size : { width : I32, height : I32 }
	default_test_size = { width: 800, height: 600 }
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

# --- Constructing a Input, so a pure test can exercise an app's update logic ------

## A component's model and message, so the recipe `Input.for_tests` documents is
## exercised here rather than only described. `counter_step` is the pure core
## an app keeps behind its effectful `update!`: it folds the messages in and
## decides what to do, and `update!` performs the decision.
CounterModel : { ticks : U64, quitting : Bool }

CounterMessage : [Tick]

CounterStep : [Quit, Continue(CounterModel)]

fresh_counter : CounterModel
fresh_counter = { ticks: 0, quitting: Bool.False }

counter_step : CounterModel, App.Input(CounterMessage) -> CounterStep
counter_step = |model, input| {
	ticked = List.fold(input.messages, model, |acc, _message| { ..acc, ticks: acc.ticks + 1 })
	if input.devices.key_pressed(KeyEscape) {
		Quit
	} else {
		Continue(ticked)
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

## An ordinary input carries on.
expect counter_step(fresh_counter, neutral_input) == Continue(fresh_counter)

## Delivered messages are folded in, in the order the input carries them.
expect counter_step(fresh_counter, neutral_input.with_messages([Tick, Tick, Tick])) == Continue({ ticks: 3, quitting: Bool.False })
