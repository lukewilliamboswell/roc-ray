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
	keys : List(U8),
	mouse : {
		left : Bool,
		middle : Bool,
		right : Bool,
		wheel : F32,
		x : F32,
		y : F32,
	},
}.{
	ScreenSize : { width : I32, height : I32 }

	## Exit the application with the given exit code.
	## The exit happens after the current frame completes to allow proper cleanup.
	exit! : I32 => {}

	## Get the current screen/window dimensions.
	get_screen_size! : () => ScreenSize

	## Read an environment variable by key.
	## Returns Ok with the value if found, or Err NotFound if not set.
	read_env! : Host, Str => Try(Str, [NotFound, ..])

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
