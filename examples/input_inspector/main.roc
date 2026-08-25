## Display live keyboard, mouse, gamepad, text, window, and capture input.
##
## The window lists its controls; Q quits because Escape is displayed as an
## ordinary key. This example shows how each `Input` gives `update!` the latest
## device state, and how `update!` can change the clipboard, cursor, and window
## or read a pixel from the previous drawing.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.Draw
import rr.Text
import rr.Color
import rr.Devices
import rr.Window
import rr.Keys
import rr.Mouse
import rr.Gamepad
import rr.App
import rr.Capture

## State kept between updates: accumulated typed text, clipboard feedback, the
## latest device snapshot, and the last colour read beneath the pointer. The
## font is retained for drawing each new snapshot.
Model : {
	font : Text.Font,

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

## The swatch colour to draw for one reading. A failed read shows the same
## unlit fill every other inactive indicator here uses.
eyedropper_swatch : Picked -> Color.Rgba
eyedropper_swatch = |picked|
	match picked {
		Ok(color) => color
		Err(_) => theme.idle
	}

expect eyedropper_swatch(Ok(Color.rgba(9, 9, 9, 255))) == Color.rgba(9, 9, 9, 255)
expect eyedropper_swatch(Err(Busy)) == theme.idle

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

## The shared surface palette. Every panel, label and indicator in the
## inspector reads from this one record, so the whole window keeps one theme.
theme : { bg : Color.Rgba, panel : Color.Rgba, edge : Color.Rgba, ink : Color.Rgba, muted : Color.Rgba, idle : Color.Rgba, idle_ink : Color.Rgba, active : Color.Rgba, active_ink : Color.Rgba }
theme = {
	bg: Color.from_hex_rgb(0x0e1420),
	panel: Color.from_hex_rgb(0x161f31),
	edge: Color.from_hex_rgb(0x25314b),
	ink: Color.from_hex_rgb(0xe6ecf5),
	muted: Color.from_hex_rgb(0x8fa0bd),
	idle: Color.from_hex_rgb(0x1e2942),
	idle_ink: Color.from_hex_rgb(0x7183a3),
	active: Color.from_hex_rgb(0x3ddc97),
	active_ink: Color.from_hex_rgb(0x08131f),
}

## A titled surface for one group of indicators.
panel! : Draw.Frame, Text.Font, { x : F32, y : F32, width : F32, height : F32, label : Str } => {}
panel! = |frame, font, cfg| {
	frame.rounded_rectangle!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, radius: 12, segments: 8, style: Draw.filled_and_outlined(theme.panel, theme.edge, 1) })
	frame.text!({ pos: { x: cfg.x + 18, y: cfg.y + 12 }, text: cfg.label, size: 14, spacing: Draw.default_spacing, color: theme.muted, font: font })
}

## One indicator chip, lit while the snapshot says its input is active.
chip! : Draw.Frame, Text.Font, { x : F32, y : F32, width : F32, label : Str, on : Bool } => {}
chip! = |frame, font, cfg| {
	fill = if cfg.on theme.active else theme.idle
	edge = if cfg.on theme.active else theme.edge
	ink = if cfg.on theme.active_ink else theme.idle_ink
	frame.rounded_rectangle!({ x: cfg.x, y: cfg.y, width: cfg.width, height: 30, radius: 8, segments: 6, style: Draw.filled_and_outlined(fill, edge, 1) })
	Text.from(cfg.label, font)
		.size(17)
		.draw!(frame, { pos: { x: cfg.x + cfg.width / 2, y: cfg.y + 15 }, color: ink, align: (Middle, Center) })
}

## A small square light next to a label, for the signals that are on or off
## rather than named keys.
light! : Draw.Frame, Text.Font, { x : F32, y : F32, label : Str, on : Bool } => {}
light! = |frame, font, cfg| {
	frame.text!({ pos: { x: cfg.x, y: cfg.y + 3 }, text: cfg.label, size: 16, spacing: Draw.default_spacing, color: theme.muted, font: font })
	fill = if cfg.on theme.active else theme.idle
	frame.rounded_rectangle!({ x: cfg.x + 130, y: cfg.y, width: 22, height: 22, radius: 6, segments: 6, style: Draw.filled_and_outlined(fill, if cfg.on theme.active else theme.edge, 1) })
}

