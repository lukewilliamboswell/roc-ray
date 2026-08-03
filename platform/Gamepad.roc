## Gamepad module - allocation-free helpers for the per-frame Host snapshot.
##
## The host samples up to four gamepads once per frame. Availability, packed
## button state, and axes are stored in three flat persistent lists so queries
## do not cross the host boundary or allocate. Button state uses the same bits
## as keyboard and mouse input: held = 1, pressed = 2, released = 4.
Gamepad := [].{

	gamepad_count : U64
	gamepad_count = 4

	button_count : U64
	button_count = 18

	axis_count : U64
	axis_count = 6

	Snapshot : {
		available : List(U8),
		buttons : List(U8),
		axes : List(F32),
	}

	GamepadId := [One, Two, Three, Four, Raw(U64)]

	## Validate and wrap a zero-based gamepad index.
	from_index : U64 -> Try(GamepadId, [InvalidGamepadIndex])
	from_index = |value| if value < gamepad_count Ok(Raw(value)) else Err(InvalidGamepadIndex)

	index : GamepadId -> U64
	index = |gamepad|
		match gamepad {
			One => 0
			Two => 1
			Three => 2
			Four => 3
			Raw(value) => value
		}

	Button := [
		Unknown,
		DpadUp,
		DpadRight,
		DpadDown,
		DpadLeft,
		FaceUp,
		FaceRight,
		FaceDown,
		FaceLeft,
		LeftBumper,
		LeftTrigger,
		RightBumper,
		RightTrigger,
		Select,
		Guide,
		Start,
		LeftStick,
		RightStick,
	]

	button_code : Button -> U64
	button_code = |button|
		match button {
			Unknown => 0
			DpadUp => 1
			DpadRight => 2
			DpadDown => 3
			DpadLeft => 4
			FaceUp => 5
			FaceRight => 6
			FaceDown => 7
			FaceLeft => 8
			LeftBumper => 9
			LeftTrigger => 10
			RightBumper => 11
			RightTrigger => 12
			Select => 13
			Guide => 14
			Start => 15
			LeftStick => 16
			RightStick => 17
		}

	Axis := [LeftX, LeftY, RightX, RightY, LeftTriggerAxis, RightTriggerAxis]

	axis_code : Axis -> U64
	axis_code = |axis|
		match axis {
			LeftX => 0
			LeftY => 1
			RightX => 2
			RightY => 3
			LeftTriggerAxis => 4
			RightTriggerAxis => 5
		}

	## Whether a gamepad was connected when this frame was sampled.
	available : Snapshot, GamepadId -> Bool
	available = |snapshot, gamepad|
		match List.get(snapshot.available, index(gamepad)) {
			Ok(value) => value != 0
			Err(_) => False
		}

	button_state : Snapshot, GamepadId, Button, U8 -> Bool
	button_state = |snapshot, gamepad, button, mask| {
		flat_index = index(gamepad) * button_count + button_code(button)
		match List.get(snapshot.buttons, flat_index) {
			Ok(value) => U8.bitwise_and(value, mask) != 0
			Err(_) => False
		}
	}

	button_down : Snapshot, GamepadId, Button -> Bool
	button_down = |snapshot, gamepad, button| button_state(snapshot, gamepad, button, 1)

	button_up : Snapshot, GamepadId, Button -> Bool
	button_up = |snapshot, gamepad, button| !(button_down(snapshot, gamepad, button))

	button_pressed : Snapshot, GamepadId, Button -> Bool
	button_pressed = |snapshot, gamepad, button| button_state(snapshot, gamepad, button, 2)

	button_released : Snapshot, GamepadId, Button -> Bool
	button_released = |snapshot, gamepad, button| button_state(snapshot, gamepad, button, 4)

	## Read an axis sampled for this frame. Stick axes are normally in [-1, 1].
	## raylib reports trigger axes in [-1, 1], where -1 is released.
	axis : Snapshot, GamepadId, Axis -> F32
	axis = |snapshot, gamepad, axis_name| {
		flat_index = index(gamepad) * axis_count + axis_code(axis_name)
		match List.get(snapshot.axes, flat_index) {
			Ok(value) => value
			Err(_) => 0
		}
	}

	left_stick : Snapshot, GamepadId -> { x : F32, y : F32 }
	left_stick = |snapshot, gamepad| {
		x: axis(snapshot, gamepad, LeftX),
		y: axis(snapshot, gamepad, LeftY),
	}

	right_stick : Snapshot, GamepadId -> { x : F32, y : F32 }
	right_stick = |snapshot, gamepad| {
		x: axis(snapshot, gamepad, RightX),
		y: axis(snapshot, gamepad, RightY),
	}

	expect index(One) == 0
	expect index(Four) == 3
	expect from_index(4) == Err(InvalidGamepadIndex)
	expect available({ available: [1, 0, 0, 0], buttons: [], axes: [] }, One)
	expect button_pressed({ available: [], buttons: [0, 0, 7], axes: [] }, One, DpadRight)
	expect axis({ available: [], buttons: [], axes: [0.25, -0.5] }, One, LeftY) == -0.5

}
