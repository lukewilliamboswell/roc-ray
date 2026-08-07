app [Model, program] {
	rr: platform "../../platform/main.roc",
	adapter: "input_adapter/main.roc",
}

import rr.App
import rr.Color
import rr.Draw
import rr.Host
import rr.Keys
import adapter.Input

Model : { started : U64 }

program = { init!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |host| Ok({ started: host.timestamp_nanos }))

## Every call below hands a value obtained through the RocRay platform to a
## package that only ever depended on `roc-ray-types`. This compiles only if the
## platform's re-exports and the package's own types are the same nominals.
render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, host, frame| {
	# `host` is the platform's nominal Host; KeyW is the platform's re-exported
	# KeyboardKey. The event comes back carrying that same key type, and the
	# platform's Keys.key_code accepts it -- a full round trip.
	label = match Input.key_event(host, KeyW) {
		KeyDown(key) => if Keys.key_code(key) == 87 "W held" else "other key"
		Click(_) => "click"
		Pad(_) => "pad"
		Nothing => "idle"
	}

	# host.mouse and host.gamepads are package-owned nominals reached through
	# the platform's Host record.
	clicked = match Input.click_event(host.mouse) {
		Click(_) => Bool.True
		_ => Bool.False
	}
	padded = match Input.pad_event(host.gamepads, One) {
		Pad(_) => Bool.True
		_ => Bool.False
	}
	age = Input.age_seconds(model.started, host.timestamp_nanos)

	frame.clear!(if clicked Color.blue else Color.ray_white)
	frame.text_at!({ pos: { x: 10, y: 10 }, text: label, size: 20, color: Color.black })
	frame.text_at!({ pos: { x: 10, y: 40 }, text: F32.to_str(age), size: 20, color: Color.black })
	frame.text_at!({ pos: { x: 10, y: 70 }, text: if padded "pad" else "no pad", size: 20, color: Color.black })

	if host.key_pressed(KeyQ) {
		host.exit!(0)
	}
	Ok(model)
}
