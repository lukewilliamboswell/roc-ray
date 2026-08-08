## Input module - one cycle of sampled keyboard, text, mouse and gamepad state.
##
## A `Snapshot` is an *observation*: it says what the input devices looked like
## when the host sampled them at the start of a cycle, and nothing else. It
## carries no authority to change anything, so it is safe to hold in a model and
## safe to hand to a pure function.
##
## Window geometry and timing used to travel with these fields. They are
## `Window.Snapshot` and `Time.Frame` now, because "what the user pressed",
## "how big the window is" and "when this frame happened" are three different
## observations that happen to be sampled together.
import Keys
import Mouse
import Gamepad

Input := [].{

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

		## Unicode codepoints entered this frame, in input order. This is
		## distinct from physical key state and respects the active keyboard
		## layout. The host reuses capacity for empty and non-empty frames while
		## this snapshot is uniquely owned. Retaining an older snapshot triggers
		## copy-on-write; growth is needed only if the existing capacity is
		## insufficient. At most 32 codepoints are delivered; excess queued input
		## is drained.
		text_input : List(U32),

		## Gamepad input sampled once per frame. Use the `gamepad` receiver, or
		## the `Gamepad` helpers, rather than indexing these flat lists.
		gamepads : Gamepad.Snapshot,

		## Mouse buttons, position, delta, and two-axis wheel movement sampled
		## once for this frame. Receiver helpers are available on `Mouse.State`.
		mouse : Mouse.State,
	}.{

		## Check whether a key is currently held. Receiver form:
		## `input.key_down(KeyW)`.
		key_down : Snapshot, Keys.KeyboardKey -> Bool
		key_down = |input, key| Keys.key_down(input, key)

		## Check whether a key is currently up. Receiver form:
		## `input.key_up(KeyW)`.
		key_up : Snapshot, Keys.KeyboardKey -> Bool
		key_up = |input, key| Keys.key_up(input, key)

		## Check whether a key was pressed this frame. Receiver form:
		## `input.key_pressed(KeyW)`. Static `Keys.key_pressed(input, KeyW)`
		## remains available; combine singular queries with `or` when checking
		## alternatives.
		key_pressed : Snapshot, Keys.KeyboardKey -> Bool
		key_pressed = |input, key| Keys.key_pressed(input, key)

		## Check whether a key was released this frame. Receiver form:
		## `input.key_released(KeyW)`. Static `Keys.key_released(input, KeyW)`
		## remains.
		key_released : Snapshot, Keys.KeyboardKey -> Bool
		key_released = |input, key| Keys.key_released(input, key)

		## Resolve a gamepad slot in this frame's sampled snapshot. The returned
		## pad is snapshot-scoped; query it now rather than retaining it in the
		## model.
		gamepad : Snapshot, Gamepad.GamepadId -> [Connected(Gamepad.ConnectedPad), Disconnected]
		gamepad = |input, id| Gamepad.lookup(input.gamepads, id)
	}

	## A snapshot in which nothing is pressed, nothing was typed, the pointer is
	## at the origin, and no gamepad is connected.
	##
	## This is what an app seeds its model with before the first cycle has
	## happened. `init!` receives an `App.Startup`, which is authority rather
	## than observation and therefore has no input to hand out -- there is
	## genuinely nothing to observe before the first frame is sampled.
	##
	## Every list is empty rather than zero-filled. The receivers all resolve a
	## key, button or axis through `List.get`, so an index that is not there
	## reads as "not pressed" instead of crashing; the `expect`s below hold that
	## down.
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

	expect !(Input.empty.key_down(KeyW))
	expect Input.empty.key_up(KeyW)
	expect !(Input.empty.key_pressed(KeyEscape))
	expect !(Input.empty.key_released(KeySpace))
	expect Input.empty.gamepad(One) == Disconnected
	expect !(Input.empty.mouse.button_down(Left))
	expect !(Input.empty.mouse.button_pressed(Left))
	expect !(Input.empty.mouse.button_released(Right))
	expect Input.empty.mouse.position() == { x: 0, y: 0 }
	expect Input.empty.mouse.delta() == { x: 0, y: 0 }
	expect Input.empty.mouse.wheel_delta() == { x: 0, y: 0 }
	expect List.len(Input.empty.text_input) == 0
}
