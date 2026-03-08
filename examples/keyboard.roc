app [Model, program] { rr: platform "../platform/main.roc" }

import rr.Draw
import rr.Host
import rr.Keys

Model : {}

program = { init!, render! }

init! : Host => Try(Model, [Exit(I64), ..])
init! = |_host| Ok({})

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	# Check WASD keys
	w_down = Keys.key_down(host.keys, KeyW)
	a_down = Keys.key_down(host.keys, KeyA)
	s_down = Keys.key_down(host.keys, KeyS)
	d_down = Keys.key_down(host.keys, KeyD)

	Draw.draw!(
		RayWhite,
		|| {
			Draw.text!({ pos: { x: 10, y: 50 }, text: "WASD to move", size: 20, color: DarkGray })

			# WASD display
			w_color = if w_down Green else LightGray
			a_color = if a_down Green else LightGray
			s_color = if s_down Green else LightGray
			d_color = if d_down Green else LightGray

			Draw.rectangle!({ x: 70, y: 100, width: 30, height: 30, color: w_color })
			Draw.text!({ pos: { x: 78, y: 105 }, text: "W", size: 20, color: Black })
			Draw.rectangle!({ x: 30, y: 135, width: 30, height: 30, color: a_color })
			Draw.text!({ pos: { x: 38, y: 140 }, text: "A", size: 20, color: Black })
			Draw.rectangle!({ x: 70, y: 135, width: 30, height: 30, color: s_color })
			Draw.text!({ pos: { x: 78, y: 140 }, text: "S", size: 20, color: Black })
			Draw.rectangle!({ x: 110, y: 135, width: 30, height: 30, color: d_color })
			Draw.text!({ pos: { x: 118, y: 140 }, text: "D", size: 20, color: Black })
		},
	)

	Ok(model)
}
