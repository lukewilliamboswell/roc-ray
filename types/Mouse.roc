## Pointer state and button events for one host-cycle input.
##
## Pass `input.devices.mouse` directly to the pure position, movement, wheel,
## and button-state receivers.
Mouse := [].{

	## Mouse input for one cycle. Position, movement and the held bits are
	## samples at the cycle boundary; the pressed and released bits and the
	## wheel are events recorded since the previous input.
	Snapshot := {
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
		button_down : Snapshot, Button -> Bool
		button_down = |mouse, button| Mouse.button_down(mouse, button)

		## Whether a button is currently up.
		button_up : Snapshot, Button -> Bool
		button_up = |mouse, button| Mouse.button_up(mouse, button)

		## Whether a button was pressed at least once since the previous input.
		## A click that began and ended between two cycles still counts.
		button_pressed : Snapshot, Button -> Bool
		button_pressed = |mouse, button| Mouse.button_pressed(mouse, button)

		## Whether a button was released at least once since the previous input.
		button_released : Snapshot, Button -> Bool
		button_released = |mouse, button| Mouse.button_released(mouse, button)

		## Current cursor position in logical drawing coordinates.
		position : Snapshot -> { x : F32, y : F32 }
		position = |mouse| Mouse.position(mouse)

		## Cursor movement since the previous frame.
		delta : Snapshot -> { x : F32, y : F32 }
		delta = |mouse| Mouse.delta(mouse)

		## Horizontal and vertical wheel movement since the previous input,
		## every notch in the interval summed.
		wheel_delta : Snapshot -> { x : F32, y : F32 }
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
	].{

		## Compare two of these values.
		is_eq : _
	}

	## Current cursor position in logical drawing coordinates.
	position : { x : F32, y : F32, ..state } -> { x : F32, y : F32 }
	position = |mouse| { x: mouse.x, y: mouse.y }

	## Cursor movement since the previous frame, sampled once by the host.
	delta : { delta_x : F32, delta_y : F32, ..state } -> { x : F32, y : F32 }
	delta = |mouse| { x: mouse.delta_x, y: mouse.delta_y }

	## Horizontal and vertical wheel movement since the previous input, every
	## notch in the interval summed.
	wheel_delta : { wheel_x : F32, wheel_y : F32, ..state } -> { x : F32, y : F32 }
	wheel_delta = |mouse| { x: mouse.wheel_x, y: mouse.wheel_y }

	## Standard mouse buttons sampled by the platform.
	Button := [Left, Right, Middle, Side, Extra, Forward, Back]

	## Select hardware pointer samples or deterministic application-provided samples.
	## Where pointer input comes from: `Hardware`, or a `Virtual` pointer whose
	## position and buttons the app states itself. `Mouse.set_source!` on the
	## platform is what switches between them.
	Source := [Hardware, Virtual({ x : F32, y : F32, left : Bool, middle : Bool, right : Bool, wheel : F32 })]

	## A virtual pointer at a position, with no button held.
	virtual_at : { x : F32, y : F32 } -> Source
	virtual_at = |pos| Virtual({ x: pos.x, y: pos.y, left: Bool.False, middle: Bool.False, right: Bool.False, wheel: 0 })

	## A virtual pointer at a position with the left button held, so the next
	## input reports a press there.
	virtual_click_at : { x : F32, y : F32 } -> Source
	virtual_click_at = |pos| Virtual({ x: pos.x, y: pos.y, left: Bool.True, middle: Bool.False, right: Bool.False, wheel: 0 })

	## Check if a mouse button is currently held down.
	button_down : { buttons : List(U8), ..state }, Button -> Bool
	button_down = |mouse, button| button_state(mouse.buttons, button, 1)

	## Check if a mouse button is currently up.
	button_up : { buttons : List(U8), ..state }, Button -> Bool
	button_up = |mouse, button| !(button_down(mouse, button))

	## Check if a mouse button was pressed at least once since the previous
	## input. A click that began and ended between two cycles still counts.
	button_pressed : { buttons : List(U8), ..state }, Button -> Bool
	button_pressed = |mouse, button| button_state(mouse.buttons, button, 2)

	## Check if a mouse button was released at least once since the previous
	## input.
	button_released : { buttons : List(U8), ..state }, Button -> Bool
	button_released = |mouse, button| button_state(mouse.buttons, button, 4)

	expect button_code(Left) == 0
	expect button_code(Back) == 6
	expect cursor_code(PointingHand) == 4
	expect button_state([7], Left, 1) and button_state([7], Left, 2) and button_state([7], Left, 4)
	expect {
		mouse : Snapshot
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

button_code : Mouse.Button -> U64
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

button_state : List(U8), Mouse.Button, U8 -> Bool
button_state = |states, button, mask|
	match List.get(states, button_code(button)) {
		Ok(state) => U8.bitwise_and(state, mask) != 0
		Err(_) => False
	}
