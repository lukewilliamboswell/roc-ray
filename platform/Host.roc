## Host module - provides platform state and system effects
import Keys
import Mouse

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
	mouse : Mouse.State,
}.{

	## Check whether a key is currently held. Receiver form: `host.key_down(KeyW)`.
	key_down : Host, Keys.KeyboardKey -> Bool
	key_down = |host, key| Keys.key_down(host, key)

	## Check whether a key is currently up. Receiver form: `host.key_up(KeyW)`.
	key_up : Host, Keys.KeyboardKey -> Bool
	key_up = |host, key| Keys.key_up(host, key)

	## Check whether a key was pressed this frame.
	key_pressed : Host, Keys.KeyboardKey -> Bool
	key_pressed = |host, key| Keys.key_pressed(host, key)

	## Check whether a key was released this frame.
	key_released : Host, Keys.KeyboardKey -> Bool
	key_released = |host, key| Keys.key_released(host, key)

	ReadFileRawResult : {
		ok : Bool,
		err : U8,
		contents : Str,
	}

	## Exit the application with the given exit code.
	## The exit happens after the current frame completes to allow proper cleanup.
	exit! : I32 => {}

	## Hosted cursor setter. Prefer `set_cursor!` in application code.
	set_cursor_raw! : U8 => {}

	## Set the OS cursor shape.
	set_cursor! : Mouse.Cursor => {}
	set_cursor! = |cursor| Host.set_cursor_raw!(Mouse.cursor_code(cursor))

	## Read an environment variable by key.
	## Returns Ok with the value if found, or Err NotFound if not set.
	read_env_raw! : Str => Try(Str, [NotFound])

	## Read an environment variable by key.
	## Returns Ok with the value if found, or Err NotFound if not set.
	read_env! : Host, Str => Try(Str, [NotFound])
	read_env! = |_host, key|
		match Host.read_env_raw!(key) {
			Ok(value) => Ok(value)
			Err(NotFound) => Err(NotFound)
		}

	## Raw hosted file read. Prefer `read_file!`.
	read_file_raw! : Str => ReadFileRawResult

	## Read a UTF-8 text file from disk.
	read_file! : Str => Try(Str, [NotFound, ReadFailed])
	read_file! = |path| {
		result = Host.read_file_raw!(path)
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

	## Set the window/screen size.
	## Returns Err NotSupported on platforms that don't support window resizing (e.g., web).
	set_screen_size_raw! : { width : F32, height : F32 } => Try({}, [NotSupported])

	## Set the window/screen size.
	## Returns Err NotSupported on platforms that don't support window resizing (e.g., web).
	set_screen_size! : { width : F32, height : F32 } => Try({}, [NotSupported])
	set_screen_size! = |size|
		match Host.set_screen_size_raw!(size) {
			Ok({}) => Ok({})
			Err(NotSupported) => Err(NotSupported)
		}

	## Set raylib's CPU-side frame-rate cap. Values at or below zero render
	## uncapped. This neither selects a software renderer nor controls VSync.
	## Note: On web/WASM, this has no effect as the browser controls frame timing.
	set_target_fps! : I32 => {}
}
