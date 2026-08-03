## Mouse module - helpers for working with Host.mouse button state.
##
## The host stores one packed state byte per raylib mouse button code 0-6:
## bit 0 is held, bit 1 is pressed this frame, and bit 2 is released this frame.
## Pass `host.mouse` directly to these helpers.
Mouse := [].{
	State := {
		buttons : List(U8),
		left : Bool,
		middle : Bool,
		right : Bool,
		wheel : F32,
		x : F32,
		y : F32,
	}.{
		button_down : State, MouseButton -> Bool
		button_down = |mouse, button| Mouse.button_down(mouse, button)

		button_up : State, MouseButton -> Bool
		button_up = |mouse, button| Mouse.button_up(mouse, button)

		button_pressed : State, MouseButton -> Bool
		button_pressed = |mouse, button| Mouse.button_pressed(mouse, button)

		button_released : State, MouseButton -> Bool
		button_released = |mouse, button| Mouse.button_released(mouse, button)
	}

	button_count : U64
	button_count = 7

	MouseButton := [Left, Right, Middle, Side, Extra, Forward, Back]

	## Cursor shapes supported by raylib. `Default` restores the platform's
	## standard cursor.
	Cursor := [
		Default,
		Arrow,
		IBeam,
		Crosshair,
		PointingHand,
		ResizeEw,
		ResizeNs,
		ResizeNwse,
		ResizeNesw,
		ResizeAll,
		NotAllowed,
	]

	cursor_code : Cursor -> U8
	cursor_code = |cursor|
		match cursor {
			Default => 0
			Arrow => 1
			IBeam => 2
			Crosshair => 3
			PointingHand => 4
			ResizeEw => 5
			ResizeNs => 6
			ResizeNwse => 7
			ResizeNesw => 8
			ResizeAll => 9
			NotAllowed => 10
		}

	button_code : MouseButton -> U64
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

	button_state : List(U8), MouseButton, U8 -> Bool
	button_state = |states, button, mask|
		match List.get(states, button_code(button)) {
			Ok(state) => U8.bitwise_and(state, mask) != 0
			Err(_) => False
		}

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
	expect button_state([7], Left, 1) and button_state([7], Left, 2) and button_state([7], Left, 4)
	expect cursor_code(Default) == 0
	expect cursor_code(NotAllowed) == 10

}
