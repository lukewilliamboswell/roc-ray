app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.7/8gdZaHEpySPZUzMBCT6RkEF9CBpcbi5F3E7QmNu4NTCU.tar.zst" }

import rr.Draw
import rr.Color
import rr.Host
import rr.App

Model : {
	greeting : Str,
	username : Str,
}

program = { init!, render! }

init! : App.Init(Model)
init! = App.init(
	App.default,
	|host| {
		username = match host.read_env!("USER") {
			Ok(value) => value
			Err(_) => "unknown user"
		}
		greeting = match host.read_env!("GREETING") {
			Ok(value) => value
			Err(_) => "Hello"
		}

		Ok({ greeting, username })
	},
)

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {

	message = "${model.greeting}, ${model.username}!"

	circle_color = if host.mouse.left Color.red else Color.green

	Draw.draw!(
		Color.ray_white,
		|| {
			Draw.text!({ pos: { x: 10, y: 10 }, text: message, size: 40, spacing: Draw.default_spacing, color: Color.dark_gray, font: Draw.default_font, align: Draw.align_top_left })
			Draw.text!({ pos: { x: 10, y: 60 }, text: "Set GREETING and USER env vars to customize!", size: 20, spacing: Draw.default_spacing, color: Color.gray, font: Draw.default_font, align: Draw.align_top_left })
			Draw.circle!({ center: { x: host.mouse.x, y: host.mouse.y }, radius: 30, style: Draw.filled(circle_color) })
		},
	)

	Ok(model)
}
