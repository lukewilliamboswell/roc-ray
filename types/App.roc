## The complete input folded by one `update!` call.
##
## `Input(msg)` contains sampled devices, window state, simulation time, task
## messages, capture status, and dropped-file events. It is pure data;
## `for_tests` constructs a neutral input without a host.
##
## The platform's `App` re-exports these, so an app writes `App.Input(Msg)` and
## never depends on this package directly. `msg` is the app's own message type;
## the platform's `requires` block binds it, which is what makes an `Input(msg)`
## parameter the witness that pins a task's return type. Starting a task is an
## effect and lives in the platform's `Task`.
import Capture
import Devices
import Time
import Window

App := [].{

	## One file dropped onto the window, and where the pointer was when it
	## landed.
	##
	## The path is the one the window system reported, absolute on every
	## platform. Reading the file is a separate, waiting effect, so a drop is
	## handled by starting a task:
	##
	## ```roc
	## Task.spawn!(input, || Opened(Files.read_bytes!(drop.path)))
	## ```
	##
	## `position` is the pointer position the host sampled for the cycle the
	## drop arrived on, in the same logical coordinates as
	## `input.devices.mouse.position()`, so an app that has more than one drop
	## target can tell which one the file landed on.
	Dropped : { path : Str, position : { x : F32, y : F32 } }

	## Everything the host observed for one cycle, handed to `update!`.
	##
	## `messages` contains every task message delivered for this cycle, in the
	## order the tasks finished. Independent tasks may finish in any order; the
	## order they were spawned in does not constrain it.
	## `capture` contains the recording status sampled for this cycle.
	##
	## `dropped` contains the files dropped onto the window since the previous
	## input, in the order the window system reported them. Like a key press it
	## is an interval event rather than a latest value: it is empty on almost
	## every cycle, and exactly one call to `update!` sees any given drop. At
	## most 64 paths are delivered per cycle; a single drop carrying more has
	## its extra paths discarded, and `dropped_overflow` says so.
	Input(msg) := {
		devices : Devices.Snapshot,
		window : Window.Snapshot,
		time : Time.Cycle,
		messages : List(msg),
		capture : Capture.Status,
		dropped : List(Dropped),
		dropped_overflow : Bool,
	}.{

		## Return the complete structural input for platform-independent libraries.
		fields : Input(msg) -> {
			devices : Devices.Snapshot,
			window : Window.Snapshot,
			time : Time.Cycle,
			messages : List(msg),
			capture : Capture.Status,
			dropped : List(Dropped),
			dropped_overflow : Bool,
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
			dropped : List(Dropped),
			dropped_overflow : Bool,
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
		## (`Text.font_stub`, `Audio.Sound.stub`, `Text.Prepared.stub`,
		## `Assets.Texture.stub`, ...), so a `Model` full of assets can be written
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
					dropped: [],
					dropped_overflow: Bool.False,
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

		## Deliver files dropped onto the window on this input.
		with_dropped : Input(msg), List(Dropped) -> Input(msg)
		with_dropped = |Input.(sampled), dropped| Input.({ ..sampled, dropped: dropped })

		## Say that this cycle's drop carried more paths than the host delivers,
		## which is what `input.dropped_overflow` reports.
		with_dropped_overflow : Input(msg), Bool -> Input(msg)
		with_dropped_overflow = |Input.(sampled), overflowed| Input.({ ..sampled, dropped_overflow: overflowed })
	}

	## The window size `Input.for_tests` reports. Ordinary rather than special:
	## a test that depends on the size should say so with `with_window`.
	default_test_size : { width : I32, height : I32 }
	default_test_size = { width: 800, height: 600 }
}
