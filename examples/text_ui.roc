app [Model, program] { rr: platform "../platform/main-default.roc" }

import rr.Draw
import rr.Color
import rr.Host
import rr.App

Model : {
	title_font : Draw.Font,
}

program = { init!, render! }

screen_w : F32
screen_w = 800

screen_h : F32
screen_h = 600

title_font_path : Str
title_font_path = "examples/assets/RocRayDemo.ttf"

long_message : Str
long_message = "This is intentionally longer than the old fixed text buffer: text rendering and measurement now allocate a temporary C string when needed, so score screens, settings menus, HUD labels, and debug overlays can render longer copy without silently disappearing after 255 bytes."

init! : App.Init(Model)
init! = App.init(
	App.default,
	|_host| {
		font = match Draw.load_font!({ path: title_font_path, size: 48 }) {
			Ok(loaded) => loaded
			Err(_) => Draw.default_font
		}

		Ok({ title_font: font })
	},
)

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, _host| {
	title_size = Draw.measure_text!({ text: "Text UI", size: 48, spacing: Draw.default_spacing, font: model.title_font })
	menu_size = Draw.measure_text!({ text: "Start Game", size: 28, spacing: Draw.default_spacing, font: Draw.default_font })
	hud_size = Draw.measure_text!({ text: "SCORE 1200", size: 24, spacing: Draw.default_spacing, font: Draw.default_font })

	title_pad = 16
	button = { x: screen_w * 0.5 - (menu_size.width + 48) * 0.5, y: 230, width: menu_size.width + 48, height: menu_size.height + 24, style: Draw.filled_and_outlined(Color.light_gray, Color.gray, 2) }

	Draw.draw!(
		Color.ray_white,
		|| {
			Draw.rounded_rectangle!({ x: screen_w * 0.5 - title_size.width * 0.5 - title_pad, y: 44, width: title_size.width + title_pad * 2, height: title_size.height + title_pad, radius: 12, segments: 8, style: Draw.filled(Color.light_gray) })
			Draw.text!({ pos: { x: screen_w * 0.5, y: 56 }, text: "Text UI", size: 48, spacing: Draw.default_spacing, color: Color.dark_gray, font: model.title_font, align: Draw.align_top_center })

			Draw.rectangle!(button)
			Draw.text!({ pos: { x: button.x + button.width * 0.5, y: button.y + button.height * 0.5 }, text: "Start Game", size: 28, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })

			Draw.rectangle!({ x: 20, y: 20, width: hud_size.width + 20, height: hud_size.height + 12, style: Draw.filled(Color.black) })
			Draw.text!({ pos: { x: 30, y: 26 }, text: "SCORE 1200", size: 24, spacing: Draw.default_spacing, color: Color.yellow, font: Draw.default_font, align: Draw.align_top_left })

			Draw.text!({ pos: { x: 40, y: 360 }, text: long_message, size: 18, spacing: Draw.default_spacing, color: Color.gray, font: Draw.default_font, align: Draw.align_top_left })
			Draw.text!({ pos: { x: screen_w - 24, y: screen_h - 24 }, text: "bottom right", size: 20, spacing: Draw.default_spacing, color: Color.blue, font: Draw.default_font, align: Draw.align_bottom_right })
		},
	)

	Ok(model)
}
