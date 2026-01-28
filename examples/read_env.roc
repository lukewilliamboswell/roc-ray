app [Model, program] { rr: platform "../platform/main.roc" }

import rr.Draw
import rr.Color
import rr.Host

Model : {
	greeting : Str,
	username : Str,
}

program = { init!, render! }

init! : Host => Try(Model, [Exit(I64), NotFound, ..])
init! = |host| {
	# Read USER and GREETING variables from the environment, early return if not set
	username = host.read_env!("USER")?
	greeting = host.read_env!("GREETING")?

	Ok({ greeting, username })
}

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {

	message = "${model.greeting}, ${model.username}!"

	circle_color = if host.mouse.left Red else Green

	Draw.draw!(
		RayWhite,
		|| {
			Draw.text!({ pos: { x: 10, y: 10 }, text: message, size: 40, color: DarkGray })
			Draw.text!({ pos: { x: 10, y: 60 }, text: "Set GREETING and USER env vars to customize!", size: 20, color: Gray })
			Draw.circle!({ center: { x: host.mouse.x, y: host.mouse.y }, radius: 30, color: circle_color })
		},
	)

	Ok(model)
}
