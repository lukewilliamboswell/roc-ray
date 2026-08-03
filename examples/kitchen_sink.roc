app [Model, program] { rr: platform "../platform/main-default.roc" }

import rr.Draw
import rr.Color
import rr.Host
import rr.App

Model : {
	message : Str,
	frame_count : U64,
}

program = { init!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|_host| {
		# Test set_target_fps!
		Host.set_target_fps!(60)

		Host.set_screen_size!({ width: 800, height: 600 }) ?? {}

		Ok({ message: "Kitchen Sink - All Host Effects", frame_count: 0 })
	},
)

target_fps_message : Str
target_fps_message = "set_target_fps!(60) - called in init"

screen_sample_message : Str
screen_sample_message = "host.screen - sampled each frame"

screen_size_message : Str
screen_size_message = "set_screen_size!() - called in init"

exit_message : Str
exit_message = "exit!(0) - right-click to exit"

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	# Circle follows the mouse, changes color when clicked
	circle_color = if host.mouse.left Color.red else Color.green

	# Use the per-frame logical screen dimensions.
	is_wide = host.screen.width > 600

	Draw.clear!(Color.ray_white)
	Draw.text!({ pos: { x: 10, y: 10 }, text: model.message, size: 24, spacing: Draw.default_spacing, color: Color.dark_gray, font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 10, y: 50 }, text: target_fps_message, size: 16, spacing: Draw.default_spacing, color: Color.blue, font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 10, y: 80 }, text: screen_sample_message, size: 16, spacing: Draw.default_spacing, color: Color.purple, font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 10, y: 110 }, text: screen_size_message, size: 16, spacing: Draw.default_spacing, color: Color.orange, font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 10, y: 140 }, text: exit_message, size: 16, spacing: Draw.default_spacing, color: Color.red, font: Draw.default_font, align: Draw.align_top_left })
	Draw.fps!({ pos: { x: 700, y: 10 }, size: 18, color: Color.gray })

	# Show current size
	size_indicator = if is_wide "Wide screen" else "Small screen"
	Draw.text!({ pos: { x: 10, y: 180 }, text: size_indicator, size: 16, spacing: Draw.default_spacing, color: Color.green, font: Draw.default_font, align: Draw.align_top_left })

	Draw.circle!({ center: { x: host.mouse.x, y: host.mouse.y }, radius: 20, style: Draw.filled_and_outlined(circle_color, Color.black, 2) })

	# Test exit! with right click
	if host.mouse.right {
		Host.exit!(0)
	}

	Ok({ ..model, frame_count: model.frame_count + 1 })
}
