app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst", roc: "nightly-2026-08-21-90da19f" }

import rr.Draw
import rr.Color
import rr.Devices
import rr.Window
import rr.Keys
import rr.Mouse
import rr.Gamepad
import rr.App
import rr.Capture

## A diagnostic that draws the whole `Devices.Snapshot`: keys down, pressed and
## released, mouse buttons and motion, gamepad sticks, and typed codepoints.
##
## Every host effect it uses -- the clipboard, the cursor mode, the exit key, a
## minimum window size, the eyedropper -- answers immediately, so all of them
## are ordinary calls from `update!` and the answers land on the cycle that
## asked. Escape is handed back to the app with `with_exit_key(NoExitKey)` so it
## can be shown lighting up like any other key; Q quits.
Model : {
	font : Draw.Font,

	## Text typed since the last clear, and what the clipboard last did with it.
	typed : Str,
	clipboard_status : Str,

	## The frame this view describes. An input inspector's whole job is to show
	## the snapshot, so here the snapshot genuinely is the model.
	##
	## `init!` cannot supply one: `App.Startup` is authority, and nothing has
	## been sampled before the first cycle. `Devices.empty` is that "nothing" as a
	## value -- every list empty, the pointer at the origin, and every receiver
	## answering `False` rather than crashing.
	input : Devices.Snapshot,

	## The colour the eyedropper last found under the pointer.
	picked : Picked,
}

## What one screen readback under the pointer came back with.
##
## `Unavailable` is the ordinary state on the first cycle: `update!` runs
## before the frame loop has presented anything for the host to snapshot.
Picked : Try(Color.Rgba, Capture.PixelReadError)

program = { init!, update!, render! }

## Nothing here waits, so there is no task to spawn and no message to fold in.
## A clipboard read is an ordinary call whose result is folded into the same
## cycle that asked for it.
Msg : []

## What a clipboard read can come back with.
Paste : Try(Str, [Unavailable, TooLarge, Busy])

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
	|_startup| Ok({ font: Draw.default_font!(), typed: "", clipboard_status: "clipboard idle", input: Devices.empty, picked: Err(Unavailable) }),
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

## Every host effect this app uses is an ordinary call. Reading the clipboard
## answers immediately -- the windowing backend hands over a pointer on the
## window's own thread -- so its result feeds the frame that asked for it and
## nothing has to be carried across a cycle boundary.
update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices

	ctrl_held = input.key_down(KeyLeftControl) or input.key_down(KeyRightControl)
	typed_this_frame = if ctrl_held "" else ascii_typed(input.text_input)
	buffered = Str.concat(model.typed, typed_this_frame)

	# One chain, so two shortcuts pressed together still resolve in this order.
	clipboard = if ctrl_held and input.key_pressed(KeyC) {
		Window.set_clipboard_text!(buffered)
		{ typed: buffered, clipboard_status: "copied to clipboard" }
	} else if ctrl_held and input.key_pressed(KeyV) {
		# The read returns its answer, so the pasted text lands on this frame.
		apply_paste({ typed: buffered, clipboard_status: model.clipboard_status }, Window.read_clipboard!())
	} else if ctrl_held and input.key_pressed(KeyX) {
		{ typed: "", clipboard_status: "cleared" }
	} else if ctrl_held and input.key_pressed(KeyE) {
		# The same setting the startup config takes, applied mid-run.
		Keys.set_exit_key!(ExitKey(KeyEscape))
		{ typed: buffered, clipboard_status: "Esc now exits again" }
	} else if ctrl_held and input.key_pressed(KeyM) {
		Window.suggest_min_size!({ width: 640, height: 480 })
		{ typed: buffered, clipboard_status: "window minimum suggested as 640x480" }
	} else {
		{ typed: buffered, clipboard_status: model.clipboard_status }
	}

	if input.key_pressed(KeyH) {
		Mouse.set_cursor_mode!(Hidden)
	}
	if input.key_pressed(KeyJ) {
		Mouse.set_cursor_mode!(Visible)
	}
	if input.key_pressed(KeyK) {
		Mouse.set_cursor_mode!(Locked)
	}
	if input.key_pressed(KeyL) {
		Mouse.set_cursor_mode!(Visible)
	}
	Mouse.set_cursor!(if input.mouse.button_down(Left) Crosshair else Arrow)

	# The eyedropper. One point of the frame the player is looking at, read
	# here rather than in `render!`, where reading the pixels this frame has
	# not finished drawing would be both a stall and a lie. A point costs no
	# allocation, which a one-pixel region would not manage, and the pointer
	# outside the window is `RegionOutOfBounds` rather than a nearby colour.
	pointer = input.mouse.position()
	picked = Capture.pixel_at!(Screen, { x: F32.to_i32_wrap(pointer.x), y: F32.to_i32_wrap(pointer.y) })

	if input.key_pressed(KeyQ) {
		Err(Exit(0))
	} else {
		Ok({ font: model.font, typed: clipboard.typed, clipboard_status: clipboard.clipboard_status, input: input, picked: picked })
	}
}

