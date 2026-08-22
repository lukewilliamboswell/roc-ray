## One cycle of sampled keyboard, text, mouse and gamepad state.
##
## A `Snapshot` is an observation: it says what the input devices looked like
## when the host sampled them at the start of a cycle, and nothing else. It
## carries no authority to change anything, so it is safe to hold in a model and
## safe to hand to a pure function. `App.Input` carries one as `input.devices`.
##
## A test writes an observation of its own. `Devices.none` is a neutral snapshot
## with the host's packed list lengths, and the `with_key_*` and `with_mouse_*`
## receivers state one device's state at a time, so a test can say exactly the
## thing it is about and nothing else.
##
## ```roc
## Devices.none.with_key_pressed(KeySpace)
## ```
import Keys
import Mouse
import Gamepad

Devices := [].{

	## Everything the host sampled from the input devices for one cycle.
	##
	## Reach for the receivers rather than indexing the packed lists directly:
	## `input.key_pressed(KeyW)`, `input.mouse.position()`,
	## `input.gamepad(One)`.
	Snapshot := {

		## Packed per-key state, one byte per raylib key code. Each byte stores
		## held, pressed-this-frame, and released-this-frame bits. Use the
		## `key_down`/`key_pressed`/`key_released` receivers.
		keys : List(U8),

		## Unicode codepoints retained for this host-cycle input, in event order. This is
		## distinct from physical key state and respects the active keyboard
		## layout. At most 32 codepoints are delivered per frame; excess queued
		## input is discarded.
		text_input : List(U32),

		## Gamepad input sampled once per host-cycle input. Use the `gamepad` receiver, or
		## the `Gamepad` helpers, rather than indexing these flat lists.
		gamepads : Gamepad.Snapshot,

		## Mouse buttons, position, delta, and two-axis wheel movement sampled
		## once for this host-cycle input. Receiver helpers are available on `Mouse.State`.
		mouse : Mouse.Snapshot,
	}.{

		## Check whether a key is currently held. Receiver form:
		## `input.key_down(KeyW)`.
		key_down : Snapshot, Keys.Key -> Bool
		key_down = |input, key| Keys.key_down(input, key)

		## Check whether a key is currently up. Receiver form:
		## `input.key_up(KeyW)`.
		key_up : Snapshot, Keys.Key -> Bool
		key_up = |input, key| Keys.key_up(input, key)

		## Check whether a key was pressed during this input interval. Receiver form:
		## `input.key_pressed(KeyW)`. Static `Keys.key_pressed(input, KeyW)`
		## remains available; combine singular queries with `or` when checking
		## alternatives.
		key_pressed : Snapshot, Keys.Key -> Bool
		key_pressed = |input, key| Keys.key_pressed(input, key)

		## Check whether a key was released during this input interval. Receiver form:
		## `input.key_released(KeyW)`. Static `Keys.key_released(input, KeyW)`
		## remains.
		key_released : Snapshot, Keys.Key -> Bool
		key_released = |input, key| Keys.key_released(input, key)

		## Resolve a gamepad slot in this input's sampled snapshot. The returned
		## pad is snapshot-scoped; query it now rather than retaining it in the
		## model.
		gamepad : Snapshot, Gamepad.Id -> [Connected(Gamepad.View), Disconnected]
		gamepad = |input, id| Gamepad.lookup(input.gamepads, id)

		## Say that one key is held, as `Devices.none.with_key_down(KeyW)`.
		##
		## Each `with_key_*` states the *complete* state of the key it names,
		## replacing whatever that key had, because the host samples exactly one
		## of held, pressed, or released per key per cycle. Different keys are
		## independent bytes, so these compose:
		## `Devices.none.with_key_pressed(KeySpace).with_key_down(KeyLeftShift)`.
		##
		## Only a snapshot with the host's packed list lengths can carry these.
		## Start from `Devices.none`, not `Devices.empty`.
		with_key_down : Snapshot, Keys.Key -> Snapshot
		with_key_down = |input, key| with_key_state(input, key, held)

		## Say that one key went down this cycle, as
		## `Devices.none.with_key_pressed(KeySpace)`.
		##
		## A key pressed this cycle is also held, which is how the host packs it,
		## so this satisfies `key_down` as well as `key_pressed`.
		with_key_pressed : Snapshot, Keys.Key -> Snapshot
		with_key_pressed = |input, key| with_key_state(input, key, U8.bitwise_or(held, pressed))

		## Say that one key came up this cycle, as
		## `Devices.none.with_key_released(KeySpace)`.
		##
		## A key released this cycle is no longer held, which is how the host
		## packs it, so this satisfies `key_released` and `key_up`.
		with_key_released : Snapshot, Keys.Key -> Snapshot
		with_key_released = |input, key| with_key_state(input, key, released)

		## Place the pointer, as `Devices.none.with_mouse_position({ x: 40, y: 12 })`.
		with_mouse_position : Snapshot, { x : F32, y : F32 } -> Snapshot
		with_mouse_position = |input, pos| {
			..snapshot_fields(input),
			mouse: { ..mouse_fields(input.mouse), x: pos.x, y: pos.y },
		}

		## Say how far the pointer moved this cycle, which is what
		## `input.mouse.delta()` reports.
		with_mouse_delta : Snapshot, { x : F32, y : F32 } -> Snapshot
		with_mouse_delta = |input, delta| {
			..snapshot_fields(input),
			mouse: { ..mouse_fields(input.mouse), delta_x: delta.x, delta_y: delta.y },
		}

		## Say how far the wheel moved this cycle, which is what
		## `input.mouse.wheel_delta()` reports.
		##
		## `wheel` is set to the vertical movement, matching how the host samples
		## a one-dimensional wheel alongside the two-axis one.
		with_mouse_wheel : Snapshot, { x : F32, y : F32 } -> Snapshot
		with_mouse_wheel = |input, wheel| {
			..snapshot_fields(input),
			mouse: { ..mouse_fields(input.mouse), wheel: wheel.y, wheel_x: wheel.x, wheel_y: wheel.y },
		}

		## Say that one mouse button is held. The `with_mouse_button_*` family
		## states the complete state of the button it names, exactly as the
		## `with_key_*` family does.
		with_mouse_button_down : Snapshot, Mouse.Button -> Snapshot
		with_mouse_button_down = |input, button| with_mouse_button_state(input, button, held)

		## Say that one mouse button went down this cycle. A button pressed this
		## cycle is also held.
		with_mouse_button_pressed : Snapshot, Mouse.Button -> Snapshot
		with_mouse_button_pressed = |input, button| with_mouse_button_state(input, button, U8.bitwise_or(held, pressed))

		## Say that one mouse button came up this cycle. A button released this
		## cycle is no longer held.
		with_mouse_button_released : Snapshot, Mouse.Button -> Snapshot
		with_mouse_button_released = |input, button| with_mouse_button_state(input, button, released)
	}

	## A neutral snapshot with the host's own packed list lengths, for tests.
	##
	## `empty` and `none` answer every query the same way -- nothing held,
	## nothing typed, pointer at the origin, no gamepad connected. They differ in
	## what they are made of. `empty`'s packed lists are empty, which is all a
	## model seed needs and costs nothing. `none`'s are the lengths the host
	## actually samples: 349 key bytes, 7 mouse-button bytes, 4 gamepad
	## availability bytes, 4 x 18 gamepad button bytes, and 4 x 6 axes. That is
	## what makes it writable, so the `with_key_*` and `with_mouse_*` receivers
	## have somewhere to put a bit.
	##
	## ```roc
	## devices = Devices.none.with_key_pressed(KeyEscape)
	## ```
	##
	## Seed a model with `empty`; build a test's input from `none`.
	none : Snapshot
	none = {
		keys: List.repeat(0, key_state_len),
		text_input: [],
		gamepads: {
			connected: List.repeat(0, gamepad_count),
			buttons: List.repeat(0, gamepad_count * gamepad_button_count),
			axes: List.repeat(0, gamepad_count * gamepad_axis_count),
		},
		mouse: {
			buttons: List.repeat(0, mouse_button_state_len),
			left: Bool.False,
			middle: Bool.False,
			right: Bool.False,
			wheel: 0,
			wheel_x: 0,
			wheel_y: 0,
			delta_x: 0,
			delta_y: 0,
			x: 0,
			y: 0,
		},
	}

	## A snapshot in which nothing is pressed, nothing was typed, the pointer is
	## at the origin, and no gamepad is connected.
	##
	## Use this to initialize models before the first device snapshot is sampled.
	## `Devices.none` is the same observation with the host's packed list lengths,
	## which is what a test that wants to say "SPACE was pressed" needs.
	empty : Snapshot
	empty = {
		keys: [],
		text_input: [],
		gamepads: {
			connected: [],
			buttons: [],
			axes: [],
		},
		mouse: {
			buttons: [],
			left: Bool.False,
			middle: Bool.False,
			right: Bool.False,
			wheel: 0,
			wheel_x: 0,
			wheel_y: 0,
			delta_x: 0,
			delta_y: 0,
			x: 0,
			y: 0,
		},
	}

	expect !(Devices.empty.key_down(KeyW))
	expect Devices.empty.key_up(KeyW)
	expect !(Devices.empty.key_pressed(KeyEscape))
	expect !(Devices.empty.key_released(KeySpace))
	expect Devices.empty.gamepad(One) == Disconnected
	expect !(Devices.empty.mouse.button_down(Left))
	expect !(Devices.empty.mouse.button_pressed(Left))
	expect !(Devices.empty.mouse.button_released(Right))
	expect Devices.empty.mouse.position() == { x: 0, y: 0 }
	expect Devices.empty.mouse.delta() == { x: 0, y: 0 }
	expect Devices.empty.mouse.wheel_delta() == { x: 0, y: 0 }
	expect List.len(Devices.empty.text_input) == 0
}

