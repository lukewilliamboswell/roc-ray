## A pure translation from RocRay's input snapshot into a caller's own event
## type -- the kind of adapter a reusable UI or game-framework package would
## own rather than leave in each application.
##
## The point of this module is what it does NOT import. It depends only on the
## `roc-ray-types` package, never on the RocRay platform, yet it accepts values
## produced by an app running on that platform.
import rrt.Keys
import rrt.Mouse
import rrt.Gamepad
import rrt.Time

Input := [].{

	## A framework-side event, carrying the platform's own key type.
	Event : [KeyDown(Keys.KeyboardKey), Click({ x : F32, y : F32 }), Pad(Gamepad.GamepadId), Nothing]

	## Takes the platform's `Input.Snapshot` directly. The open record is what
	## makes this work: `Snapshot` is a nominal record the package cannot name,
	## but it has these fields, so the package never needs to know the nominal.
	key_event : { keys : List(U8), ..state }, Keys.KeyboardKey -> Event
	key_event = |input, key| if Keys.key_down(input, key) KeyDown(key) else Nothing

	## Takes `input.mouse`, which IS a package-owned nominal (`Mouse.State`).
	click_event : Mouse.State -> Event
	click_event = |mouse| if Mouse.button_pressed(mouse, Left) Click(Mouse.position(mouse)) else Nothing

	## Takes `input.gamepads`, another package-owned nominal.
	pad_event : Gamepad.Snapshot, Gamepad.GamepadId -> Event
	pad_event = |snapshot, id| if Gamepad.available(snapshot, id) Pad(id) else Nothing

	## Frame age in seconds, from the platform's monotonic clock.
	age_seconds : U64, U64 -> F32
	age_seconds = |started, now| Time.delta_seconds(started, now)
}
