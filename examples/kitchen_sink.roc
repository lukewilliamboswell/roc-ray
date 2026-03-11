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

	# Test set_screen_size! - call without ? to avoid interpreter bug with Try propagation
	Host.set_screen_size!({ width: 800, height: 600 })?

	Ok({ message: "Kitchen Sink - All Host Effects", frame_count: 0 })
}

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {

	# Test: call get_screen_size!
	screen = Host.get_screen_size!()

	# Circle follows the mouse, changes color when clicked
	circle_color = if host.mouse.left Red else Green

	# Use screen.width to prove the effect worked
	is_wide = screen.width > 600

	Draw.draw!(
		RayWhite,
		|| {
			Draw.text!({ pos: { x: 10, y: 10 }, text: model.message, size: 24, color: DarkGray })
			Draw.text!({ pos: { x: 10, y: 50 }, text: "set_target_fps!(60) - called in init", size: 16, color: Blue })
			Draw.text!({ pos: { x: 10, y: 80 }, text: "get_screen_size!() - called each frame", size: 16, color: Purple })
			Draw.text!({ pos: { x: 10, y: 110 }, text: "set_screen_size!() - called in init", size: 16, color: Orange })
			Draw.text!({ pos: { x: 10, y: 140 }, text: "exit!(0) - right-click to exit", size: 16, color: Red })

			# Show current size
			size_indicator = if is_wide "Wide screen" else "Small screen"
			Draw.text!({ pos: { x: 10, y: 180 }, text: size_indicator, size: 16, color: Green })

			Draw.circle!({ center: { x: host.mouse.x, y: host.mouse.y }, radius: 20, color: circle_color })
		},
	)

	# Test exit! with right click
	if host.mouse.right {
		Host.exit!(0)
	}

	Ok({ message: model.message, frame_count: model.frame_count + 1 })
}
