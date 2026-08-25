## Latest device samples and interval events for one `App.Input`.
##
## `input.devices` carries the keyboard, pointer, text and gamepad state the
## host observed for this cycle. Held keys, held buttons, pointer position and
## gamepad axes are the latest value at the cycle boundary. Key and mouse
## presses and releases, wheel movement and typed text are the events recorded
## since the preceding input, from the window system's own event callbacks: an
## event that reaches the process is in the next input or reported as an
## overflow, never silently lost, and each is consumed by exactly one call to
## `update!`. Presses of one key or button in one interval coalesce into a
## single bit; typed text is capped at 32 codepoints with `text_input_overflow`
## saying when more arrived; the wheel is the sum of every notch. Gamepad
## buttons are sampled rather than recorded, so their edges can miss a press
## and release that both happen between two cycles.
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
	## is the pointer, and `gamepads` is up to four pads. Read them through the
	## receivers -- `key_pressed`, `mouse.position()`, `gamepad(One)` -- rather
	## than through the packed lists.
	##
	## Declared in the `roc-ray-types` package's `Devices` and re-exported here,
	## which is also where its receivers are documented. `App.Input` carries one
	## as `input.devices`.
	Snapshot : RrtDevices.Snapshot

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
