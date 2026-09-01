## Display live keyboard, mouse, gamepad, text, window, and capture input.
##
## The window lists its controls; Q quits because Escape is displayed as an
## ordinary key. This example shows how each `Input` gives `update!` the latest
## device state and the ordered record of what the devices did, and how
## `update!` can change the clipboard, cursor, and window or read a pixel from
## the previous drawing. Every cycle with events prints them to stdout in
## delivery order, which is what the windowed sweep asserts on.
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
import rr.Stdout

## State kept between updates: accumulated typed text, clipboard feedback, the
## latest device snapshot, and the last colour read beneath the pointer. The
## font is retained for drawing each new snapshot.
Model : {
	font : Text.Font,
	chips : Box(ChipLabels),

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

	## The most recent cycle's event record, described.
	events_line : Str,
}

ChipLabels : {
	w : Text.Prepared,
	a : Text.Prepared,
	s : Text.Prepared,
	d : Text.Prepared,
	up : Text.Prepared,
	left : Text.Prepared,
	down : Text.Prepared,
	right : Text.Prepared,
	one : Text.Prepared,
	shift : Text.Prepared,
	ctrl : Text.Prepared,
	escape : Text.Prepared,
	space : Text.Prepared,
	mouse_down : Text.Prepared,
	mouse_up : Text.Prepared,
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

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("RocRay Input Inspector")
		.with_size({ width: 820, height: 700 })
		.with_resizable(Bool.True)
	# Without this raylib closes the window on Escape, so the Esc indicator
	# below could never light up. Q exits instead.
		.with_exit_key(NoExitKey)
		.with_frame_pacing(Capped(120)),
	|_startup| {
		font = Draw.default_font!()
		Ok({
			font,
			chips: Box.box({
				w: Text.from("W", font).size(17).prepare!()?,
				a: Text.from("A", font).size(17).prepare!()?,
				s: Text.from("S", font).size(17).prepare!()?,
				d: Text.from("D", font).size(17).prepare!()?,
				up: Text.from("^", font).size(17).prepare!()?,
				left: Text.from("<", font).size(17).prepare!()?,
				down: Text.from("v", font).size(17).prepare!()?,
				right: Text.from(">", font).size(17).prepare!()?,
				one: Text.from("1", font).size(17).prepare!()?,
				shift: Text.from("Shift", font).size(17).prepare!()?,
				ctrl: Text.from("Ctrl", font).size(17).prepare!()?,
				escape: Text.from("Esc", font).size(17).prepare!()?,
				space: Text.from("Space", font).size(17).prepare!()?,
				mouse_down: Text.from("Mouse down", font).size(17).prepare!()?,
				mouse_up: Text.from("Mouse up", font).size(17).prepare!()?,
			}),
			typed: "",
			clipboard_status: "clipboard idle",
			input: Devices.empty,
			picked: Err(Unavailable),
			events_line: "events: none yet",
		})
	},
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

	# The record, as opposed to the bits the chips show: every edge, click,
	# notch and character in the order it happened. A cycle with nothing in
	# it keeps the previous line on screen and prints nothing.
	events_line =
		if List.is_empty(input.events) {
			model.events_line
		} else {
			line = describe_events(input.events, input.events_overflow)
			_ = Stdout.line!(line)
			line
		}

	if input.key_pressed(KeyQ) {
		Err(Exit(0))
	} else {
		Ok({ font: model.font, chips: model.chips, typed: clipboard.typed, clipboard_status: clipboard.clipboard_status, input: input, picked: picked, events_line: events_line })
	}
}

## One event as a short label, by code rather than name so the line stays
## one token per event: `KeyPressed(65)`, `ButtonReleased(Left at 12,34)`.
event_label : Devices.Event -> Str
event_label = |event|
	match event {
		KeyPressed(key) => "KeyPressed(${U64.to_str(Keys.key_code(key))})"
		KeyReleased(key) => "KeyReleased(${U64.to_str(Keys.key_code(key))})"
		ButtonPressed(button, at) => "ButtonPressed(${button_label(button)} at ${F32.to_str(at.x)},${F32.to_str(at.y)})"
		ButtonReleased(button, at) => "ButtonReleased(${button_label(button)} at ${F32.to_str(at.x)},${F32.to_str(at.y)})"
		Wheel(delta) => "Wheel(${F32.to_str(delta.x)},${F32.to_str(delta.y)})"
		Text(codepoint) => "Text(${U32.to_str(codepoint)})"
	}