## Held bit in a packed key or mouse-button state byte.
## Mirrors `INPUT_HELD` in `src/roc_ffi.zig`.
held : U8
held = 1

## Pressed-this-cycle bit. Mirrors `INPUT_PRESSED` in `src/roc_ffi.zig`.
pressed : U8
pressed = 2

## Released-this-cycle bit. Mirrors `INPUT_RELEASED` in `src/roc_ffi.zig`.
released : U8
released = 4

## Packed key-state bytes the host samples, one per raylib key code 0-348.
## Mirrors `KEY_COUNT` in `src/roc_ffi.zig` and `DevicesFromHost` in `main.roc`.
key_state_len : U64
key_state_len = 349

## Packed mouse-button bytes, one per raylib mouse button code 0-6.
## Mirrors `MOUSE_BUTTON_COUNT` in `src/roc_ffi.zig`.
mouse_button_state_len : U64
mouse_button_state_len = 7

## Gamepad slots sampled per cycle. Mirrors `GAMEPAD_COUNT`.
gamepad_count : U64
gamepad_count = 4

## Packed button bytes per gamepad. Mirrors `GAMEPAD_BUTTON_COUNT`.
gamepad_button_count : U64
gamepad_button_count = 18

## Sampled axes per gamepad. Mirrors `GAMEPAD_AXIS_COUNT`.
gamepad_axis_count : U64
gamepad_axis_count = 6

