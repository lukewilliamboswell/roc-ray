## Time module - helpers for working with the monotonic clock.
##
## `Host.timestamp_nanos` is a monotonic clock in nanoseconds. These helpers
## convert nanosecond durations into seconds (F32) for physics/animation math.
##
## For the common "move per frame" case you can use `Host.frame_time` directly
## (seconds since the previous frame) without touching this module.
Time := [].{

	## Convert a nanosecond duration to seconds.
	##
	## expect Time.to_seconds(500_000_000) == 0.5
	to_seconds : U64 -> F32
	to_seconds = |nanos| U64.to_f32(nanos) / 1_000_000_000

	## Seconds elapsed between two clock samples (`current` must be >= `previous`).
	## Handy for deriving your own delta from `Host.timestamp_nanos`:
	##
	##     dt = Time.delta_seconds(model.last_tick, host.timestamp_nanos)
	delta_seconds : U64, U64 -> F32
	delta_seconds = |previous, current| to_seconds(current - previous)

}