button_label : Mouse.Button -> Str
button_label = |button|
	match button {
		Left => "Left"
		Right => "Right"
		Middle => "Middle"
		Side => "Side"
		Extra => "Extra"
		Forward => "Forward"
		Back => "Back"
	}

## The whole record on one line, in delivery order, with the overflow flag.
describe_events : List(Devices.Event), Bool -> Str
describe_events = |events, overflowed| {
	labels = Str.join_with(List.map(events, event_label), " ")
	if overflowed "events: ${labels} (overflowed)" else "events: ${labels}"
}

expect event_label(KeyPressed(KeyA)) == "KeyPressed(65)"
expect event_label(ButtonReleased(Left, { x: 12, y: 34 })) == "ButtonReleased(Left at 12,34)"
expect event_label(Wheel({ x: 0, y: 1 })) == "Wheel(0,1)"
expect event_label(Text(104)) == "Text(104)"
expect describe_events([KeyPressed(KeyA), KeyReleased(KeyA), Text(104)], Bool.False) == "events: KeyPressed(65) KeyReleased(65) Text(104)"
expect describe_events([Text(104)], Bool.True) == "events: Text(104) (overflowed)"

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
	draw = App.effects().render(frame)
	draw.rounded_rectangle!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, radius: 12, segments: 8, style: Draw.filled_and_outlined(theme.panel, theme.edge, 1) })
	draw.text!({ pos: { x: cfg.x + 18, y: cfg.y + 12 }, text: cfg.label, size: 14, spacing: Draw.default_spacing, color: theme.muted, font: font })
}

## One indicator chip, lit while the snapshot says its input is active.
chip! : Draw.Frame, Text.Prepared, { x : F32, y : F32, width : F32, on : Bool } => {}
chip! = |frame, label, cfg| {
	draw = App.effects().render(frame)
	fill = if cfg.on theme.active else theme.idle
	edge = if cfg.on theme.active else theme.edge
	ink = if cfg.on theme.active_ink else theme.idle_ink
	draw.rounded_rectangle!({ x: cfg.x, y: cfg.y, width: cfg.width, height: 30, radius: 8, segments: 6, style: Draw.filled_and_outlined(fill, edge, 1) })
	label.draw!(frame, { pos: { x: cfg.x + cfg.width / 2, y: cfg.y + 15 }, color: ink, align: (Middle, Center) })
}

## A small square light next to a label, for the signals that are on or off
## rather than named keys.
light! : Draw.Frame, Text.Font, { x : F32, y : F32, label : Str, on : Bool } => {}
light! = |frame, font, cfg| {
	draw = App.effects().render(frame)
	draw.text!({ pos: { x: cfg.x, y: cfg.y + 3 }, text: cfg.label, size: 16, spacing: Draw.default_spacing, color: theme.muted, font: font })
	fill = if cfg.on theme.active else theme.idle
	draw.rounded_rectangle!({ x: cfg.x + 130, y: cfg.y, width: 22, height: 22, radius: 6, segments: 6, style: Draw.filled_and_outlined(fill, if cfg.on theme.active else theme.edge, 1) })
}

