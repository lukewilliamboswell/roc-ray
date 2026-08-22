## Helpers for working with the cycle's simulation clock.
##
## Animation and physics use `input.time`, not wall time. The host samples one
## `Cycle` per call to `update!`, and every app that moves something should
## derive that movement from it: a value read from the calendar or a
## wall-clock timer is not the timeline the platform paces, replays, or holds
## to a fixed step while a capture records.
##
## For the common "move per cycle" case, use `input.time.elapsed_seconds`
## directly -- simulation seconds since the preceding input -- without touching
## the helpers below.
##
## The helpers live in the companion `roc-ray-types` package so reusable
## packages can depend on them without depending on this platform. This module
## re-exports them.
import rrt.Time as RrtTime

Time := [].{

	## When one cycle happened, and how much time it covers.
	Cycle : RrtTime.Cycle

	## The cycle an app starts on: count zero, no elapsed time.
	##
	## `App.Input.for_tests` uses it, and a test that needs a second cycle says
	## so: `input.with_time({ ..Time.first_cycle, cycle_count: 1 })`.
	first_cycle : Cycle
	first_cycle = RrtTime.first_cycle

	## Convert a nanosecond duration to seconds.
	##
	## expect Time.to_seconds(500_000_000) == 0.5
	to_seconds : U64 -> F32
	to_seconds = RrtTime.to_seconds

	## Seconds elapsed between two clock samples. The second must not be earlier
	## than the first.
	##
	## Handy for deriving a delta over more than one cycle from
	## `Time.Cycle.simulation_nanos`:
	##
	##     dt = Time.delta_seconds(model.last_tick, input.time.simulation_nanos)
	delta_seconds : U64, U64 -> F32
	delta_seconds = RrtTime.delta_seconds
}