## Say what the eyedropper found, or why it found nothing.
##
## Pure, so every branch is checkable without a window -- which matters here
## because most of them only ever appear on a machine that has one.
eyedropper_label : Picked -> Str
eyedropper_label = |picked|
	match picked {
		Ok(color) => "Under the pointer: rgba(${U8.to_str(color.r)}, ${U8.to_str(color.g)}, ${U8.to_str(color.b)}, ${U8.to_str(color.a)})"
		# The pointer is outside the window, which is an ordinary thing for it
		# to be while a button is held.
		Err(RegionOutOfBounds) => "Under the pointer: off screen"
		# Nothing has been presented yet, or this run has no framebuffer at all.
		Err(Unavailable) => "Under the pointer: no frame to read yet"
		Err(Busy) => "Under the pointer: host busy, try again"
		Err(TargetUnavailable) => "Under the pointer: no source"
		Err(ReadbackFailed) => "Under the pointer: readback failed"
	}

expect eyedropper_label(Ok(Color.rgba(1, 2, 3, 255))) == "Under the pointer: rgba(1, 2, 3, 255)"
expect eyedropper_label(Err(RegionOutOfBounds)) == "Under the pointer: off screen"
expect eyedropper_label(Err(Unavailable)) == "Under the pointer: no frame to read yet"

## The swatch colour to draw for one reading. A failed read shows the neutral
## grey every other inactive indicator here uses.
eyedropper_swatch : Picked -> Color.Rgba
eyedropper_swatch = |picked|
	match picked {
		Ok(color) => color
		Err(_) => Color.light_gray
	}

expect eyedropper_swatch(Ok(Color.rgba(9, 9, 9, 255))) == Color.rgba(9, 9, 9, 255)
expect eyedropper_swatch(Err(Busy)) == Color.light_gray

## Fold one clipboard read's outcome into the text field.
##
## Pure, so the interesting half of Ctrl+V is testable without a window.
##
## `TooLarge` is its own outcome rather than being folded into `NoText`: there
## *is* text, the host just would not copy that much of it onto the frame
## thread, and telling someone their clipboard is empty when it is not would be
## a lie the app is in a position to avoid.
##
## `Busy` is separate again, and for the same reason in reverse: the clipboard
## is fine and so is this app, the host simply had no room to start the read.
## That is the one outcome here worth asking for a second time.
apply_paste : { typed : Str, clipboard_status : Str }, Paste -> { typed : Str, clipboard_status : Str }
apply_paste = |state, result|
	match result {
		Ok(text) => { typed: Str.concat(state.typed, text), clipboard_status: "pasted from clipboard" }
		# One error covers an empty clipboard and non-text content alike; the
		# windowing backend does not tell them apart.
		Err(Unavailable) => { ..state, clipboard_status: "clipboard has no text" }
		Err(TooLarge) => { ..state, clipboard_status: "clipboard holds too much text to paste" }
		Err(Busy) => { ..state, clipboard_status: "host was busy -- press Ctrl+V again" }
	}

expect apply_paste(apply_paste({ typed: "", clipboard_status: "idle" }, Ok("first")), Ok(" second"))
	== { typed: "first second", clipboard_status: "pasted from clipboard" }
