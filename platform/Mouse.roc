## Mouse module - helpers for working with Host.mouse button state.
##
## The host stores fixed-size state lists with one byte per raylib mouse button
## code 0-6. Pass `host.mouse` directly to these helpers.
Mouse := [].{

	button_count : U64
	button_count = 7

	MouseButton := [Left, Right, Middle, Side, Extra, Forward, Back]

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

	button_state : List(U8), MouseButton -> Bool
	button_state = |states, button|
		match List.get(states, button_code(button)) {
			Ok(state) => state == 1
			Err(_) => False
		}

	## Check if a mouse button is currently held down.
	button_down : { buttons : List(U8), ..state }, MouseButton -> Bool
	button_down = |mouse, button| button_state(mouse.buttons, button)

	## Check if a mouse button is currently up.
	button_up : { buttons : List(U8), ..state }, MouseButton -> Bool
	button_up = |mouse, button| !(button_down(mouse, button))

	## Check if a mouse button was first pressed this frame.
	button_pressed : { buttons_pressed : List(U8), ..state }, MouseButton -> Bool
	button_pressed = |mouse, button| button_state(mouse.buttons_pressed, button)

	## Check if a mouse button was released this frame.
	button_released : { buttons_released : List(U8), ..state }, MouseButton -> Bool
	button_released = |mouse, button| button_state(mouse.buttons_released, button)

	expect button_code(Left) == 0
	expect button_code(Back) == 6

}
