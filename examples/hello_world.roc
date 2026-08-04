app [Model, program] { rr: platform "../platform/main.roc" }

import rr.Draw
import rr.Color
import rr.Host
import rr.App
import rr.Text

Model : {
	message : Text.Prepared,
	pentagon_points : Box(List(Draw.Vector2)),
}

program = { init!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default,
	|host| {
		host.set_cursor_mode!(Visible)
		Ok({
			message: Text.from("Roc :heart: Raylib!").size(30).prepare!()?,
			pentagon_points: Box.box([{ x: 650, y: 120 }, { x: 720, y: 165 }, { x: 695, y: 235 }, { x: 605, y: 235 }, { x: 580, y: 165 }]),
		})
	},
)

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, host, frame| {

	# Circle follows the mouse, changes color when clicked
	circle_color = if host.mouse.left Color.red else Color.green
	accent = Color.from_hex_rgb(0x1d9bf0)
	soft_accent = Color.with_alpha(accent, 120)

	frame.clear!(Color.ray_white)
	model.message.draw!(frame, { pos: { x: 10, y: 10 }, color: Color.dark_gray, align: Text.align_top_left })
	frame.fps!({ pos: { x: 10, y: 46 }, size: 18, color: Color.gray })

	frame.rectangle!({ x: 80, y: 120, width: 130, height: 90, style: Draw.filled_and_outlined(soft_accent, accent, 4) })
	frame.line!({ start: { x: 80, y: 250 }, end: { x: 260, y: 300 }, stroke: Draw.stroke(Color.blue, 8) })
	frame.rounded_rectangle!({ x: 260, y: 120, width: 150, height: 90, radius: 18, segments: 12, style: Draw.filled_and_outlined(Color.orange, Color.dark_gray, 3) })
	frame.triangle!({ a: { x: 500, y: 120 }, b: { x: 430, y: 220 }, c: { x: 570, y: 220 }, style: Draw.filled_and_outlined(Color.purple, Color.dark_gray, 3) })
	frame.polygon!({ points: Box.unbox(model.pentagon_points), style: Draw.filled_and_outlined(Color.rgba(20, 190, 140, 180), Color.green, 4) })

	# Gradient examples
	frame.rectangle_gradient_v!({ x: 80, y: 350, width: 130, height: 90, color_top: Color.blue, color_bottom: Color.red })
	frame.rectangle_gradient_h!({ x: 260, y: 350, width: 150, height: 90, color_left: Color.green, color_right: Color.yellow })
	frame.circle_gradient!({ center: { x: 520, y: 395 }, radius: 60, color_inner: Color.white, color_outer: Color.purple })

	# Draw circle last so it is drawn over the top of other shapes
	frame.circle!({ center: { x: host.mouse.x, y: host.mouse.y }, radius: 42, style: Draw.filled_and_outlined(circle_color, Color.black, 2) })

	Ok(model)
}
