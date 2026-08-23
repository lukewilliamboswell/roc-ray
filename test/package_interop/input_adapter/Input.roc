## A pure translation from RocRay's input snapshot into a caller's own event
## type -- the kind of adapter a reusable UI or game-framework package would
## own rather than leave in each application.
##
## The point of this module is what it does NOT import. It depends only on the
## `roc-ray-types` package, never on the RocRay platform, yet it accepts values
## produced by an app running on that platform.
import rrt.App
import rrt.Keys
import rrt.Mouse
import rrt.Gamepad
import rrt.Texture
import rrt.Time
import rrt.Devices

Input := [].{

	## A framework-side event, carrying the platform's own key type.
	Event : [KeyDown(Keys.Key), Click({ x : F32, y : F32 }), Pad(Gamepad.Id), Nothing]

	## What the package reads off a whole cycle at once.
	Pulse : { cycle : U64, messages : U64, clicked : Bool }

	## Takes the entire `App.Input(msg)` the platform hands `update!`, rather
	## than an open record of the fields it happens to read. `App.Input` here is
	## this package's `rrt.App.Input`; the app names the same value
	## `App.Input(Msg)`, which is the platform's re-export. This signature
	## accepts it only if those are one parameterized nominal rather than two
	## look-alikes -- and `msg` stays the app's own message type through it, so
	## the value is still the witness `rr.Task.spawn!` demands.
	pulse : App.Input(msg) -> Pulse
	pulse = |input| {
		cycle: input.time.cycle_count,
		messages: List.len(input.messages),
		clicked: Mouse.button_pressed(input.devices.mouse, Left),
	}

	## Takes the platform's `Devices.Snapshot` directly. The open record is what
	## makes this work: `Snapshot` is a nominal record the package cannot name,
	## but it has these fields, so the package never needs to know the nominal.
	key_event : { keys : List(U8), ..state }, Keys.Key -> Event
	key_event = |input, key| if Keys.key_down(input, key) KeyDown(key) else Nothing

	## Takes `input.mouse`, which IS a package-owned nominal (`Mouse.Snapshot`).
	click_event : Mouse.Snapshot -> Event
	click_event = |mouse| if Mouse.button_pressed(mouse, Left) Click(Mouse.position(mouse)) else Nothing

	## Takes `input.gamepads`, another package-owned nominal.
	pad_event : Gamepad.Snapshot, Gamepad.Id -> Event
	pad_event = |snapshot, id| if Gamepad.available(snapshot, id) Pad(id) else Nothing

	## Frame age in seconds, from the platform's monotonic clock.
	age_seconds : U64, U64 -> F32
	age_seconds = |started, now| Time.delta_seconds(started, now)

	## A texture the package retains and measures. Reading the dimensions needs
	## the *type*, not the platform, which is exactly the line the companion
	## package draws: vocabulary here, capability there. The package can hold
	## this and describe it; only `rr.Assets` can upload to it.
	Sized : { texture : Texture, aspect : F32 }

	## Takes a texture the app got from `rr.Assets`. `Texture` here is this
	## package's `rrt.Texture`; the app names the same value `Draw.Texture`,
	## which is the platform's re-export. This signature accepts it only if
	## those are one nominal rather than two look-alike records.
	describe : Texture -> Sized
	describe = |texture| { texture, aspect: texture.width / texture.height }

	## Hands the texture back out, so identity has to survive both directions:
	## the app puts the result straight back into a platform-typed slot and
	## draws with it.
	retained : Sized -> Texture
	retained = |sized| sized.texture
}