## Open a snapshot so its fields can be updated, the way `Devices.fields`
## opens a input. A nominal cannot be record-updated directly.
snapshot_fields : Devices.Snapshot -> {
	keys : List(U8),
	text_input : List(U32),
	gamepads : Gamepad.Snapshot,
	mouse : Mouse.Snapshot,
}
snapshot_fields = |input| input

## The same, for the sampled mouse state nested inside it.
mouse_fields : Mouse.Snapshot -> {
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
}
mouse_fields = |mouse| mouse

## Write one packed state byte, leaving a list that is too short alone.
##
## A snapshot whose lists are shorter than the host's -- `Devices.empty`, whose
## lists are empty -- has nowhere to put the byte, so it comes back unchanged.
## That is why the receivers document starting from `Devices.none`, and why the
## expects below check a decode rather than only an encode.
set_byte : List(U8), U64, U8 -> List(U8)
set_byte = |bytes, index, value|
	match List.set(bytes, index, value) {
		Ok(updated) => updated
		Err(_) => bytes
	}

## Replace one key's packed state byte.
with_key_state : Devices.Snapshot, Keys.Key, U8 -> Devices.Snapshot
with_key_state = |input, key, state| {
	..snapshot_fields(input),
	keys: set_byte(input.keys, Keys.key_code(key), state),
}

