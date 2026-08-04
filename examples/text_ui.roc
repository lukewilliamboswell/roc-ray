app [Model, program] { rr: platform "../platform/main-default.roc" }

import rr.Draw
import rr.Text
import rr.Color
import rr.Host
import rr.App

Model : {
	ui : Box(
		{
			title : Text.Prepared,
			menu : Text.Prepared,
			hud : Text.Prepared,
			bottom : Text.Prepared,
		},
	),
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

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|_host| {
		font = match Text.load_font!({ path: title_font_path, size: 48 }) {
			Ok(loaded) => loaded
			Err(_) => Text.default_font
		}

		Ok({
			ui: Box.box({
				title: Text.from("Text UI").size(48).font(font).prepare!(),
				menu: Text.from("Start Game").size(28).prepare!(),
				hud: Text.from("SCORE 1200").size(24).prepare!(),
				bottom: Text.from("bottom right").size(20).prepare!(),
			}),
		})
	},
)

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, _host, frame| {
	ui = Box.unbox(model.ui)
	title_size = ui.title.bounds()
	menu_size = ui.menu.bounds()
	hud_size = ui.hud.bounds()

	title_pad = 16
	button = { x: screen_w * 0.5 - (menu_size.width + 48) * 0.5, y: 230, width: menu_size.width + 48, height: menu_size.height + 24, style: Draw.filled_and_outlined(Color.light_gray, Color.gray, 2) }

	frame.clear!(Color.ray_white)
	frame.rounded_rectangle!({ x: screen_w * 0.5 - title_size.width * 0.5 - title_pad, y: 44, width: title_size.width + title_pad * 2, height: title_size.height + title_pad, radius: 12, segments: 8, style: Draw.filled(Color.light_gray) })
	ui.title.draw!(frame, { pos: { x: screen_w * 0.5, y: 56 }, color: Color.dark_gray, align: Text.align_top_center })

	frame.rectangle!(button)
	ui.menu.draw!(frame, { pos: { x: button.x + button.width * 0.5, y: button.y + button.height * 0.5 }, color: Color.black, align: Text.align_center })

	frame.rectangle!({ x: 20, y: 20, width: hud_size.width + 20, height: hud_size.height + 12, style: Draw.filled(Color.black) })
	ui.hud.draw!(frame, { pos: { x: 30, y: 26 }, color: Color.yellow, align: Text.align_top_left })

	frame.text!({ pos: { x: 40, y: 360 }, text: long_message, size: 18, spacing: Draw.default_spacing, color: Color.gray, font: Draw.default_font, align: Draw.align_top_left })
	ui.bottom.draw!(frame, { pos: { x: screen_w - 24, y: screen_h - 24 }, color: Color.blue, align: Text.align_bottom_right })

	Ok(model)
}
