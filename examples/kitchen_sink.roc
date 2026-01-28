app [Model, program] { rr: platform "../platform/main.roc" }

import rr.Draw
import rr.Color
import rr.Host

Model : {
	message : Str,
	frame_count : U64,
}

program = { init!, render! }

init! : Host => Try(Model, [Exit(I64), ..])
init! = |_host| {
	# Test set_target_fps!
	Host.set_target_fps!(60)
	Ok({ message: "The Kitchen Sink!", frame_count: 0 })
}

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {

	# Test: call get_screen_size!
	screen = Host.get_screen_size!()

	# Circle follows the mouse, changes color when clicked
	circle_color = if host.mouse.left Red else Green

	# Use screen.width to prove the effect worked
	is_wide = screen.width > 400

	Draw.draw!(
		RayWhite,
		|| {
			Draw.text!({ pos: { x: 10, y: 10 }, text: model.message, size: 24, color: DarkGray })
			Draw.text!({ pos: { x: 10, y: 50 }, text: "set_target_fps!(60) called in init", size: 16, color: Blue })
			Draw.text!({ pos: { x: 10, y: 80 }, text: "get_screen_size!() called each frame", size: 16, color: Purple })
			Draw.text!({ pos: { x: 10, y: 110 }, text: "Right-click to test exit!(0)", size: 16, color: Red })

			# Show wide/narrow based on screen size
			size_indicator = if is_wide "Wide screen" else "Narrow"
			Draw.text!({ pos: { x: 10, y: 150 }, text: size_indicator, size: 16, color: Green })
			Draw.circle!({ center: { x: host.mouse.x, y: host.mouse.y }, radius: 5, color: circle_color })
		},
	)

	# Test exit! with right click - use block to return same type from both branches
	if host.mouse.right {
		Host.exit!(0)
	}
		
	Ok({ message: model.message, frame_count: model.frame_count + 1 })
}
