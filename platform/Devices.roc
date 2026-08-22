## Latest device samples and interval events for one `App.Input`.
##
## `input.devices` carries the keyboard, pointer, text and gamepad state the
## host sampled for this cycle. Held keys and pointer position are the latest
## value at the cycle boundary; presses, releases and typed text are the events
## retained since the preceding input, so each is consumed by exactly one call
## to `update!`.
##
## The type and its pure query receivers live in the companion `roc-ray-types`
## package so reusable packages can depend on them without depending on this
## platform. This module re-exports them, so `Snapshot` here and in the package
## are the same nominal type.
##
## Receivers are documented in the [roc-ray-types docs](../types/),
## which is where the nominal is declared.
import rrt.Devices as RrtDevices

Devices := [].{

	## Everything the host sampled from input devices for one cycle.
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
