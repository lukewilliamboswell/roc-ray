## Time module - helpers for working with the monotonic clock.
##
## The helpers live in the companion `roc-ray-types` package so reusable
## packages can depend on them without depending on this platform. This module
## re-exports them.
##
## For the common "move per cycle" case you can use `input.time.elapsed_seconds`
## directly (simulation seconds since the previous input) without touching the helpers.
import rrt.Time as RrtTime

Time := [].{

	## When one cycle happened, and how much time it covers.
	Cycle : RrtTime.Cycle

	first_cycle : Cycle
	first_cycle = RrtTime.first_cycle

	## Convert a nanosecond duration to seconds.
	##
	## expect Time.to_seconds(500_000_000) == 0.5
	to_seconds : U64 -> F32
	to_seconds = RrtTime.to_seconds

	## Seconds elapsed between two clock samples (`current` must be >= `previous`).
	## Handy for deriving your own delta from `Time.Cycle.simulation_nanos`:
	##
	##     dt = Time.delta_seconds(model.last_tick, input.time.timestamp_nanos)
	delta_seconds : U64, U64 -> F32
	delta_seconds = RrtTime.delta_seconds
}
