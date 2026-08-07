## Gamepad module - helpers for working with Host.gamepads.
##
## The types and pure helpers live in the companion `roc-ray-types` package so
## reusable packages can depend on them without depending on this platform.
## This module re-exports them, so the nominal types are shared either way.
import rrt.Gamepad as RrtGamepad

Gamepad := [].{

	## Gamepad input sampled once per frame for every slot.
	Snapshot : RrtGamepad.Snapshot

	## The four gamepad slots the platform samples.
	GamepadId : RrtGamepad.GamepadId

	## Face, shoulder, d-pad, and stick buttons.
	Button : RrtGamepad.Button

	## Analogue stick and trigger axes.
	Axis : RrtGamepad.Axis

	## A gamepad resolved against a snapshot, carrying its receivers.
	ConnectedPad : RrtGamepad.ConnectedPad

	## Validate and wrap a raw gamepad slot index.
	from_index : U64 -> Try(GamepadId, [InvalidGamepadIndex, ..])
	from_index = RrtGamepad.from_index

	## Resolve a gamepad slot in a sampled snapshot.
	lookup : Snapshot, GamepadId -> [Connected(ConnectedPad), Disconnected]
	lookup = RrtGamepad.lookup

	## Whether a gamepad slot reported as connected this frame.
	available : { connected : List(U8), ..state }, GamepadId -> Bool
	available = RrtGamepad.available

	## Check if a gamepad button is currently held down.
	button_down : { buttons : List(U8), ..state }, GamepadId, Button -> Bool
	button_down = RrtGamepad.button_down

	## Check if a gamepad button is currently up.
	button_up : { buttons : List(U8), ..state }, GamepadId, Button -> Bool
	button_up = RrtGamepad.button_up

	## Check if a gamepad button was first pressed this frame.
	button_pressed : { buttons : List(U8), ..state }, GamepadId, Button -> Bool
	button_pressed = RrtGamepad.button_pressed

	## Check if a gamepad button was released this frame.
	button_released : { buttons : List(U8), ..state }, GamepadId, Button -> Bool
	button_released = RrtGamepad.button_released

	## Sampled value for one axis, in the range raylib reports.
	axis : { axes : List(F32), ..state }, GamepadId, Axis -> F32
	axis = RrtGamepad.axis

	## Left analogue stick as a two-axis vector.
	left_stick : { axes : List(F32), ..state }, GamepadId -> { x : F32, y : F32 }
	left_stick = RrtGamepad.left_stick

	## Right analogue stick as a two-axis vector.
	right_stick : { axes : List(F32), ..state }, GamepadId -> { x : F32, y : F32 }
	right_stick = RrtGamepad.right_stick
}
