app [Model, program] { rr: platform "../platform/main.roc" }

import rr.Draw
import rr.Color
import rr.Host
import rr.Keys
import rr.Mouse

Model : {}

program = { init!, render! }

init! : Host => Try(Model, [Exit(I64), ..])
init! = |_host| Ok({})

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	w_down = Keys.key_down(host.keys, KeyW)
	a_down = Keys.key_down(host.keys, KeyA)
	s_down = Keys.key_down(host.keys, KeyS)
	d_down = Keys.key_down(host.keys, KeyD)
	up_down = Keys.key_down(host.keys, KeyUp)
	left_down = Keys.key_down(host.keys, KeyLeft)
	down_down = Keys.key_down(host.keys, KeyDown)
	right_down = Keys.key_down(host.keys, KeyRight)
	one_down = Keys.key_down(host.keys, Key1)
	shift_down = Keys.key_down(host.keys, KeyLeftShift) or Keys.key_down(host.keys, KeyRightShift)
	ctrl_down = Keys.key_down(host.keys, KeyLeftControl) or Keys.key_down(host.keys, KeyRightControl)
	escape_pressed = Keys.key_pressed(host.keys_pressed, KeyEscape)
	space_released = Keys.key_released(host.keys_released, KeySpace)
	mouse_left_pressed = Mouse.button_pressed(host.mouse, Left)
	mouse_left_released = Mouse.button_released(host.mouse, Left)

	Draw.draw!(
		Color.ray_white,
		|| {
			Draw.text!({ pos: { x: 10, y: 50 }, text: "Keyboard and mouse input", size: 20, spacing: Draw.default_spacing, color: Color.dark_gray, font: Draw.default_font, align: Draw.align_top_left })

			w_color = if w_down Color.green else Color.light_gray
			a_color = if a_down Color.green else Color.light_gray
			s_color = if s_down Color.green else Color.light_gray
			d_color = if d_down Color.green else Color.light_gray

			Draw.rectangle!({ x: 70, y: 100, width: 30, height: 30, style: Draw.filled(w_color) })
			Draw.text!({ pos: { x: 85, y: 115 }, text: "W", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
			Draw.rectangle!({ x: 30, y: 135, width: 30, height: 30, style: Draw.filled(a_color) })
			Draw.text!({ pos: { x: 45, y: 150 }, text: "A", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
			Draw.rectangle!({ x: 70, y: 135, width: 30, height: 30, style: Draw.filled(s_color) })
			Draw.text!({ pos: { x: 85, y: 150 }, text: "S", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
			Draw.rectangle!({ x: 110, y: 135, width: 30, height: 30, style: Draw.filled(d_color) })
			Draw.text!({ pos: { x: 125, y: 150 }, text: "D", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })

			up_color = if up_down Color.green else Color.light_gray
			left_color = if left_down Color.green else Color.light_gray
			down_color = if down_down Color.green else Color.light_gray
			right_color = if right_down Color.green else Color.light_gray

			Draw.rectangle!({ x: 250, y: 100, width: 30, height: 30, style: Draw.filled(up_color) })
			Draw.text!({ pos: { x: 265, y: 115 }, text: "^", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
			Draw.rectangle!({ x: 210, y: 135, width: 30, height: 30, style: Draw.filled(left_color) })
			Draw.text!({ pos: { x: 225, y: 150 }, text: "<", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
			Draw.rectangle!({ x: 250, y: 135, width: 30, height: 30, style: Draw.filled(down_color) })
			Draw.text!({ pos: { x: 265, y: 150 }, text: "v", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
			Draw.rectangle!({ x: 290, y: 135, width: 30, height: 30, style: Draw.filled(right_color) })
			Draw.text!({ pos: { x: 305, y: 150 }, text: ">", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })

			one_color = if one_down Color.green else Color.light_gray
			shift_color = if shift_down Color.green else Color.light_gray
			ctrl_color = if ctrl_down Color.green else Color.light_gray
			escape_color = if escape_pressed Color.green else Color.light_gray
			space_color = if space_released Color.green else Color.light_gray
			mouse_press_color = if mouse_left_pressed Color.green else Color.light_gray
			mouse_release_color = if mouse_left_released Color.green else Color.light_gray

			Draw.rectangle!({ x: 30, y: 220, width: 50, height: 30, style: Draw.filled(one_color) })
			Draw.text!({ pos: { x: 55, y: 235 }, text: "1", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
			Draw.rectangle!({ x: 90, y: 220, width: 80, height: 30, style: Draw.filled(shift_color) })
			Draw.text!({ pos: { x: 130, y: 235 }, text: "Shift", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
			Draw.rectangle!({ x: 180, y: 220, width: 70, height: 30, style: Draw.filled(ctrl_color) })
			Draw.text!({ pos: { x: 215, y: 235 }, text: "Ctrl", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
			Draw.rectangle!({ x: 260, y: 220, width: 80, height: 30, style: Draw.filled(escape_color) })
			Draw.text!({ pos: { x: 300, y: 235 }, text: "Esc", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
			Draw.rectangle!({ x: 350, y: 220, width: 90, height: 30, style: Draw.filled(space_color) })
			Draw.text!({ pos: { x: 395, y: 235 }, text: "Space", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
			Draw.rectangle!({ x: 30, y: 270, width: 130, height: 30, style: Draw.filled(mouse_press_color) })
			Draw.text!({ pos: { x: 95, y: 285 }, text: "Mouse down", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
			Draw.rectangle!({ x: 170, y: 270, width: 110, height: 30, style: Draw.filled(mouse_release_color) })
			Draw.text!({ pos: { x: 225, y: 285 }, text: "Mouse up", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
		},
	)

	Ok(model)
}