## A line of body text inside a panel.
line! : Draw.Effects, Text.Font, { x : F32, y : F32, text : Str, color : Color.Rgba } => {}
line! = |draw, font, cfg|
	draw.text!({ pos: { x: cfg.x, y: cfg.y }, text: cfg.text, size: 16, spacing: Draw.default_spacing, color: cfg.color, font: font })

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	draw = App.effects().render(frame)
	input = model.input
	font = model.font
	chips = Box.unbox(model.chips)

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
	draw.text!({ pos: { x: 30, y: 26 }, text: title, size: 26, spacing: Draw.default_spacing, color: theme.ink, font: font })
	draw.text!({ pos: { x: 30, y: 58 }, text: "Every field of one Devices.Snapshot, live; the bits as chips, the event record as a line", size: 15, spacing: Draw.default_spacing, color: theme.muted, font: font })

	panel!(frame, font, { x: 20, y: 84, width: 780, height: 258, label: "KEYS AND BUTTONS" })
	chip!(frame, chips.w, { x: 70, y: 126, width: 30, on: w_down })
	chip!(frame, chips.a, { x: 30, y: 161, width: 30, on: a_down })
	chip!(frame, chips.s, { x: 70, y: 161, width: 30, on: s_down })
	chip!(frame, chips.d, { x: 110, y: 161, width: 30, on: d_down })
	chip!(frame, chips.up, { x: 250, y: 126, width: 30, on: up_down })
	chip!(frame, chips.left, { x: 210, y: 161, width: 30, on: left_down })
	chip!(frame, chips.down, { x: 250, y: 161, width: 30, on: down_down })
	chip!(frame, chips.right, { x: 290, y: 161, width: 30, on: right_down })
	chip!(frame, chips.one, { x: 30, y: 246, width: 50, on: one_down })
	chip!(frame, chips.shift, { x: 90, y: 246, width: 80, on: shift_down })
	chip!(frame, chips.ctrl, { x: 180, y: 246, width: 70, on: ctrl_down })
	chip!(frame, chips.escape, { x: 260, y: 246, width: 80, on: escape_pressed })
	chip!(frame, chips.space, { x: 350, y: 246, width: 90, on: space_released })
	chip!(frame, chips.mouse_down, { x: 30, y: 296, width: 130, on: mouse_left_pressed })
	chip!(frame, chips.mouse_up, { x: 170, y: 296, width: 110, on: mouse_left_released })

	panel!(frame, font, { x: 20, y: 356, width: 780, height: 108, label: "SIGNALS" })
	light!(frame, font, { x: 30, y: 388, label: "Typed Unicode", on: text_entered })
	light!(frame, font, { x: 220, y: 388, label: "Mouse delta", on: mouse_moved })
	light!(frame, font, { x: 410, y: 388, label: "Wheel x/y", on: wheel_moved })
	light!(frame, font, { x: 30, y: 424, label: "Gamepad 1", on: gamepad_connected })
	light!(frame, font, { x: 220, y: 424, label: "Left stick", on: stick_moved })
	light!(frame, font, { x: 410, y: 424, label: "Face down", on: gamepad_action_pressed })
	line!(draw, font, { x: 600, y: 391, text: "Mouse ${F32.to_str(mouse_position.x)}, ${F32.to_str(mouse_position.y)}", color: theme.muted })
	draw.text!({ pos: { x: 30, y: 446 }, text: model.events_line, size: 13, spacing: Draw.default_spacing, color: theme.ink, font: font })

	panel!(frame, font, { x: 20, y: 478, width: 780, height: 184, label: "HOST EFFECTS" })
	line!(draw, font, { x: 30, y: 510, text: cursor_help_visibility, color: theme.muted })
	line!(draw, font, { x: 250, y: 510, text: cursor_help_locking, color: theme.muted })
	line!(draw, font, { x: 30, y: 536, text: clipboard_help, color: theme.muted })
	line!(draw, font, { x: 30, y: 560, text: window_help, color: theme.muted })
	line!(draw, font, { x: 30, y: 586, text: Str.concat("Buffer: ", model.typed), color: theme.ink })
	line!(draw, font, { x: 30, y: 610, text: model.clipboard_status, color: theme.muted })
	draw.rounded_rectangle!({ x: 30, y: 632, width: 22, height: 22, radius: 6, segments: 6, style: Draw.filled_and_outlined(eyedropper_swatch(model.picked), theme.edge, 1) })
	line!(draw, font, { x: 62, y: 634, text: eyedropper_label(model.picked), color: theme.muted })

	draw.text!({ pos: { x: 30, y: 676 }, text: "Q exits  |  Esc is a normal key  |  hold left mouse for a crosshair", size: 14, spacing: Draw.default_spacing, color: Color.from_hex_rgb(0x5c6b87), font: font })
	Ok({})
}
