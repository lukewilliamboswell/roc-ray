app [Model, program] { rr: platform "../platform/main-default.roc" }

import rr.Draw
import rr.Color
import rr.Host
import rr.Keys
import rr.Mouse
import rr.Gamepad
import rr.App

Model : {}

program = { init!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|_host| Ok({}),
)

title : Str
title = "Keyboard + mouse input"

cursor_help_visibility : Str
cursor_help_visibility = "Cursor: H hide, J show"

cursor_help_locking : Str
cursor_help_locking = "K lock, L unlock"

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, host, frame| {
	if host.key_pressed(KeyH) {
		host.set_cursor_mode!(Hidden)
	}
	if host.key_pressed(KeyJ) {
		host.set_cursor_mode!(Visible)
	}
	if host.key_pressed(KeyK) {
		host.set_cursor_mode!(Locked)
	}
	if host.key_pressed(KeyL) {
		host.set_cursor_mode!(Visible)
	}

	w_down = host.key_down(KeyW)
	a_down = host.key_down(KeyA)
	s_down = host.key_down(KeyS)
	d_down = host.key_down(KeyD)
	up_down = host.key_down(KeyUp)
	left_down = host.key_down(KeyLeft)
	down_down = host.key_down(KeyDown)
	right_down = host.key_down(KeyRight)
	one_down = host.key_down(Key1)
	shift_down = host.key_down(KeyLeftShift) or host.key_down(KeyRightShift)
	ctrl_down = host.key_down(KeyLeftControl) or host.key_down(KeyRightControl)
	escape_pressed = host.key_pressed(KeyEscape)
	space_released = host.key_released(KeySpace)
	mouse_left_pressed = host.mouse.button_pressed(Left)
	mouse_left_released = host.mouse.button_released(Left)
	_mouse_position = host.mouse.position()
	mouse_delta = host.mouse.delta()
	wheel_delta = host.mouse.wheel_delta()
	gamepad_input = match host.gamepads.lookup(One) {
		Connected(pad) => { connected: Bool.True, left_stick: pad.left_stick(), action_pressed: pad.button_pressed(FaceDown) }
		Disconnected => { connected: Bool.False, left_stick: { x: 0, y: 0 }, action_pressed: Bool.False }
	}
	gamepad_connected = gamepad_input.connected
	left_stick = gamepad_input.left_stick
	gamepad_action_pressed = gamepad_input.action_pressed
	text_entered = List.len(host.text_input) > 0
	mouse_moved = mouse_delta.x != 0 or mouse_delta.y != 0
	wheel_moved = wheel_delta.x != 0 or wheel_delta.y != 0
	stick_moved = F32.abs(left_stick.x) > 0.1 or F32.abs(left_stick.y) > 0.1

	frame.clear!(Color.ray_white)
	frame.text!({ pos: { x: 10, y: 50 }, text: title, size: 20, spacing: Draw.default_spacing, color: Color.dark_gray, font: Draw.default_font, align: Draw.align_top_left })

	w_color = if w_down Color.green else Color.light_gray
	a_color = if a_down Color.green else Color.light_gray
	s_color = if s_down Color.green else Color.light_gray
	d_color = if d_down Color.green else Color.light_gray

	frame.rectangle!({ x: 70, y: 100, width: 30, height: 30, style: Draw.filled(w_color) })
	frame.text!({ pos: { x: 85, y: 115 }, text: "W", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
	frame.rectangle!({ x: 30, y: 135, width: 30, height: 30, style: Draw.filled(a_color) })
	frame.text!({ pos: { x: 45, y: 150 }, text: "A", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
	frame.rectangle!({ x: 70, y: 135, width: 30, height: 30, style: Draw.filled(s_color) })
	frame.text!({ pos: { x: 85, y: 150 }, text: "S", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
	frame.rectangle!({ x: 110, y: 135, width: 30, height: 30, style: Draw.filled(d_color) })
	frame.text!({ pos: { x: 125, y: 150 }, text: "D", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })

	up_color = if up_down Color.green else Color.light_gray
	left_color = if left_down Color.green else Color.light_gray
	down_color = if down_down Color.green else Color.light_gray
	right_color = if right_down Color.green else Color.light_gray

	frame.rectangle!({ x: 250, y: 100, width: 30, height: 30, style: Draw.filled(up_color) })
	frame.text!({ pos: { x: 265, y: 115 }, text: "^", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
	frame.rectangle!({ x: 210, y: 135, width: 30, height: 30, style: Draw.filled(left_color) })
	frame.text!({ pos: { x: 225, y: 150 }, text: "<", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
	frame.rectangle!({ x: 250, y: 135, width: 30, height: 30, style: Draw.filled(down_color) })
	frame.text!({ pos: { x: 265, y: 150 }, text: "v", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
	frame.rectangle!({ x: 290, y: 135, width: 30, height: 30, style: Draw.filled(right_color) })
	frame.text!({ pos: { x: 305, y: 150 }, text: ">", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })

	one_color = if one_down Color.green else Color.light_gray
	shift_color = if shift_down Color.green else Color.light_gray
	ctrl_color = if ctrl_down Color.green else Color.light_gray
	escape_color = if escape_pressed Color.green else Color.light_gray
	space_color = if space_released Color.green else Color.light_gray
	mouse_press_color = if mouse_left_pressed Color.green else Color.light_gray
	mouse_release_color = if mouse_left_released Color.green else Color.light_gray

	frame.rectangle!({ x: 30, y: 220, width: 50, height: 30, style: Draw.filled(one_color) })
	frame.text!({ pos: { x: 55, y: 235 }, text: "1", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
	frame.rectangle!({ x: 90, y: 220, width: 80, height: 30, style: Draw.filled(shift_color) })
	frame.text!({ pos: { x: 130, y: 235 }, text: "Shift", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
	frame.rectangle!({ x: 180, y: 220, width: 70, height: 30, style: Draw.filled(ctrl_color) })
	frame.text!({ pos: { x: 215, y: 235 }, text: "Ctrl", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
	frame.rectangle!({ x: 260, y: 220, width: 80, height: 30, style: Draw.filled(escape_color) })
	frame.text!({ pos: { x: 300, y: 235 }, text: "Esc", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
	frame.rectangle!({ x: 350, y: 220, width: 90, height: 30, style: Draw.filled(space_color) })
	frame.text!({ pos: { x: 395, y: 235 }, text: "Space", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
	frame.rectangle!({ x: 30, y: 270, width: 130, height: 30, style: Draw.filled(mouse_press_color) })
	frame.text!({ pos: { x: 95, y: 285 }, text: "Mouse down", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })
	frame.rectangle!({ x: 170, y: 270, width: 110, height: 30, style: Draw.filled(mouse_release_color) })
	frame.text!({ pos: { x: 225, y: 285 }, text: "Mouse up", size: 20, spacing: Draw.default_spacing, color: Color.black, font: Draw.default_font, align: Draw.align_center })

	frame.text_at!({ pos: { x: 30, y: 330 }, text: "Typed Unicode", size: 18, color: Color.dark_gray })
	frame.rectangle!({ x: 175, y: 328, width: 24, height: 24, style: Draw.filled(if text_entered Color.green else Color.light_gray) })
	frame.text_at!({ pos: { x: 220, y: 330 }, text: "Mouse delta", size: 18, color: Color.dark_gray })
	frame.rectangle!({ x: 345, y: 328, width: 24, height: 24, style: Draw.filled(if mouse_moved Color.green else Color.light_gray) })
	frame.text_at!({ pos: { x: 390, y: 330 }, text: "Wheel x/y", size: 18, color: Color.dark_gray })
	frame.rectangle!({ x: 505, y: 328, width: 24, height: 24, style: Draw.filled(if wheel_moved Color.green else Color.light_gray) })

	frame.text_at!({ pos: { x: 30, y: 370 }, text: "Gamepad 1", size: 18, color: Color.dark_gray })
	frame.rectangle!({ x: 135, y: 368, width: 24, height: 24, style: Draw.filled(if gamepad_connected Color.green else Color.light_gray) })
	frame.text_at!({ pos: { x: 180, y: 370 }, text: "Left stick", size: 18, color: Color.dark_gray })
	frame.rectangle!({ x: 285, y: 368, width: 24, height: 24, style: Draw.filled(if stick_moved Color.green else Color.light_gray) })
	frame.text_at!({ pos: { x: 330, y: 370 }, text: "Face down", size: 18, color: Color.dark_gray })
	frame.rectangle!({ x: 440, y: 368, width: 24, height: 24, style: Draw.filled(if gamepad_action_pressed Color.green else Color.light_gray) })
	frame.text_at!({ pos: { x: 30, y: 410 }, text: cursor_help_visibility, size: 18, color: Color.dark_gray })
	frame.text_at!({ pos: { x: 238, y: 410 }, text: cursor_help_locking, size: 18, color: Color.dark_gray })
	Ok(model)
}
