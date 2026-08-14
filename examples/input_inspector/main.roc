app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-12-606470f" }

import rr.Draw
import rr.Color
import rr.Input
import rr.Window
import rr.Program
import rr.Keys
import rr.Mouse
import rr.Gamepad
import rr.App

Model : {
	font : Draw.Font,

	## Text typed since the last clear, and what the clipboard last did with it.
	typed : Str,
	clipboard_status : Str,

	## The frame this view describes. An input inspector's whole job is to show
	## the snapshot, so here the snapshot genuinely is the model.
	##
	## `init!` cannot supply one: `App.Startup` is authority, and nothing has
	## been sampled before the first frame. `Input.empty` is that "nothing" as a
	## value -- every list empty, the pointer at the origin, and every receiver
	## answering `False` rather than crashing.
	input : Input.Snapshot,
}

program = { init!, update, render! }

## A clipboard task chooses this message at submission time. The app receives
## the typed result directly in `step.messages`, with no public task ID.
Msg : [ClipboardReadFinished(Try(Str, [Unavailable, TooLarge, Busy]))]

init! : App.Init(Model, [])
init! = App.init(
	App.static_config(
		App.default
			.with_title("RocRay Input Inspector")
			.with_size({ width: 820, height: 700 })
			.with_resizable(Bool.True)
		# Without this raylib closes the window on Escape, so the Esc indicator
		# below could never light up. Q exits instead.
			.with_exit_key(NoExitKey)
			.with_frame_pacing(Capped(120)),
	),
	|_startup| Ok({ font: Draw.default_font!(), typed: "", clipboard_status: "clipboard idle", input: Input.empty }),
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

## Everything the host used to be told mid-update is returned instead: settings
## that just happen become actions, and reading the clipboard -- which answers
## back -- becomes a task.
update : Model, Program.Step(Msg) -> Program.Update(Model, Msg)
update = |model, step| {
	input = step.input

	ctrl_held = input.key_down(KeyLeftControl) or input.key_down(KeyRightControl)
	typed_this_frame = if ctrl_held "" else ascii_typed(input.text_input)
	buffered = Str.concat(model.typed, typed_this_frame)

	# One chain, as before, so two shortcuts pressed together still resolve in
	# this order -- it now yields the work to do alongside the new buffer.
	clipboard = if ctrl_held and input.key_pressed(KeyC) {
		{ typed: buffered, clipboard_status: "copied to clipboard", actions: [Window.set_clipboard_text(buffered)], tasks: [] }
	} else if ctrl_held and input.key_pressed(KeyV) {
		# A read answers back, so it is a task: the pasted text is appended on
		# the step that carries the answer rather than on this one.
		{ typed: buffered, clipboard_status: model.clipboard_status, actions: [], tasks: [Program.read_clipboard(|result| ClipboardReadFinished(result))] }
	} else if ctrl_held and input.key_pressed(KeyX) {
		{ typed: "", clipboard_status: "cleared", actions: [], tasks: [] }
	} else if ctrl_held and input.key_pressed(KeyE) {
		# The same setting the startup config takes, applied mid-run.
		{ typed: buffered, clipboard_status: "Esc now exits again", actions: [Keys.set_exit_key(ExitKey(KeyEscape))], tasks: [] }
	} else if ctrl_held and input.key_pressed(KeyM) {
		{ typed: buffered, clipboard_status: "window minimum set to 640x480", actions: [Window.set_window_min_size({ width: 640, height: 480 })], tasks: [] }
	} else {
		{ typed: buffered, clipboard_status: model.clipboard_status, actions: [], tasks: [] }
	}

	# Ctrl+V can be pressed again before a slow earlier read answers. Fold every
	# message in host-observed order so no successful paste is silently lost; the
	# status describes the last terminal result in that order.
	pasted = apply_paste_messages({ typed: clipboard.typed, clipboard_status: clipboard.clipboard_status }, step.messages)

	# Applied in order, before anything is drawn, which is where the effects
	# they replace used to run.
	actions =
		List.join([
			if input.key_pressed(KeyQ) [Program.exit(0)] else [],
			if input.key_pressed(KeyH) [Mouse.set_cursor_mode(Hidden)] else [],
			if input.key_pressed(KeyJ) [Mouse.set_cursor_mode(Visible)] else [],
			if input.key_pressed(KeyK) [Mouse.set_cursor_mode(Locked)] else [],
			if input.key_pressed(KeyL) [Mouse.set_cursor_mode(Visible)] else [],
			clipboard.actions,
			[Mouse.set_cursor(if input.mouse.button_down(Left) Crosshair else Arrow)],
		])

	Program.static({ font: model.font, typed: pasted.typed, clipboard_status: pasted.clipboard_status, input: input })
		.with_actions(actions)
		.with_tasks(clipboard.tasks)
}

## Fold this step's callback messages into the text field.
##
## `TooLarge` is its own outcome rather than being folded into `NoText`: there
## *is* text, the host just would not copy that much of it onto the frame
## thread, and telling someone their clipboard is empty when it is not would be
## a lie the app is in a position to avoid.
##
## `Busy` is separate again, and for the same reason in reverse: the clipboard
## is fine and so is this app, the host simply had no room to start the read.
## That is the one outcome here worth asking for a second time.
apply_paste_messages : { typed : Str, clipboard_status : Str }, List(Msg) -> { typed : Str, clipboard_status : Str }
apply_paste_messages = |state, messages| List.fold(messages, state, apply_paste_message)

apply_paste_message : { typed : Str, clipboard_status : Str }, Msg -> { typed : Str, clipboard_status : Str }
apply_paste_message = |state, message|
	match message {
		ClipboardReadFinished(Ok(text)) => { typed: Str.concat(state.typed, text), clipboard_status: "pasted from clipboard" }
		# One error covers an empty clipboard and non-text content alike; the
		# windowing backend does not tell them apart.
		ClipboardReadFinished(Err(Unavailable)) => { ..state, clipboard_status: "clipboard has no text" }
		ClipboardReadFinished(Err(TooLarge)) => { ..state, clipboard_status: "clipboard holds too much text to paste" }
		ClipboardReadFinished(Err(Busy)) => { ..state, clipboard_status: "host was busy -- press Ctrl+V again" }
	}

expect apply_paste_messages(
	{ typed: "", clipboard_status: "idle" },
	[ClipboardReadFinished(Ok("first")), ClipboardReadFinished(Ok(" second"))],
) == { typed: "first second", clipboard_status: "pasted from clipboard" }

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
	Ok({})
}
