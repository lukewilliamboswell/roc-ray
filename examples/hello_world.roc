app [Model, program] { rr: platform "../platform/main-default.roc" }

import rr.Draw
import rr.Color
import rr.Host
import rr.App

Model : {
	message : Str,
}

program = { init!, render! }

init! : App.Init(Model)
init! = App.init(
	App.default,
	|_host| Ok({ message: "Roc :heart: Raylib!" }),
)

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {

	# Circle follows the mouse, changes color when clicked
	circle_color = if host.mouse.left Color.red else Color.green
	accent = Color.from_hex_rgb(0x1d9bf0)
	soft_accent = Color.with_alpha(accent, 120)

	Draw.draw!(
		Color.ray_white,
		|| {
			Draw.text!({ pos: { x: 10, y: 10 }, text: model.message, size: 30, spacing: Draw.default_spacing, color: Color.dark_gray, font: Draw.default_font, align: Draw.align_top_left })
			Draw.fps!({ pos: { x: 10, y: 46 }, size: 18, color: Color.gray })

			Draw.rectangle!({ x: 80, y: 120, width: 130, height: 90, style: Draw.filled_and_outlined(soft_accent, accent, 4) })
			Draw.line!({ start: { x: 80, y: 250 }, end: { x: 260, y: 300 }, stroke: Draw.stroke(Color.blue, 8) })
			Draw.rounded_rectangle!({ x: 260, y: 120, width: 150, height: 90, radius: 18, segments: 12, style: Draw.filled_and_outlined(Color.orange, Color.dark_gray, 3) })
			Draw.triangle!({ a: { x: 500, y: 120 }, b: { x: 430, y: 220 }, c: { x: 570, y: 220 }, style: Draw.filled_and_outlined(Color.purple, Color.dark_gray, 3) })
			Draw.polygon!({ points: [{ x: 650, y: 120 }, { x: 720, y: 165 }, { x: 695, y: 235 }, { x: 605, y: 235 }, { x: 580, y: 165 }], style: Draw.filled_and_outlined(Color.rgba(20, 190, 140, 180), Color.green, 4) })

			# Gradient examples
			Draw.rectangle_gradient_v!({ x: 80, y: 350, width: 130, height: 90, color_top: Color.blue, color_bottom: Color.red })
			Draw.rectangle_gradient_h!({ x: 260, y: 350, width: 150, height: 90, color_left: Color.green, color_right: Color.yellow })
			Draw.circle_gradient!({ center: { x: 520, y: 395 }, radius: 60, color_inner: Color.white, color_outer: Color.purple })

			# Draw circle last so it is drawn over the top of other shapes
			Draw.circle!({ center: { x: host.mouse.x, y: host.mouse.y }, radius: 42, style: Draw.filled_and_outlined(circle_color, Color.black, 2) })
		},
	)

	Ok(model)
}
