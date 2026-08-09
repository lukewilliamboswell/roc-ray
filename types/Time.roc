## Time module - helpers for working with the monotonic clock.
##
## These helpers convert nanosecond durations and monotonic clock samples into
## seconds (`F32`) for animation and simulation math.
Time := [].{

	## Convert a nanosecond duration to seconds.
	##
	## expect Time.to_seconds(500_000_000) == 0.5
	to_seconds : U64 -> F32
	to_seconds = |nanos| U64.to_f32(nanos) / 1_000_000_000

	## Seconds elapsed between two clock samples (`current` must be >= `previous`).
	## For example, derive a delta from consecutive timestamp samples:
	##
	##     dt = Time.delta_seconds(model.last_tick, timestamp_nanos)
	delta_seconds : U64, U64 -> F32
	delta_seconds = |previous, current| to_seconds(current - previous)

}