## Replace one mouse button's packed state byte, keeping the three convenience
## booleans in input with it.
##
## The host derives `left`, `middle`, and `right` from the held bit of buttons
## 0, 2, and 1, so a snapshot that set only the packed byte would disagree with
## itself in a way no real sample ever does.
with_mouse_button_state : Devices.Snapshot, Mouse.Button, U8 -> Devices.Snapshot
with_mouse_button_state = |input, button, state| {
	buttons = set_byte(input.mouse.buttons, mouse_button_code(button), state)
	{
		..snapshot_fields(input),
		mouse: {
			..mouse_fields(input.mouse),
			buttons: buttons,
			left: button_held(buttons, 0),
			middle: button_held(buttons, 2),
			right: button_held(buttons, 1),
		},
	}
}

button_held : List(U8), U64 -> Bool
button_held = |buttons, index|
	match List.get(buttons, index) {
		Ok(state) => U8.bitwise_and(state, held) != 0
		Err(_) => Bool.False
	}

## raylib's mouse button code, which is the index into the packed byte list.
##
## The decoding half of this table lives in the companion types package and is
## private there, the same way `Mouse.cursor_code` is restated rather than
## re-exported. The round-trip expects below drive both halves over every
## button, so the two tables cannot drift apart without a test failing.
mouse_button_code : Mouse.Button -> U64
mouse_button_code = |button|
	match button {
		Left => 0
		Right => 1
		Middle => 2
		Side => 3
		Extra => 4
		Forward => 5
		Back => 6
	}

## Every mouse button, so the round-trip expects cover the whole table.
every_mouse_button : List(Mouse.Button)
every_mouse_button = [Left, Right, Middle, Side, Extra, Forward, Back]

## `none` carries exactly what the host samples, so a `List.set` into it lands.
expect List.len(Devices.none.keys) == key_state_len
expect List.len(Devices.none.mouse.buttons) == mouse_button_state_len
expect List.len(Devices.none.gamepads.connected) == gamepad_count
expect List.len(Devices.none.gamepads.buttons) == gamepad_count * gamepad_button_count
expect List.len(Devices.none.gamepads.axes) == gamepad_count * gamepad_axis_count

## The key list is exactly long enough for the highest raylib key code, which is
## what pins its length to the host's rather than to a number written twice.
expect Keys.key_code(KeyKbMenu) == key_state_len - 1

## A neutral snapshot answers every query the way `empty` does.
expect !(Devices.none.key_down(KeyW))
expect Devices.none.key_up(KeyW)
expect !(Devices.none.key_pressed(KeyEscape))
expect !(Devices.none.key_released(KeySpace))
expect Devices.none.gamepad(One) == Disconnected
expect Devices.none.gamepad(Four) == Disconnected
expect !(Devices.none.mouse.button_down(Left))
expect Devices.none.mouse.position() == { x: 0, y: 0 }
expect Devices.none.mouse.delta() == { x: 0, y: 0 }
expect Devices.none.mouse.wheel_delta() == { x: 0, y: 0 }

