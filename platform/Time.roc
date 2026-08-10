## Time module - helpers for working with the monotonic clock.
##
## The helpers live in the companion `roc-ray-types` package so reusable
## packages can depend on them without depending on this platform. This module
## re-exports them.
##
## For the common "move per frame" case you can use `Host.frame_time` directly
## (seconds since the previous frame) without touching this module.
##
## Receivers are documented in the [roc-ray-types docs](../types/),
## which is where the nominal is declared.
import rrt.Time as RrtTime

Time := [].{

	## Convert a nanosecond duration to seconds.
	##
	## expect Time.to_seconds(500_000_000) == 0.5
	to_seconds : U64 -> F32
	to_seconds = RrtTime.to_seconds

	## Seconds elapsed between two clock samples (`current` must be >= `previous`).
	## Handy for deriving your own delta from `Host.timestamp_nanos`:
	##
	##     dt = Time.delta_seconds(model.last_tick, host.timestamp_nanos)
	delta_seconds : U64, U64 -> F32
	delta_seconds = RrtTime.delta_seconds
}
