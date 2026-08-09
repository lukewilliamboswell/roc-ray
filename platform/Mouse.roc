## Mouse helpers for `step.input.mouse`.
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

	## Cursor visibility and capture policy, applied atomically as one tagged
	## operation by `Mouse.set_cursor_mode` or `startup.set_cursor_mode!`.
	CursorMode : [Visible, Hidden, Locked]

	## Flatten a cursor shape to the raylib code the host passes to
	## `SetMouseCursor`, the way `Keys.exit_key_code` flattens an exit key.
	##
	## Apps do not need this: `Mouse.set_cursor(shape)` and
	## `startup.set_cursor!` both take the shape itself. The platform uses it to
	## apply a `SetCursor` action without having to keep a second copy of the
	## numbering.
	cursor_code : Cursor -> U8
	cursor_code = |cursor|
		match cursor {
			Default => 0
			Arrow => 1
			IBeam => 2
			Crosshair => 3
			PointingHand => 4
			ResizeEastWest => 5
			ResizeNorthSouth => 6
			ResizeNorthwestSoutheast => 7
			ResizeNortheastSouthwest => 8
			ResizeAll => 9
			NotAllowed => 10
		}

	expect Mouse.cursor_code(Default) == 0
	expect Mouse.cursor_code(PointingHand) == 4
	expect Mouse.cursor_code(NotAllowed) == 10

	## Flatten a cursor mode to the code the host applies. Apps take the tag
	## itself; the platform uses this to apply a `SetCursorMode` action.
	cursor_mode_code : CursorMode -> U8
	cursor_mode_code = |mode|
		match mode {
			Visible => 0
			Hidden => 1
			Locked => 2
		}

	expect Mouse.cursor_mode_code(Visible) == 0
	expect Mouse.cursor_mode_code(Locked) == 2

	## Ask for the native cursor shape, as an action a pure `update` can return.
	set_cursor : Cursor -> [SetCursor(Cursor), ..]
	set_cursor = |cursor| SetCursor(cursor)

	## Ask for cursor visibility/capture, as an action.
	set_cursor_mode : CursorMode -> [SetCursorMode(CursorMode), ..]
	set_cursor_mode = |mode| SetCursorMode(mode)

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
