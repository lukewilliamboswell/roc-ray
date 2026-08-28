## Opt-in application annotations for RocRay Observatory captures.
##
## These effects are legal in `init!`, `update!`, `render!`, and tasks. They
## only add diagnostic data to a capture selected by host startup policy. They
## do not reveal whether recording is enabled and cannot change application or
## drawing behavior.
##
## Labels are diagnostic metadata. Do not put application payloads, input
## contents, task messages, file contents, secrets, or personal data in them.
##
## Zones are nested per application-code owner and must be ended in strict
## last-in, first-out order. An invalid, expired, cross-owner, double-ended, or
## out-of-order zone is a programmer error, including when recording is off.
import HostABI

## Keep the ABI numbering private. The public contract is `Trace.Unit`, not
## these transport codes.
trace_unit_code : [Bytes, Count, Nanoseconds, Microseconds, Milliseconds, Ratio] -> U8
trace_unit_code = |unit|
	match unit {
		Bytes => 0
		Count => 1
		Nanoseconds => 2
		Microseconds => 3
		Milliseconds => 4
		Ratio => 5
	}

Trace := [].{

	## Opaque identity for one active diagnostic zone.
	##
	## Only `begin!` creates a zone. Pass it unchanged to `end!`; do not retain
	## one after it has ended.
	Zone :: U64

	## Unit attached to a numeric sample. `Ratio` is a label only; its value is
	## not restricted to any particular range.
	Unit : [Bytes, Count, Nanoseconds, Microseconds, Milliseconds, Ratio]

	## Add one instantaneous annotation to the current callback or task. The
	## label must be valid UTF-8 no longer than 255 encoded bytes.
	## Legal in `init!`, `update!`, `render!`, and tasks.
	mark! : Str => {}
	mark! = |label| HostABI.trace_mark!(label)

	## Begin a nested diagnostic zone. The label must be valid UTF-8 no longer
	## than 255 encoded bytes. At most 64 zones may be active for one owner.
	##
	## The zone may span startup work or task waits. End it from the same
	## callback or task owner, in strict last-in, first-out order.
	## Legal in `init!`, `update!`, `render!`, and tasks.
	begin! : Str => Zone
	begin! = |label| Zone.(HostABI.trace_begin!(label))

	## End the most recently begun active zone for this callback or task.
	## Legal in `init!`, `update!`, `render!`, and tasks.
	end! : Zone => {}
	end! = |Zone.(token)| HostABI.trace_end!(token)

	## Record one signed integer sample. Its label has the same 255-byte bound.
	## Legal in `init!`, `update!`, `render!`, and tasks.
	sample_i64! : Str, I64, Unit => {}
	sample_i64! = |label, value, unit| HostABI.trace_sample_i64!(label, value, trace_unit_code(unit))

	## Record one finite floating-point sample. Negative finite values are valid;
	## NaN and infinities are programmer errors. Its label has the same bound.
	## Legal in `init!`, `update!`, `render!`, and tasks.
	sample_f64! : Str, F64, Unit => {}
	sample_f64! = |label, value, unit| HostABI.trace_sample_f64!(label, value, trace_unit_code(unit))
}
