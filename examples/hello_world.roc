app [Model, program] { rr: platform "../platform/main.roc" }

import rr.Draw
import rr.Color
import rr.PlatformState

Model : {
	message : Str,
}

program = { init!, render! }

init! : () => Try(Model, [Exit(I64), ..])
init! = || Ok(
	{
		message: "Roc :heart: Raylib!",
	},
)

render! : Model, PlatformState => Try(Model, [Exit(I64), ..])
render! = |model, state| {

	# Circle follows the mouse, changes color when clicked
	circle_color = if state.mouse.left Red else Green

	Draw.draw!(
		RayWhite,
		|| {
			Draw.text!({ pos: { x: 10, y: 10 }, text: model.message, size: 30, color: DarkGray })
			Draw.rectangle!({ x: 100, y: 200, width: 100, height: 80, color: Red })
			Draw.line!({ start: { x: 100, y: 500 }, end: { x: 600, y: 550 }, color: Blue })

			# Gradient examples
			Draw.rectangle_gradient_v!({ x: 250, y: 200, width: 100, height: 80, color_top: Blue, color_bottom: Red })
			Draw.rectangle_gradient_h!({ x: 400, y: 200, width: 100, height: 80, color_left: Green, color_right: Yellow })
			Draw.circle_gradient!({ center: { x: 600, y: 400 }, radius: 60, color_inner: White, color_outer: Purple })

			# Draw circle last so it is drawn over the top of other shapes
			Draw.circle!({ center: { x: state.mouse.x, y: state.mouse.y }, radius: 50, color: circle_color })
		},
	)

	Ok(model)
}