expect apply_paste({ typed: "kept", clipboard_status: "idle" }, Err(Unavailable))
	== { typed: "kept", clipboard_status: "clipboard has no text" }

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	input = model.input

	w_down = input.key_down(KeyW)
	a_down = input.key_down(KeyA)
	s_down = input.key_down(KeyS)
	d_down = input.key_down(KeyD)
	up_down = input.key_down(KeyUp)
	left_down = input.key_down(KeyLeft)
	down_down = input.key_down(KeyDown)
	right_down = input.key_down(KeyRight)
	one_down = input.key_down(Key1)
	shift_down = input.key_down(KeyLeftShift) or input.key_down(KeyRightShift)
	ctrl_down = input.key_down(KeyLeftControl) or input.key_down(KeyRightControl)
	escape_pressed = input.key_pressed(KeyEscape)
	space_released = input.key_released(KeySpace)
	mouse_left_pressed = input.mouse.button_pressed(Left)
	mouse_left_released = input.mouse.button_released(Left)
	mouse_position = input.mouse.position()
	mouse_delta = input.mouse.delta()
	wheel_delta = input.mouse.wheel_delta()
	gamepad_input = match input.gamepad(One) {
		Connected(pad) => { connected: Bool.True, left_stick: pad.left_stick(), action_pressed: pad.button_pressed(FaceDown) }
		Disconnected => { connected: Bool.False, left_stick: { x: 0, y: 0 }, action_pressed: Bool.False }
	}
	gamepad_connected = gamepad_input.connected
	left_stick = gamepad_input.left_stick
	gamepad_action_pressed = gamepad_input.action_pressed
	text_entered = List.len(input.text_input) > 0
	mouse_moved = mouse_delta.x != 0 or mouse_delta.y != 0
	wheel_moved = wheel_delta.x != 0 or wheel_delta.y != 0
	stick_moved = F32.abs(left_stick.x) > 0.1 or F32.abs(left_stick.y) > 0.1

	frame.clear!(Color.ray_white)
	frame.text!({ pos: { x: 10, y: 50 }, text: title, size: 20, spacing: Draw.default_spacing, color: Color.dark_gray, font: model.font, align: Draw.align_top_left })

	w_color = if w_down Color.green else Color.light_gray
	a_color = if a_down Color.green else Color.light_gray
	s_color = if s_down Color.green else Color.light_gray
	d_color = if d_down Color.green else Color.light_gray

	frame.rectangle!({ x: 70, y: 100, width: 30, height: 30, style: Draw.filled(w_color) })
	frame.text!({ pos: { x: 85, y: 115 }, text: "W", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })
	frame.rectangle!({ x: 30, y: 135, width: 30, height: 30, style: Draw.filled(a_color) })
	frame.text!({ pos: { x: 45, y: 150 }, text: "A", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })
	frame.rectangle!({ x: 70, y: 135, width: 30, height: 30, style: Draw.filled(s_color) })
	frame.text!({ pos: { x: 85, y: 150 }, text: "S", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })
	frame.rectangle!({ x: 110, y: 135, width: 30, height: 30, style: Draw.filled(d_color) })
	frame.text!({ pos: { x: 125, y: 150 }, text: "D", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })

	up_color = if up_down Color.green else Color.light_gray
	left_color = if left_down Color.green else Color.light_gray
	down_color = if down_down Color.green else Color.light_gray
	right_color = if right_down Color.green else Color.light_gray

	frame.rectangle!({ x: 250, y: 100, width: 30, height: 30, style: Draw.filled(up_color) })
	frame.text!({ pos: { x: 265, y: 115 }, text: "^", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })
	frame.rectangle!({ x: 210, y: 135, width: 30, height: 30, style: Draw.filled(left_color) })
	frame.text!({ pos: { x: 225, y: 150 }, text: "<", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })
	frame.rectangle!({ x: 250, y: 135, width: 30, height: 30, style: Draw.filled(down_color) })
	frame.text!({ pos: { x: 265, y: 150 }, text: "v", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })
	frame.rectangle!({ x: 290, y: 135, width: 30, height: 30, style: Draw.filled(right_color) })
	frame.text!({ pos: { x: 305, y: 150 }, text: ">", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })

	one_color = if one_down Color.green else Color.light_gray
	shift_color = if shift_down Color.green else Color.light_gray
	ctrl_color = if ctrl_down Color.green else Color.light_gray
	escape_color = if escape_pressed Color.green else Color.light_gray
	space_color = if space_released Color.green else Color.light_gray
	mouse_press_color = if mouse_left_pressed Color.green else Color.light_gray
	mouse_release_color = if mouse_left_released Color.green else Color.light_gray

	frame.rectangle!({ x: 30, y: 220, width: 50, height: 30, style: Draw.filled(one_color) })
	frame.text!({ pos: { x: 55, y: 235 }, text: "1", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })
	frame.rectangle!({ x: 90, y: 220, width: 80, height: 30, style: Draw.filled(shift_color) })
	frame.text!({ pos: { x: 130, y: 235 }, text: "Shift", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })
	frame.rectangle!({ x: 180, y: 220, width: 70, height: 30, style: Draw.filled(ctrl_color) })
	frame.text!({ pos: { x: 215, y: 235 }, text: "Ctrl", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })
	frame.rectangle!({ x: 260, y: 220, width: 80, height: 30, style: Draw.filled(escape_color) })
	frame.text!({ pos: { x: 300, y: 235 }, text: "Esc", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })
	frame.rectangle!({ x: 350, y: 220, width: 90, height: 30, style: Draw.filled(space_color) })
	frame.text!({ pos: { x: 395, y: 235 }, text: "Space", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })
	frame.rectangle!({ x: 30, y: 270, width: 130, height: 30, style: Draw.filled(mouse_press_color) })
	frame.text!({ pos: { x: 95, y: 285 }, text: "Mouse down", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })
	frame.rectangle!({ x: 170, y: 270, width: 110, height: 30, style: Draw.filled(mouse_release_color) })
	frame.text!({ pos: { x: 225, y: 285 }, text: "Mouse up", size: 20, spacing: Draw.default_spacing, color: Color.black, font: model.font, align: Draw.align_center })

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
	frame.rectangle!({ x: 30, y: 620, width: 24, height: 24, style: Draw.filled_and_outlined(eyedropper_swatch(model.picked), Color.dark_gray, 1) })
	frame.text_at!({ pos: { x: 66, y: 622 }, text: eyedropper_label(model.picked), size: 18, color: Color.gray })
	Ok({})
}
