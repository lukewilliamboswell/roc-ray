app [Model, program] { rr: platform "../platform/main.roc" }

import rr.Draw
import rr.Color
import rr.Host
import rr.App

Model : {
	copy : Box(
		{
			message : Str,
			target_fps : Str,
			screen_sample : Str,
			screen_size : Str,
			exit : Str,
		},
	),
	frame_count : U64,
}

program = { init!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|host| {
		# Test set_target_fps!
		host.set_target_fps!(60)

		host.set_screen_size!({ width: 800, height: 600 }) ?? {}

		Ok({
			copy: Box.box({
				message: "Kitchen Sink - All Host Effects",
				target_fps: "set_target_fps!(60) - called in init",
				screen_sample: "host.screen - sampled each frame",
				screen_size: "set_screen_size!() - called in init",
				exit: "exit!(0) - right-click to exit",
			}),
			frame_count: 0,
		})
	},
)

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, host, frame| {
	# Circle follows the mouse, changes color when clicked
	circle_color = if host.mouse.left Color.red else Color.green

	# Use the per-frame logical screen dimensions.
	is_wide = host.screen.width > 600
	copy = Box.unbox(model.copy)

	frame.clear!(Color.ray_white)
	frame.text!({ pos: { x: 10, y: 10 }, text: copy.message, size: 24, spacing: Draw.default_spacing, color: Color.dark_gray, font: Draw.default_font, align: Draw.align_top_left })
	frame.text!({ pos: { x: 10, y: 50 }, text: copy.target_fps, size: 16, spacing: Draw.default_spacing, color: Color.blue, font: Draw.default_font, align: Draw.align_top_left })
	frame.text!({ pos: { x: 10, y: 80 }, text: copy.screen_sample, size: 16, spacing: Draw.default_spacing, color: Color.purple, font: Draw.default_font, align: Draw.align_top_left })
	frame.text!({ pos: { x: 10, y: 110 }, text: copy.screen_size, size: 16, spacing: Draw.default_spacing, color: Color.orange, font: Draw.default_font, align: Draw.align_top_left })
	frame.text!({ pos: { x: 10, y: 140 }, text: copy.exit, size: 16, spacing: Draw.default_spacing, color: Color.red, font: Draw.default_font, align: Draw.align_top_left })
	frame.fps!({ pos: { x: 700, y: 10 }, size: 18, color: Color.gray })

	# Show current size
	size_indicator = if is_wide "Wide screen" else "Small screen"
	frame.text!({ pos: { x: 10, y: 180 }, text: size_indicator, size: 16, spacing: Draw.default_spacing, color: Color.green, font: Draw.default_font, align: Draw.align_top_left })

	frame.circle!({ center: { x: host.mouse.x, y: host.mouse.y }, radius: 20, style: Draw.filled_and_outlined(circle_color, Color.black, 2) })

	# Test exit! with right click
	if host.mouse.right {
		host.exit!(0)
	}

	Ok({ ..model, frame_count: model.frame_count + 1 })
}
