## Internal wall-clock transport and hosted effects.
##
## This module is intentionally not exposed by the platform package. Public
## applications use `Time`, which wraps the flat record below in the
## `Timestamp` nominal so an instant cannot be mistaken for the simulation
## clock's nanosecond counts.
##
## Reading the calendar changes no host state and waits for nothing, but it is
## refused during `render!` all the same, so it carries the `during_update`
## phase set in `src/host_native.zig`. Wall time is not the timeline this
## platform paces: an animation driven from the calendar would ignore the
## fixed-step pacing a capture runs under, and `render!` is handed the model
## rather than an input, so a rendered clock reads the instant its model
## already folded in.
TimeHost := [].{

	## An instant on the host's wall clock, already normalized: `seconds` is
	## floor-based seconds since the Unix epoch and `nanosecond` is always less
	## than 1,000,000,000, so an instant before the epoch has a negative
	## `seconds` and a non-negative `nanosecond`.
	RawTimestamp : {
		seconds : I64,
		nanosecond : U32,
	}

	## Read the host's wall clock.
	now! : () => RawTimestamp
}
