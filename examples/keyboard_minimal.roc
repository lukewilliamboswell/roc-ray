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
	# Just check one key
	w_down = Keys.key_down(host.keys, KeyW)

	color = if w_down Green else Red

	Draw.draw!(
		RayWhite,
		|| {
			Draw.rectangle!({ x: 100, y: 100, width: 100, height: 100, color: color })
		},
	)

	Ok(model)
}
