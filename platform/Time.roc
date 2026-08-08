## Time module - helpers for working with the monotonic clock.
##
## The helpers live in the companion `roc-ray-types` package so reusable
## packages can depend on them without depending on this platform. This module
## re-exports them.
##
## For the common "move per frame" case you can use `step.time.elapsed_seconds`
## directly (seconds since the previous frame) without touching the helpers.
##
## Receivers are documented in the [roc-ray-types docs](../types/),
## which is where the nominal is declared.
import rrt.Time as RrtTime

Time := [].{

	## When one cycle happened, and how much time it covers.
	##
	## This is the only place a cycle's timing lives. It used to be duplicated
	## between the step and the input snapshot, which meant two values that
	## could disagree and one of them silently winning.
	Frame : {

		## How many cycles have been completed before this one, counting from
		## zero.
		frame_count : U64,

		## The **simulation** clock in nanoseconds, sampled at the start of this
		## frame. Counts up from window initialization and never goes backwards.
		## Use it for animation, scheduling and fixed-timestep loops, with
		## `Time.to_seconds` to convert a nanosecond duration to seconds.
		##
		## Simulation, not wall: a fixed-step recording substitutes an exact
		## delta so the captured animation is smooth and reproducible, and this
		## clock advances by that delta rather than by however long the frame
		## really took. That is what makes a recording play back at the rate it
		## was asked for. `elapsed_seconds` is this clock's delta.
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

	## Running a simulation on fixed ticks needs no platform support, and
	## deliberately gets none. Keep an accumulator in the model, add
	## `elapsed_seconds` to it inside `update`, and run a pure step for each
	## whole tick it has paid for -- zero, one, or several -- capping the
	## catch-up so a stalled frame cannot spiral. `examples/snake.roc` is that
	## loop in about fifteen lines.
	##
	## One outer `update` per frame is what makes it cheap: the model crosses
	## the boundary once however many ticks ran inside. Ticks cannot be run at
	## exact wall-clock instants while rendering shares this thread -- if a
	## frame stalls, the ticks catch up afterwards -- and anything stronger
	## would need a second simulation thread and a different ownership story.
	##
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
