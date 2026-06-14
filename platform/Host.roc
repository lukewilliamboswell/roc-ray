## Host module - provides platform state and system effects

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

	## Per-key held state: 1 while the key is down, 0 otherwise.
	## Use with `Keys.key_down` / `Keys.key_up`.
	keys : List(U8),

	## Per-key edge state: 1 only on the frame the key was first pressed
	## (respecting key-repeat), 0 otherwise. Use with `Keys.key_pressed` for
	## one-shot actions like menu/restart where holding shouldn't re-trigger.
	keys_pressed : List(U8),

	## Per-key release edge state: 1 only on the frame the key was released,
	## 0 otherwise. Use with `Keys.key_released`.
	keys_released : List(U8),
	mouse : {

		## Per-button held state for raylib mouse button codes 0-6.
		## Prefer the `Mouse` module helpers for new code.
		buttons : List(U8),

		## Per-button press edge state. Use with `Mouse.button_pressed`.
		buttons_pressed : List(U8),

		## Per-button release edge state. Use with `Mouse.button_released`.
		buttons_released : List(U8),

		left : Bool,
		middle : Bool,
		right : Bool,
		wheel : F32,
		x : F32,
		y : F32,
	},
}.{
	ScreenSize : { width : I32, height : I32 }

	ReadFileRawResult : {
		ok : Bool,
		err : U8,
		contents : Str,
	}

	## Exit the application with the given exit code.
	## The exit happens after the current frame completes to allow proper cleanup.
	exit! : I32 => {}

	## Get the current screen/window dimensions.
	get_screen_size! : () => ScreenSize

	## Read an environment variable by key.
	## Returns Ok with the value if found, or Err NotFound if not set.
	read_env! : Host, Str => Try(Str, [NotFound, ..])

	## Raw hosted file read. Prefer `read_file!`.
	read_file_raw! : Str => ReadFileRawResult

	## Read a UTF-8 text file from disk.
	read_file! : Str => Try(Str, [NotFound, ReadFailed, ..])
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
	set_screen_size! : { width : F32, height : F32 } => Try({}, [NotSupported, ..])

	## Set the target frames per second for the render loop.
	## Note: On web/WASM, this has no effect as the browser controls frame timing.
	set_target_fps! : I32 => {}
}
