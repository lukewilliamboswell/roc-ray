## Internal transport for application diagnostic annotations.
##
## This module is intentionally not exposed by the platform package. Public
## applications use `Trace`, which keeps zone tokens and unit codes out of the
## application-facing contract.
TraceHost := [].{

	## Record one instantaneous annotation.
	mark! : Str => {}

	## Begin a nested zone and return its host-owned matching token.
	begin! : Str => U64

	## End the zone named by a token returned from `begin!`.
	end! : U64 => {}

	## Record one signed integer sample with its private unit code.
	sample_i64! : Str, I64, U8 => {}

	## Record one floating-point sample with its private unit code.
	sample_f64! : Str, F64, U8 => {}
}
