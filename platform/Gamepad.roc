## Gamepad module - allocation-free helpers for the per-frame Host snapshot.
##
## The host samples up to four gamepads once per frame. Availability, packed
## button state, and axes are stored in three flat persistent lists so queries
## do not cross the host boundary or allocate. Button state uses the same bits
## as keyboard and mouse input: held = 1, pressed = 2, released = 4.
Gamepad := [].{

	## Fixed-size input snapshot stored on `Host` and sampled once per frame.
	Snapshot := {
		connected : List(U8),
		buttons : List(U8),
		axes : List(F32),
	}

	## One of the four gamepad slots sampled by the platform.
	GamepadId := [One, Two, Three, Four]

	## Validate and wrap a zero-based gamepad index.
	from_index : U64 -> Try(GamepadId, [InvalidGamepadIndex])
	from_index = |value|
		match value {
			0 => Ok(One)
			1 => Ok(Two)
			2 => Ok(Three)
			3 => Ok(Four)
			_ => Err(InvalidGamepadIndex)
		}

	## Standard gamepad buttons. Face directions are layout-neutral rather than
	## assuming Xbox, PlayStation, or Nintendo labels.
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

	## Analog stick and trigger axes.
	Axis := [LeftX, LeftY, RightX, RightY, LeftTriggerAxis, RightTriggerAxis]

	## Whether a gamepad was connected when this frame was sampled.
	available : Snapshot, GamepadId -> Bool
	available = |snapshot, gamepad|
		match List.get(snapshot.connected, index(gamepad)) {
			Ok(value) => value != 0
			Err(_) => False
		}

	## Whether a button is currently held.
	button_down : Snapshot, GamepadId, Button -> Bool
	button_down = |snapshot, gamepad, button| button_state(snapshot, gamepad, button, 1)

	## Whether a button is currently up.
	button_up : Snapshot, GamepadId, Button -> Bool
	button_up = |snapshot, gamepad, button| !(button_down(snapshot, gamepad, button))

	## Whether a button was first pressed this frame.
	button_pressed : Snapshot, GamepadId, Button -> Bool
	button_pressed = |snapshot, gamepad, button| button_state(snapshot, gamepad, button, 2)

	## Whether a button was released this frame.
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

	## Left stick as a two-dimensional vector.
	left_stick : Snapshot, GamepadId -> { x : F32, y : F32 }
	left_stick = |snapshot, gamepad| {
		x: axis(snapshot, gamepad, LeftX),
		y: axis(snapshot, gamepad, LeftY),
	}

	## Right stick as a two-dimensional vector.
	right_stick : Snapshot, GamepadId -> { x : F32, y : F32 }
	right_stick = |snapshot, gamepad| {
		x: axis(snapshot, gamepad, RightX),
		y: axis(snapshot, gamepad, RightY),
	}

	expect index(One) == 0
	expect index(Four) == 3
	expect from_index(4) == Err(InvalidGamepadIndex)
	expect available({ connected: [1, 0, 0, 0], buttons: [], axes: [] }, One)
	expect button_pressed({ connected: [], buttons: [0, 0, 7], axes: [] }, One, DpadRight)
	expect axis({ connected: [], buttons: [], axes: [0.25, -0.5] }, One, LeftY) == -0.5
	expect {
		snapshot : Snapshot
		snapshot = { connected: [1, 0, 0, 0], buttons: [0, 0, 7], axes: [0.25, -0.5, 0.75, 1] }
		snapshot.available(One)
			and snapshot.button_down(One, DpadRight)
				and !(snapshot.button_up(One, DpadRight))
					and snapshot.button_pressed(One, DpadRight)
						and snapshot.button_released(One, DpadRight)
							and snapshot.axis(One, LeftY) == -0.5
								and snapshot.left_stick(One) == { x: 0.25, y: -0.5 }
									and snapshot.right_stick(One) == { x: 0.75, y: 1 }
	}

}

gamepad_count : U64
gamepad_count = 4

button_count : U64
button_count = 18

axis_count : U64
axis_count = 6

index : Gamepad.GamepadId -> U64
index = |gamepad|
	match gamepad {
		One => 0
		Two => 1
		Three => 2
		Four => 3
	}

button_code : Gamepad.Button -> U64
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

axis_code : Gamepad.Axis -> U64
axis_code = |axis|
	match axis {
		LeftX => 0
		LeftY => 1
		RightX => 2
		RightY => 3
		LeftTriggerAxis => 4
		RightTriggerAxis => 5
	}

button_state : Gamepad.Snapshot, Gamepad.GamepadId, Gamepad.Button, U8 -> Bool
button_state = |snapshot, gamepad, button, mask| {
	flat_index = index(gamepad) * button_count + button_code(button)
	match List.get(snapshot.buttons, flat_index) {
		Ok(value) => U8.bitwise_and(value, mask) != 0
		Err(_) => False
	}
}
