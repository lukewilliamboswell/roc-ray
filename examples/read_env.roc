app [Model, program] { rr: platform "../platform/main-default.roc" }

import rr.Draw
import rr.Color
import rr.Host
import rr.App

Model : {
	message : Str,
}

program = { init!, render! }

init! : App.Init(Model, [])
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

		Ok({ message: "${greeting}, ${username}!" })
	},
)

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {

	circle_color = if host.mouse.left Color.red else Color.green

	Draw.clear!(Color.ray_white)
	Draw.text!({ pos: { x: 10, y: 10 }, text: model.message, size: 40, spacing: Draw.default_spacing, color: Color.dark_gray, font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 10, y: 60 }, text: "Set GREETING and USER", size: 20, spacing: Draw.default_spacing, color: Color.gray, font: Draw.default_font, align: Draw.align_top_left })
	Draw.circle!({ center: { x: host.mouse.x, y: host.mouse.y }, radius: 30, style: Draw.filled(circle_color) })

	Ok(model)
}
