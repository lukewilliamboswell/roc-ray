## Time module - helpers for working with the monotonic clock.
##
## The helpers live in the companion `roc-ray-types` package so reusable
## packages can depend on them without depending on this platform. This module
## re-exports them.
##
## For the common "move per frame" case you can use `step.time.elapsed_seconds`
## directly (seconds since the previous frame) without touching the helpers.
import rrt.Time as RrtTime

Time := [].{

	## When one cycle happened, and how much time it covers.
	Frame : {

		## How many cycles have been completed before this one, counting from
		## zero.
		frame_count : U64,

		## The **simulation** clock in nanoseconds, sampled at the start of this
		## frame. Counts up from window initialization and never goes backwards.
		## Use it for animation, scheduling and fixed-timestep loops, with
		## `Time.to_seconds` to convert a nanosecond duration to seconds.
		##
		## During fixed-step recording, this clock advances by exactly `1/fps`
		## per captured frame. `elapsed_seconds` is this clock's delta.
		timestamp_nanos : U64,

		## Real monotonic time in nanoseconds, whatever the simulation clock is
		## doing. Equal to `timestamp_nanos` unless a fixed-step recording is
		## running, and the one to use for anything that has to line up with the
		## world outside the app -- a network timeout, a frame-time budget, a
		## rate limit.
		##
		## In a headless run both clocks are synthetic, because a headless run
		## exists to produce the same output twice.
		wall_timestamp_nanos : U64,

		## Seconds elapsed on the simulation clock since the previous frame (0
		## on the first frame). Multiply movement by this for frame-rate
		## independent motion, e.g. `x + velocity * step.time.elapsed_seconds`.
		elapsed_seconds : F32,
	}

	## Convert a nanosecond duration to seconds.
	##
	## expect Time.to_seconds(500_000_000) == 0.5
	to_seconds : U64 -> F32
	to_seconds = RrtTime.to_seconds

	## Seconds elapsed between two clock samples (`current` must be >= `previous`).
	## Handy for deriving your own delta from `Time.Frame.timestamp_nanos`:
	##
	##     dt = Time.delta_seconds(model.last_tick, step.time.timestamp_nanos)
	delta_seconds : U64, U64 -> F32
	delta_seconds = RrtTime.delta_seconds
}