## The round trip: what `with_key_pressed` packs is what `key_pressed` decodes.
## A pressed key is held too, and it is not released.
expect Devices.none.with_key_pressed(KeySpace).key_pressed(KeySpace)
expect Devices.none.with_key_pressed(KeySpace).key_down(KeySpace)
expect !(Devices.none.with_key_pressed(KeySpace).key_released(KeySpace))

## A held key is down without being new this cycle.
expect Devices.none.with_key_down(KeyW).key_down(KeyW)
expect !(Devices.none.with_key_down(KeyW).key_pressed(KeyW))

## A released key is no longer down, which is how the host packs it.
expect Devices.none.with_key_released(KeySpace).key_released(KeySpace)
expect !(Devices.none.with_key_released(KeySpace).key_down(KeySpace))
expect Devices.none.with_key_released(KeySpace).key_up(KeySpace)

## One key does not answer for another, at either end of the code range.
expect !(Devices.none.with_key_pressed(KeySpace).key_pressed(KeyEscape))
expect Devices.none.with_key_pressed(KeyKbMenu).key_pressed(KeyKbMenu)
expect Devices.none.with_key_pressed(Raw(0)).key_pressed(Raw(0))

## Keys are independent bytes, so the receivers compose.
expect {
	input = Devices.none.with_key_pressed(KeyEscape).with_key_down(KeyLeftShift).with_key_released(KeyW)
	input.key_pressed(KeyEscape) and input.key_down(KeyLeftShift) and input.key_released(KeyW)
}

## Stating one key twice keeps the last statement rather than merging them.
expect !(Devices.none.with_key_pressed(KeyW).with_key_down(KeyW).key_pressed(KeyW))

## The same round trip for every mouse button, which is what proves this
## module's code table agrees with the decoder's.
expect List.all(every_mouse_button, |button| Devices.none.with_mouse_button_pressed(button).mouse.button_pressed(button))
expect List.all(every_mouse_button, |button| Devices.none.with_mouse_button_down(button).mouse.button_down(button))
expect List.all(every_mouse_button, |button| Devices.none.with_mouse_button_released(button).mouse.button_released(button))
expect List.all(every_mouse_button, |button| !(Devices.none.with_mouse_button_released(button).mouse.button_down(button)))

## And no button answers for a different one.
expect !(Devices.none.with_mouse_button_pressed(Left).mouse.button_pressed(Right))
expect !(Devices.none.with_mouse_button_pressed(Back).mouse.button_pressed(Forward))

## The three convenience booleans follow the packed bytes, because the host
## derives them from exactly those bits.
expect Devices.none.with_mouse_button_down(Left).mouse.left
expect Devices.none.with_mouse_button_down(Right).mouse.right
expect Devices.none.with_mouse_button_down(Middle).mouse.middle
expect !(Devices.none.with_mouse_button_down(Left).mouse.right)
expect !(Devices.none.with_mouse_button_released(Left).mouse.left)
expect !(Devices.none.with_mouse_button_down(Side).mouse.left)

## Pointer, movement, and wheel are ordinary scalars on the sample.
expect Devices.none.with_mouse_position({ x: 40, y: 12 }).mouse.position() == { x: 40, y: 12 }
expect Devices.none.with_mouse_delta({ x: 3, y: -4 }).mouse.delta() == { x: 3, y: -4 }
expect Devices.none.with_mouse_wheel({ x: 0, y: 2 }).mouse.wheel_delta() == { x: 0, y: 2 }
expect Devices.none.with_mouse_wheel({ x: 0, y: 2 }).mouse.wheel == 2

## Mouse receivers compose with each other and with the key ones.
expect {
	input =
		Devices.none
			.with_mouse_position({ x: 300, y: 500 })
			.with_mouse_button_down(Left)
			.with_key_pressed(KeyR)
	input.mouse.position() == { x: 300, y: 500 } and input.mouse.button_down(Left) and input.key_pressed(KeyR)
}
