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
	from_index : U64 -> Try(GamepadId, [InvalidGamepadIndex, ..])
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

	## A gamepad proven connected in this snapshot. This is a small value holding
	## references to the existing flat lists; lookup does not allocate or resample.
	ConnectedPad :: { snapshot : Snapshot, gamepad : GamepadId }.{

		## Slot occupied by this connected pad.
		id : ConnectedPad -> GamepadId
		id = |pad| pad.gamepad

		## Whether a button is currently held.
		button_down : ConnectedPad, Button -> Bool
		button_down = |pad, button| button_state(pad.snapshot, pad.gamepad, button, 1)

		## Whether a button is currently up.
		button_up : ConnectedPad, Button -> Bool
		button_up = |pad, button| !(pad.button_down(button))

		## Whether a button was first pressed this frame.
		button_pressed : ConnectedPad, Button -> Bool
		button_pressed = |pad, button| button_state(pad.snapshot, pad.gamepad, button, 2)

		## Whether a button was released this frame.
		button_released : ConnectedPad, Button -> Bool
		button_released = |pad, button| button_state(pad.snapshot, pad.gamepad, button, 4)

		## Read an axis sampled for this frame. Stick axes are normally in [-1, 1].
		axis : ConnectedPad, Axis -> F32
		axis = |pad, axis_name| axis_value(pad.snapshot, pad.gamepad, axis_name)

		## Left stick as a two-dimensional vector.
		left_stick : ConnectedPad -> { x : F32, y : F32 }
		left_stick = |pad| { x: pad.axis(LeftX), y: pad.axis(LeftY) }

		## Right stick as a two-dimensional vector.
		right_stick : ConnectedPad -> { x : F32, y : F32 }
		right_stick = |pad| { x: pad.axis(RightX), y: pad.axis(RightY) }
	}

	## Resolve a slot into a connected receiver. Callers must handle disconnect
	## once, after which all button and axis queries stay allocation-free.
	lookup : Snapshot, GamepadId -> [Connected(ConnectedPad), Disconnected]
	lookup = |snapshot, gamepad|
		if available(snapshot, gamepad) {
			pad : ConnectedPad
			pad = { snapshot, gamepad }
			Connected(pad)
		} else {
			Disconnected
		}

	## Compatibility query for code that only needs connectivity. Prefer
	## `snapshot.lookup(id)` before reading buttons or axes.
	available : { connected : List(U8), ..state }, GamepadId -> Bool
	available = |snapshot, gamepad|
		match List.get(snapshot.connected, index(gamepad)) {
			Ok(value) => value != 0
			Err(_) => False
		}

	## Whether a button is currently held.
	button_down : { buttons : List(U8), ..state }, GamepadId, Button -> Bool
	button_down = |snapshot, gamepad, button| button_state(snapshot, gamepad, button, 1)

	## Whether a button is currently up.
	button_up : { buttons : List(U8), ..state }, GamepadId, Button -> Bool
	button_up = |snapshot, gamepad, button| !(button_down(snapshot, gamepad, button))

	## Whether a button was first pressed this frame.
	button_pressed : { buttons : List(U8), ..state }, GamepadId, Button -> Bool
	button_pressed = |snapshot, gamepad, button| button_state(snapshot, gamepad, button, 2)

	## Whether a button was released this frame.
	button_released : { buttons : List(U8), ..state }, GamepadId, Button -> Bool
	button_released = |snapshot, gamepad, button| button_state(snapshot, gamepad, button, 4)

	## Read an axis sampled for this frame. Stick axes are normally in [-1, 1].
	## raylib reports trigger axes in [-1, 1], where -1 is released.
	axis : { axes : List(F32), ..state }, GamepadId, Axis -> F32
	axis = |snapshot, gamepad, axis_name| axis_value(snapshot, gamepad, axis_name)

	## Left stick as a two-dimensional vector.
	left_stick : { axes : List(F32), ..state }, GamepadId -> { x : F32, y : F32 }
	left_stick = |snapshot, gamepad| {
		x: axis(snapshot, gamepad, LeftX),
		y: axis(snapshot, gamepad, LeftY),
	}

	## Right stick as a two-dimensional vector.
	right_stick : { axes : List(F32), ..state }, GamepadId -> { x : F32, y : F32 }
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
		match snapshot.lookup(One) {
			Connected(pad) =>
				pad.id() == One
					and pad.button_down(DpadRight)
						and !(pad.button_up(DpadRight))
							and pad.button_pressed(DpadRight)
								and pad.button_released(DpadRight)
									and pad.axis(LeftY) == -0.5
										and pad.left_stick() == { x: 0.25, y: -0.5 }
											and pad.right_stick() == { x: 0.75, y: 1 }
			Disconnected => False
		}
	}
	expect {
		snapshot : Snapshot
		snapshot = { connected: [1, 0, 0, 0], buttons: [], axes: [] }
		snapshot.lookup(Two) == Disconnected
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

button_state : { buttons : List(U8), ..state }, Gamepad.GamepadId, Gamepad.Button, U8 -> Bool
button_state = |snapshot, gamepad, button, mask| {
	flat_index = index(gamepad) * button_count + button_code(button)
	match List.get(snapshot.buttons, flat_index) {
		Ok(value) => U8.bitwise_and(value, mask) != 0
		Err(_) => False
	}
}

axis_value : { axes : List(F32), ..state }, Gamepad.GamepadId, Gamepad.Axis -> F32
axis_value = |snapshot, gamepad, axis_name| {
	flat_index = index(gamepad) * axis_count + axis_code(axis_name)
	match List.get(snapshot.axes, flat_index) {
		Ok(value) => value
		Err(_) => 0
	}
}
