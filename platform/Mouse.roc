## Mouse module - helpers for working with Host.mouse button state.
##
## The host stores one packed state byte per raylib mouse button code 0-6:
## bit 0 is held, bit 1 is pressed this frame, and bit 2 is released this frame.
## Pass `host.mouse` directly to these helpers.
import MouseHost

Mouse := [].{

	## Mouse input sampled once at the start of the current frame.
	State := {
		buttons : List(U8),
		left : Bool,
		middle : Bool,
		right : Bool,
		wheel : F32,
		wheel_x : F32,
		wheel_y : F32,
		delta_x : F32,
		delta_y : F32,
		x : F32,
		y : F32,
	}.{
		button_down : State, MouseButton -> Bool
		button_down = |mouse, button| Mouse.button_down(mouse, button)

		## Whether a button is currently up.
		button_up : State, MouseButton -> Bool
		button_up = |mouse, button| Mouse.button_up(mouse, button)

		## Whether a button was first pressed this frame.
		button_pressed : State, MouseButton -> Bool
		button_pressed = |mouse, button| Mouse.button_pressed(mouse, button)

		## Whether a button was released this frame.
		button_released : State, MouseButton -> Bool
		button_released = |mouse, button| Mouse.button_released(mouse, button)

		## Current cursor position in logical drawing coordinates.
		position : State -> { x : F32, y : F32 }
		position = |mouse| Mouse.position(mouse)

		## Cursor movement since the previous frame.
		delta : State -> { x : F32, y : F32 }
		delta = |mouse| Mouse.delta(mouse)

		## Horizontal and vertical wheel movement for this frame.
		wheel_delta : State -> { x : F32, y : F32 }
		wheel_delta = |mouse| Mouse.wheel_delta(mouse)
	}

	## Native operating-system cursor shapes.
	Cursor := [
		Default,
		Arrow,
		IBeam,
		Crosshair,
		PointingHand,
		ResizeEastWest,
		ResizeNorthSouth,
		ResizeNorthwestSoutheast,
		ResizeNortheastSouthwest,
		ResizeAll,
		NotAllowed,
	]

	## Current cursor position in logical drawing coordinates.
	position : { x : F32, y : F32, ..state } -> { x : F32, y : F32 }
	position = |mouse| { x: mouse.x, y: mouse.y }

	## Cursor movement since the previous frame, sampled once by the host.
	delta : { delta_x : F32, delta_y : F32, ..state } -> { x : F32, y : F32 }
	delta = |mouse| { x: mouse.delta_x, y: mouse.delta_y }

	## Horizontal and vertical wheel movement sampled for this frame.
	wheel_delta : { wheel_x : F32, wheel_y : F32, ..state } -> { x : F32, y : F32 }
	wheel_delta = |mouse| { x: mouse.wheel_x, y: mouse.wheel_y }

	## Show the OS cursor. This does not unlock a cursor locked with `lock_cursor!`.
	show_cursor! : () => {}
	show_cursor! = || MouseHost.show_cursor!()

	## Hide the OS cursor. This does not lock its position.
	hide_cursor! : () => {}
	hide_cursor! = || MouseHost.hide_cursor!()

	## Lock and hide the cursor for relative-look controls.
	lock_cursor! : () => {}
	lock_cursor! = || MouseHost.lock_cursor!()

	## Unlock a cursor locked with `lock_cursor!` and make it visible.
	unlock_cursor! : () => {}
	unlock_cursor! = || MouseHost.unlock_cursor!()

	## Set the native cursor shape.
	set_cursor! : Cursor => {}
	set_cursor! = |cursor| MouseHost.set_cursor!(cursor_code(cursor))

	## Standard mouse buttons sampled by the platform.
	MouseButton := [Left, Right, Middle, Side, Extra, Forward, Back]

	## Check if a mouse button is currently held down.
	button_down : { buttons : List(U8), ..state }, MouseButton -> Bool
	button_down = |mouse, button| button_state(mouse.buttons, button, 1)

	## Check if a mouse button is currently up.
	button_up : { buttons : List(U8), ..state }, MouseButton -> Bool
	button_up = |mouse, button| !(button_down(mouse, button))

	## Check if a mouse button was first pressed this frame.
	button_pressed : { buttons : List(U8), ..state }, MouseButton -> Bool
	button_pressed = |mouse, button| button_state(mouse.buttons, button, 2)

	## Check if a mouse button was released this frame.
	button_released : { buttons : List(U8), ..state }, MouseButton -> Bool
	button_released = |mouse, button| button_state(mouse.buttons, button, 4)

	expect button_code(Left) == 0
	expect button_code(Back) == 6
	expect cursor_code(PointingHand) == 4
	expect button_state([7], Left, 1) and button_state([7], Left, 2) and button_state([7], Left, 4)
	expect {
		mouse : State
		mouse = { buttons: [7], left: True, middle: False, right: False, wheel: -2, wheel_x: 1, wheel_y: -2, delta_x: 3, delta_y: 4, x: 10, y: 20 }
		mouse.position() == { x: 10, y: 20 }
			and mouse.delta() == { x: 3, y: 4 }
				and mouse.wheel_delta() == { x: 1, y: -2 }
					and mouse.button_pressed(Left)
	}

}

cursor_code : Mouse.Cursor -> U8
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

button_code : Mouse.MouseButton -> U64
button_code = |button|
	match button {
		Left => 0
		Right => 1
		Middle => 2
		Side => 3
		Extra => 4
		Forward => 5
		Back => 6
	}

button_state : List(U8), Mouse.MouseButton, U8 -> Bool
button_state = |states, button, mask|
	match List.get(states, button_code(button)) {
		Ok(state) => U8.bitwise_and(state, mask) != 0
		Err(_) => False
	}
