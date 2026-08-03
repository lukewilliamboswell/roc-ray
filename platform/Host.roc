## Host module - provides platform state and system effects
import Keys
import Mouse
import Gamepad
import HostHost

Host := {
	frame_count : U64,

	## Monotonic clock in nanoseconds, sampled at the start of this frame.
	## Counts up from window initialization and never goes backwards. Use it
	## for absolute timing (animations, scheduling, fixed-timestep loops).
	## See the `Time` module for converting nanosecond durations to seconds.
	timestamp_nanos : U64,

	## Seconds elapsed since the previous frame (0 on the first frame).
	## Multiply movement by this for frame-rate-independent motion, e.g.
	## `x + velocity * host.frame_time`.
	frame_time : F32,

	## Logical drawing dimensions sampled for this frame. These coordinates
	## match mouse input and raylib drawing units; they are not HiDPI framebuffer
	## pixel dimensions.
	screen : { width : I32, height : I32 },

	## Packed per-key state, updated in place by the host. Each byte stores held,
	## pressed-this-frame, and released-this-frame bits. Use the `Keys` helpers.
	keys : List(U8),

	## Unicode codepoints entered this frame, in input order. This is distinct
	## from physical key state and respects the active keyboard layout. Empty
	## frames are allocation-free; a non-empty list requires one variable-size
	## allocation because raylib's text queue length varies from frame to frame.
	## At most 32 codepoints are delivered; excess queued input is drained.
	text_input : List(U32),

	## Gamepad input sampled once per frame. Use the `Gamepad` helpers rather
	## than indexing these persistent flat lists directly.
	gamepads : Gamepad.Snapshot,

	## Mouse buttons, position, delta, and two-axis wheel movement sampled once
	## for this frame. Receiver helpers are available on `Mouse.State`.
	mouse : Mouse.State,
}.{

	## Check whether a key is currently held. Receiver form: `host.key_down(KeyW)`.
	key_down : Host, Keys.KeyboardKey -> Bool
	key_down = |host, key| Keys.key_down(host, key)

	## Check whether a key is currently up. Receiver form: `host.key_up(KeyW)`.
	key_up : Host, Keys.KeyboardKey -> Bool
	key_up = |host, key| Keys.key_up(host, key)

	## Check whether a key was pressed this frame. Receiver form:
	## `host.key_pressed(KeyW)`. Static `Keys.key_pressed(host, KeyW)` remains
	## available; combine singular queries with `or` when checking alternatives.
	key_pressed : Host, Keys.KeyboardKey -> Bool
	key_pressed = |host, key| Keys.key_pressed(host, key)

	## Check whether a key was released this frame. Receiver form:
	## `host.key_released(KeyW)`. Static `Keys.key_released(host, KeyW)` remains.
	key_released : Host, Keys.KeyboardKey -> Bool
	key_released = |host, key| Keys.key_released(host, key)

	## Exit the application with the given exit code.
	## The exit happens after the current frame completes to allow proper cleanup.
	exit! : I32 => {}
	exit! = |code| HostHost.exit!(code)

	## Read an environment variable by key.
	## Returns Ok with the value if found, or Err NotFound if not set.
	read_env! : Host, Str => Try(Str, [NotFound])
	read_env! = |_host, key|
		match HostHost.read_env!(key) {
			Ok(value) => Ok(value)
			Err(NotFound) => Err(NotFound)
		}

	## Read a UTF-8 text file from disk.
	read_file! : Str => Try(Str, [NotFound, ReadFailed])
	read_file! = |path| {
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
	## `if Host.random_i32!(0, 1) == 0 -1 else 1`.
	random_i32! : I32, I32 => I32
	random_i32! = |min, max| HostHost.random_i32!(min, max)

	## Set the window/screen size.
	## Returns Err NotSupported on platforms that don't support window resizing (e.g., web).
	set_screen_size! : { width : F32, height : F32 } => Try({}, [NotSupported])
	set_screen_size! = |size|
		match HostHost.set_screen_size!(size) {
			Ok({}) => Ok({})
			Err(NotSupported) => Err(NotSupported)
		}

	## Set raylib's CPU-side frame-rate cap. Values at or below zero render
	## uncapped. This neither selects a software renderer nor controls VSync.
	## Note: On web/WASM, this has no effect as the browser controls frame timing.
	set_target_fps! : I32 => {}
	set_target_fps! = |fps| HostHost.set_target_fps!(fps)
}
