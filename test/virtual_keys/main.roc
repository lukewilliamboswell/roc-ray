app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Devices
import rr.Keys

## Does a scripted keyboard reach the app as ordinary keyboard input?
##
## A headless run only asserts an exit code, so an app whose scripted keys never
## arrive still passes the suite. This probe asserts on the values themselves.
## It installs a source on one cycle and checks what the next cycle was handed:
## exactly one `key_pressed` for a newly held key, a plain `key_down` while it
## stays held, `key_released` when the script lets go, and queued codepoints
## delivered on one cycle and gone from the next.
##
## The one-cycle lag is the property, not an accident. The host samples input at
## the top of a cycle, so a source installed during `update!` is what the *next*
## cycle sees, exactly as `Mouse.set_source!` places the pointer.
##
## Exit codes: 0 every property held, 3 one did not, 4 the script never
## finished.
Model : { outcome : Outcome }

Outcome : [Pending, Passed, FailedWith(Str)]

Msg : []

program = { init!, update!, render! }

## Cycles the script covers. Nothing is scripted from the last one: it exists to
## observe the release edge the handover back to hardware must have produced.
scripted_cycles : U64
scripted_cycles = 4

## The text the script types, and the codepoints it has to arrive as.
typed : Str
typed = "ab"

typed_codepoints : List(U32)
typed_codepoints = [97, 98]

expect Keys.typing(typed) == typed_codepoints

init! : App.Init(Model, [])
init! = App.init(App.default.with_title("virtual keys"), |_startup| Ok({ outcome: Pending }))

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices
	cycle = program_input.time.cycle_count

	outcome =
		match check(cycle, input, input.text_input) {
			Ok({}) => if cycle + 1 >= scripted_cycles Passed else Pending
			Err(reason) => FailedWith(reason)
		}

	script!(cycle)

	match outcome {
		Passed => Err(Exit(0))
		FailedWith(_) => Err(Exit(3))
		Pending =>
			if cycle >= scripted_cycles {
				Err(Exit(4))
			} else {
				Ok({ ..model, outcome })
			}
		}
}

## Drive the keyboard for the cycle after this one.
script! : U64 => {}
script! = |cycle|
	if cycle == 0 {
		Keys.set_source!(Keys.holding([KeySpace]))
		Keys.set_text!(Keys.typing(typed))
	} else if cycle == 1 {
		# Space stays held while a second key joins it, so one key's steady
		# `down` and another's fresh `pressed` are asserted on the same cycle.
		Keys.set_source!(Keys.holding([KeySpace, KeyLeftShift]))
	} else if cycle == 2 {
		Keys.set_source!(Hardware)
	} else {
		{}
	}

## Everything the input must show on a given cycle of the script.
##
## Text is passed alongside the snapshot it came from rather than read off it,
## because `Devices.none` has receivers for key state and none for text, and the
## expectations below have to be able to state both.
##
## Pure, so those expectations check the checker itself: one that accepted
## anything would let a host delivering nothing pass.
check : U64, Devices.Snapshot, List(U32) -> Try({}, Str)
check = |cycle, input, text|
	if cycle == 0 {
		# Nothing is scripted yet and a headless run has no hardware, so the
		# keyboard has to be silent rather than holding something left over.
		if input.key_down(KeySpace) {
			Err("cycle 0: space was down before anything was scripted")
		} else if !List.is_empty(text) {
			Err("cycle 0: text arrived before anything was typed")
		} else {
			Ok({})
		}
	} else if cycle == 1 {
		if !input.key_pressed(KeySpace) {
			Err("cycle 1: a newly held key produced no pressed edge")
		} else if !input.key_down(KeySpace) {
			Err("cycle 1: a held key was not down")
		} else if input.key_released(KeySpace) {
			Err("cycle 1: a held key reported a release")
		} else if text != typed_codepoints {
			Err("cycle 1: typed text did not arrive as its codepoints")
		} else {
			Ok({})
		}
	} else if cycle == 2 {
		if input.key_pressed(KeySpace) {
			Err("cycle 2: a key held since the previous cycle pressed twice")
		} else if !input.key_down(KeySpace) {
			Err("cycle 2: a key still in the source stopped being down")
		} else if !input.key_pressed(KeyLeftShift) {
			Err("cycle 2: a key added to the source produced no pressed edge")
		} else if !List.is_empty(text) {
			Err("cycle 2: text was delivered twice")
		} else {
			Ok({})
		}
	} else if !input.key_released(KeySpace) {
		Err("cycle 3: handing back to hardware produced no release edge")
	} else if !input.key_released(KeyLeftShift) {
		Err("cycle 3: the second key produced no release edge")
	} else if input.key_down(KeySpace) {
		Err("cycle 3: a released key was still down")
	} else {
		Ok({})
	}

## A silent keyboard passes cycle 0 and fails every cycle that expects an edge.
expect check(0, Devices.none, []) == Ok({})
expect check(1, Devices.none, typed_codepoints) != Ok({})
expect check(2, Devices.none, []) != Ok({})
expect check(3, Devices.none, []) != Ok({})

## Stray text on the first cycle is caught, and missing text on the second is
## caught even when every key edge is right.
expect check(0, Devices.none, typed_codepoints) != Ok({})
expect check(1, Devices.none.with_key_pressed(KeySpace), []) != Ok({})
expect check(1, Devices.none.with_key_pressed(KeySpace), typed_codepoints) == Ok({})

## The second cycle wants space merely down, not pressed again.
expect check(2, Devices.none.with_key_pressed(KeySpace).with_key_pressed(KeyLeftShift), []) != Ok({})
expect check(2, Devices.none.with_key_down(KeySpace).with_key_pressed(KeyLeftShift), []) == Ok({})

expect check(3, Devices.none.with_key_released(KeySpace).with_key_released(KeyLeftShift), []) == Ok({})

render! : Model, _ => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
