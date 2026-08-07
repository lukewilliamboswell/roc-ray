## Mouse module - helpers for working with Host.mouse button state.
##
## The types and pure helpers live in the companion `roc-ray-types` package so
## reusable packages can depend on them without depending on this platform.
## This module re-exports them, so `State` here and in the package are the same
## nominal type and its receivers are available either way.
##
## Receivers are documented in the [roc-ray-types docs](../types/),
## which is where the nominal is declared.
import rrt.Mouse as RrtMouse

Mouse := [].{

	## Mouse input sampled once at the start of the current frame.
	State : RrtMouse.State

	## Native operating-system cursor shapes.
	Cursor : RrtMouse.Cursor

	## Standard mouse buttons sampled by the platform.
	MouseButton : RrtMouse.MouseButton

	## Current cursor position in logical drawing coordinates.
	position : { x : F32, y : F32, ..state } -> { x : F32, y : F32 }
	position = RrtMouse.position

	## Cursor movement since the previous frame, sampled once by the host.
	delta : { delta_x : F32, delta_y : F32, ..state } -> { x : F32, y : F32 }
	delta = RrtMouse.delta

	## Horizontal and vertical wheel movement sampled for this frame.
	wheel_delta : { wheel_x : F32, wheel_y : F32, ..state } -> { x : F32, y : F32 }
	wheel_delta = RrtMouse.wheel_delta

	## Check if a mouse button is currently held down.
	button_down : { buttons : List(U8), ..state }, MouseButton -> Bool
	button_down = RrtMouse.button_down

	## Check if a mouse button is currently up.
	button_up : { buttons : List(U8), ..state }, MouseButton -> Bool
	button_up = RrtMouse.button_up

	## Check if a mouse button was first pressed this frame.
	button_pressed : { buttons : List(U8), ..state }, MouseButton -> Bool
	button_pressed = RrtMouse.button_pressed

	## Check if a mouse button was released this frame.
	button_released : { buttons : List(U8), ..state }, MouseButton -> Bool
	button_released = RrtMouse.button_released
}
