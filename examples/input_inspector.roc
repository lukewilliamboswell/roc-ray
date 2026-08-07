app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.9.0/3sKTYuHvxSV77dDyZrxuUYgfrAarL6ZtasWMPeH32udh.tar.zst" }

import rr.Draw
import rr.Color
import rr.Host
import rr.Program
import rr.Keys
import rr.Mouse
import rr.Gamepad
import rr.App

Model : {

	## Text typed since the last clear, and what the clipboard last did with it.
	typed : Str,
	clipboard_status : Str,

	## The frame this view describes. An input inspector's whole job is to show
	## the snapshot, so here the snapshot genuinely is the model.
	host : Host,
}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default
		.with_title("RocRay Input Inspector")
		.with_size({ width: 820, height: 700 })
		.with_resizable(Bool.True)
	# Without this raylib closes the window on Escape, so the Esc indicator
	# below could never light up. Q exits instead.
		.with_exit_key(NoExitKey)
		.with_frame_pacing(Capped(120)),
	|host| Ok({ typed: "", clipboard_status: "clipboard idle", host: host }),
)

title : Str
title = "Input Inspector"

cursor_help_visibility : Str
cursor_help_visibility = "Cursor: H hide, J show"

cursor_help_locking : Str
cursor_help_locking = "K lock, L unlock"

clipboard_help : Str
clipboard_help = "Type, then Ctrl+C copies and Ctrl+V pastes | Ctrl+X clears"

window_help : Str
window_help = "Ctrl+E re-arms Esc as the exit key | Ctrl+M sets a 640x480 minimum"

## Decode this frame's codepoints into text. Restricted to printable ASCII so
## the example stays short -- those codepoints are their own UTF-8 bytes.
ascii_typed : List(U32) -> Str
ascii_typed = |codepoints|
	Str.from_utf8_lossy(
		List.map(
			List.keep_if(codepoints, |code| code >= 32 and code < 127),
			|code| U32.to_u8_wrap(code),
		),
	)

update! : Model, Program.Step => Try(Program.Next(Model), [Exit(I64), ..])
update! = |model, step| {
	host = step.input
	if host.key_pressed(KeyQ) {
		host.exit!(0)
	}

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

	ctrl_held = host.key_down(KeyLeftControl) or host.key_down(KeyRightControl)
	typed_this_frame = if ctrl_held "" else ascii_typed(host.text_input)
	buffered = Str.concat(model.typed, typed_this_frame)

	clipboard = if ctrl_held and host.key_pressed(KeyC) {
		host.set_clipboard_text!(buffered)
		{ typed: buffered, clipboard_status: "copied to clipboard" }
	} else if ctrl_held and host.key_pressed(KeyV) {
		match host.get_clipboard_text!() {
			Ok(pasted) => { typed: Str.concat(buffered, pasted), clipboard_status: "pasted from clipboard" }
			# One error covers an empty clipboard and non-text content alike;
			# the windowing backend does not tell them apart.
			Err(Unavailable) => { typed: buffered, clipboard_status: "clipboard has no text" }
		}
	} else if ctrl_held and host.key_pressed(KeyX) {
		{ typed: "", clipboard_status: "cleared" }
	} else if ctrl_held and host.key_pressed(KeyE) {
		# The same setting the startup config takes, applied mid-run.
		host.set_exit_key!(ExitKey(KeyEscape))
		{ typed: buffered, clipboard_status: "Esc now exits again" }
	} else if ctrl_held and host.key_pressed(KeyM) {
		host.set_window_min_size!({ width: 640, height: 480 })
		{ typed: buffered, clipboard_status: "window minimum set to 640x480" }
	} else {
		{ typed: buffered, clipboard_status: model.clipboard_status }
	}

	host.set_cursor!(if host.mouse.button_down(Left) Crosshair else Arrow)

	Ok({
		model: { typed: clipboard.typed, clipboard_status: clipboard.clipboard_status, host: host },
		commands: [],
	})
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	host = model.host

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
	mouse_position = host.mouse.position()
	mouse_delta = host.mouse.delta()
	wheel_delta = host.mouse.wheel_delta()
	gamepad_input = match host.gamepad(One) {
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
	frame.text_at!({ pos: { x: 30, y: 450 }, text: Str.concat("Mouse ", Str.concat(F32.to_str(mouse_position.x), Str.concat(", ", F32.to_str(mouse_position.y)))), size: 18, color: Color.gray })
	frame.text_at!({ pos: { x: 30, y: 486 }, text: clipboard_help, size: 18, color: Color.dark_gray })
	frame.text_at!({ pos: { x: 30, y: 512 }, text: window_help, size: 18, color: Color.dark_gray })
	frame.text_at!({ pos: { x: 30, y: 542 }, text: Str.concat("Buffer: ", model.typed), size: 18, color: Color.dark_gray })
	frame.text_at!({ pos: { x: 30, y: 568 }, text: model.clipboard_status, size: 18, color: Color.gray })
	frame.text_at!({ pos: { x: 30, y: 594 }, text: "Hold left mouse for crosshair | Q exits | Esc is a normal key", size: 18, color: Color.gray })
	Ok({})
}
