## Latest device samples and interval events for one `App.Input`.
##
## `input.devices` carries the keyboard, pointer, text and gamepad state the
## host observed for this cycle. Held keys, held buttons, pointer position and
## gamepad axes are the latest value at the cycle boundary. Key and mouse
## presses and releases, wheel movement and typed text are the events recorded
## since the preceding input, from the window system's own event callbacks: an
## event that reaches the process is in the next input or reported as an
## overflow, never silently lost, and each is consumed by exactly one call to
## `update!`. The packed bits behind `key_pressed` and `mouse.button_pressed`
## are the coalesced view -- at least one press, at least one release -- and
## `events` is the record: every event in delivery order with count, order
## across sources and click positions preserved, up to 256 per input with
## `events_overflow` saying when more arrived. Typed text is capped at 32
## codepoints with `text_input_overflow`; the wheel is the sum of every notch.
## Gamepad buttons are sampled rather than recorded, so their edges can miss a
## press and release that both happen between two cycles.
##
## The type and its pure query receivers live in the companion `roc-ray-types`
## package so reusable packages can depend on them without depending on this
## platform. This module re-exports them, so `Snapshot` here and in the package
## are the same nominal type.
import rrt.Devices as RrtDevices

Devices := [].{

	## Everything the host observed from input devices for one cycle.
	##
	## `keys`, `text_input` and `text_input_overflow` are the keyboard, `mouse`
	## is the pointer, `gamepads` is up to four pads, and `events` with
	## `events_overflow` is the ordered record of everything the keyboard and
	## pointer did. Read the state through the receivers -- `key_pressed`,
	## `mouse.position()`, `gamepad(One)` -- rather than through the packed
	## lists, and walk `events` when order or count matters.
	##
	## Declared in the `roc-ray-types` package's `Devices` and re-exported here,
	## which is also where its receivers are documented. `App.Input` carries one
	## as `input.devices`.
	Snapshot : RrtDevices.Snapshot

	## One key edge, click, wheel notch or typed character from
	## `input.devices.events`, in the order it happened.
	##
	## ```roc
	## List.walk(input.devices.events, model, |m, event|
	##     match event {
	##         ButtonPressed(Left, at) => start_drag(m, at)
	##         ButtonReleased(Left, at) => end_drag(m, at)
	##         Text(codepoint) => insert(m, codepoint)
	##         _ => m
	##     })
	## ```
	##
	## Declared in the `roc-ray-types` package's `Devices` and re-exported here.
	Event : RrtDevices.Event

	## A snapshot with the host's packed list lengths and nothing pressed.
	##
	## This is the writable one: it has somewhere to put a bit, so a test can
	## say what happened with `Devices.none.with_key_pressed(KeySpace)`.
	## `App.Input.for_tests` starts from it.
	none : Snapshot
	none = RrtDevices.none

	## A snapshot with no packed storage at all, for seeding a model before the
	## first input is sampled.
	empty : Snapshot
	empty = RrtDevices.empty
}
