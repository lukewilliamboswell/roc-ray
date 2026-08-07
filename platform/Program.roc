## Program module - the message-driven application shape.
##
## An app written against this module never reads input or the clock inside
## `render!`. Every source of nondeterminism reaches it as an `Input` handed to
## `update!`, which returns a new model plus a list of `Cmd`s for the host to
## run. Results come back as another `Input`.
##
## Two things follow. Effects that block -- a file read today, a socket
## tomorrow -- no longer stall the frame, because the host runs them and
## delivers the answer when it is ready. And because *every* nondeterministic
## value arrives through one channel, that channel is a recording: the host can
## write the input stream to a file and replay it exactly.
##
## Roc still only ever runs on one thread. The host owns whatever concurrency
## exists, and `Box(Model)` is never shared.
import Host

Program := [].{

	## A single message into the application.
	##
	## `Frame` carries the same per-frame snapshot the old `render!` received,
	## so an app can keep using `host.key_pressed(...)` and friends -- it just
	## reads them in `update!` instead.
	##
	## `Tick` is separate from `Frame` on purpose: running the simulation `n`
	## steps for one rendered frame is "deliver `n` ticks", and re-rendering
	## without advancing time is "deliver none". Fused, neither is expressible.
	Input : [
		Tick({ frame_count : U64, timestamp_nanos : U64, frame_time : F32 }),
		Frame(Host),
		EffectResult({ id : U64, value : Value }),
	]

	## The payload of a completed `Cmd`, tagged by what the command produced.
	Value : [
		Unit,
		I32Value(I32),
		StrValue(Str),
		Failed(U8),
	]

	## A request for the host to do something and report back.
	##
	## Each carries an `id` the app chooses. The host echoes it in the resulting
	## `EffectResult`, which is how an app correlates an answer to its question.
	## There is no callback to store, so a `Cmd` stays plain serializable data --
	## which is what lets the host write one to a recording.
	##
	## Fire-and-forget effects are deliberately absent: playing a sound or
	## exiting has no result to wait for, so those stay ordinary effect calls,
	## and replay reproduces them by re-executing rather than by logging.
	Cmd : [
		ReadFile({ id : U64, path : Str }),
		Delay({ id : U64, millis : U64 }),
	]

	## The flat record a `Cmd` becomes on the way out to the host.
	##
	## Unions do not cross the host boundary in this platform; every effect
	## flattens to scalars behind a `U8` tag first. `kind` selects the variant
	## and the fields it does not use carry inert values.
	CmdToHost : {
		kind : U8,
		id : U64,
		path : Str,
		millis : U64,
	}

	## Flatten a `Cmd` for the host.
	to_host : Cmd -> CmdToHost
	to_host = |cmd|
		match cmd {
			ReadFile(req) => { kind: cmd_read_file, id: req.id, path: req.path, millis: 0 }
			Delay(req) => { kind: cmd_delay, id: req.id, path: "", millis: req.millis }
		}

	## Rebuild an `EffectResult` payload from the host's flat fields.
	##
	## An unrecognised code decodes as `Failed`, so a host newer than the app
	## degrades rather than crashing.
	value_from_host : { value_kind : U8, i32_value : I32, str_value : Str, err : U8 } -> Value
	value_from_host = |raw|
	# A failure is reported as a non-zero code, whatever the value kind says:
	# the host has no payload to hand back when a command did not succeed.
	# Checking the kind first made `Failed` unreachable and left a failed
	# read indistinguishable from a completed `Delay`.
		if raw.err != 0 {
			Failed(raw.err)
		} else if raw.value_kind == value_i32 {
			I32Value(raw.i32_value)
		} else if raw.value_kind == value_str {
			StrValue(raw.str_value)
		} else {
			Unit
		}
}

## `kind` codes for the host's flat input record. Mirrored in `src/host_native.zig`.
input_tick : U8
input_tick = 0

input_frame : U8
input_frame = 1

input_effect_result : U8
input_effect_result = 2

## `value_kind` codes for an `EffectResult`. Mirrored in `src/host_native.zig`.
value_unit : U8
value_unit = 0

value_i32 : U8
value_i32 = 1

value_str : U8
value_str = 2

## `kind` codes for `CmdToHost`. Mirrored in `src/host_native.zig`.
cmd_read_file : U8
cmd_read_file = 0

cmd_delay : U8
cmd_delay = 1

expect Program.to_host(ReadFile({ id: 7, path: "data.txt" })) == { kind: 0, id: 7, path: "data.txt", millis: 0 }
expect Program.to_host(Delay({ id: 9, millis: 250 })) == { kind: 1, id: 9, path: "", millis: 250 }
expect Program.value_from_host({ value_kind: 1, i32_value: -3, str_value: "", err: 0 }) == I32Value(-3)
expect Program.value_from_host({ value_kind: 2, i32_value: 0, str_value: "hi", err: 0 }) == StrValue("hi")
# The host reports a failure as VALUE_UNIT plus a non-zero code, so that is the
# shape the decoder has to recognise.
expect Program.value_from_host({ value_kind: 0, i32_value: 0, str_value: "", err: 1 }) == Failed(1)
expect Program.value_from_host({ value_kind: 0, i32_value: 0, str_value: "", err: 0 }) == Unit