## A line of body text inside a panel.
line! : Draw.Frame, Text.Font, { x : F32, y : F32, text : Str, color : Color.Rgba } => {}
line! = |frame, font, cfg|
	frame.text!({ pos: { x: cfg.x, y: cfg.y }, text: cfg.text, size: 16, spacing: Draw.default_spacing, color: cfg.color, font: font })

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	input = model.input
	font = model.font

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

	frame.clear!(theme.bg)
	frame.text!({ pos: { x: 30, y: 26 }, text: title, size: 26, spacing: Draw.default_spacing, color: theme.ink, font: font })
	frame.text!({ pos: { x: 30, y: 58 }, text: "Every field of one Devices.Snapshot, live", size: 15, spacing: Draw.default_spacing, color: theme.muted, font: font })

	panel!(frame, font, { x: 20, y: 84, width: 780, height: 258, label: "KEYS AND BUTTONS" })
	chip!(frame, font, { x: 70, y: 126, width: 30, label: "W", on: w_down })
	chip!(frame, font, { x: 30, y: 161, width: 30, label: "A", on: a_down })
	chip!(frame, font, { x: 70, y: 161, width: 30, label: "S", on: s_down })
	chip!(frame, font, { x: 110, y: 161, width: 30, label: "D", on: d_down })
	chip!(frame, font, { x: 250, y: 126, width: 30, label: "^", on: up_down })
	chip!(frame, font, { x: 210, y: 161, width: 30, label: "<", on: left_down })
	chip!(frame, font, { x: 250, y: 161, width: 30, label: "v", on: down_down })
	chip!(frame, font, { x: 290, y: 161, width: 30, label: ">", on: right_down })
	chip!(frame, font, { x: 30, y: 246, width: 50, label: "1", on: one_down })
	chip!(frame, font, { x: 90, y: 246, width: 80, label: "Shift", on: shift_down })
	chip!(frame, font, { x: 180, y: 246, width: 70, label: "Ctrl", on: ctrl_down })
	chip!(frame, font, { x: 260, y: 246, width: 80, label: "Esc", on: escape_pressed })
	chip!(frame, font, { x: 350, y: 246, width: 90, label: "Space", on: space_released })
	chip!(frame, font, { x: 30, y: 296, width: 130, label: "Mouse down", on: mouse_left_pressed })
	chip!(frame, font, { x: 170, y: 296, width: 110, label: "Mouse up", on: mouse_left_released })

	panel!(frame, font, { x: 20, y: 356, width: 780, height: 108, label: "SIGNALS" })
	light!(frame, font, { x: 30, y: 388, label: "Typed Unicode", on: text_entered })
	light!(frame, font, { x: 220, y: 388, label: "Mouse delta", on: mouse_moved })
	light!(frame, font, { x: 410, y: 388, label: "Wheel x/y", on: wheel_moved })
	light!(frame, font, { x: 30, y: 424, label: "Gamepad 1", on: gamepad_connected })
	light!(frame, font, { x: 220, y: 424, label: "Left stick", on: stick_moved })
	light!(frame, font, { x: 410, y: 424, label: "Face down", on: gamepad_action_pressed })
	line!(frame, font, { x: 600, y: 391, text: "Mouse ${F32.to_str(mouse_position.x)}, ${F32.to_str(mouse_position.y)}", color: theme.muted })

	panel!(frame, font, { x: 20, y: 478, width: 780, height: 184, label: "HOST EFFECTS" })
	line!(frame, font, { x: 30, y: 510, text: cursor_help_visibility, color: theme.muted })
	line!(frame, font, { x: 250, y: 510, text: cursor_help_locking, color: theme.muted })
	line!(frame, font, { x: 30, y: 536, text: clipboard_help, color: theme.muted })
	line!(frame, font, { x: 30, y: 560, text: window_help, color: theme.muted })
	line!(frame, font, { x: 30, y: 586, text: Str.concat("Buffer: ", model.typed), color: theme.ink })
	line!(frame, font, { x: 30, y: 610, text: model.clipboard_status, color: theme.muted })
	frame.rounded_rectangle!({ x: 30, y: 632, width: 22, height: 22, radius: 6, segments: 6, style: Draw.filled_and_outlined(eyedropper_swatch(model.picked), theme.edge, 1) })
	line!(frame, font, { x: 62, y: 634, text: eyedropper_label(model.picked), color: theme.muted })

	frame.text!({ pos: { x: 30, y: 676 }, text: "Q exits  |  Esc is a normal key  |  hold left mouse for a crosshair", size: 14, spacing: Draw.default_spacing, color: Color.from_hex_rgb(0x5c6b87), font: font })
	Ok({})
}
