app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Capture
import rr.Color
import rr.Draw
import rr.Keys
import rr.Mouse
import rr.Text

## Record a UI demo driven by a scripted pointer and keyboard.
##
## `Mouse.set_source!` and `Keys.set_source!` replace only what the host reports
## on the input, so the widget code below is ordinary hover, hit-test and
## text-entry logic reading `input.mouse`, `input.text_input` and
## `input.key_pressed` -- it has no idea either device is scripted. That is the
## point: the recording exercises the real input path instead of a parallel
## fake one, so what you see in the GIF is what a real click or keystroke would
## do.
##
## Keys and text are separate channels because they are separate things. A key
## code says which key is held, and edges fall out of consecutive frames;
## `Keys.set_text!` says what characters were entered, which on a real keyboard
## depends on the layout and so cannot be derived from a key code. The field
## below fills from the text channel and its backspace comes from the key
## channel.
##
## The recording asks for `DrawCursor`, because the operating-system cursor is
## not part of the framebuffer and would otherwise be missing from the file.
##
## Run it, then open `captures/ui_demo.gif`.
Model : {
	frame : U64,
	pointer : { x : F32, y : F32 },

	## Where the host said the pointer was this cycle, as distinct from the
	## scripted `pointer` above. Hover and press styling are drawn from this,
	## so the recording shows what the app was really told.
	mouse : { x : F32, y : F32 },
	held : Bool,
	clicks : U64,
	toggled : Bool,
	slider : F32,

	## Whether the text field has the keyboard. Scripted text arrives whatever
	## has focus, exactly as hardware text would; it is this app that decides
	## the field is where it goes.
	focused : Bool,

	## How many characters of `field_text` the field holds. The script types
	## that string in order, so a count names the field's contents and the
	## labels for every reachable one are prepared up front.
	typed : U64,
	title : Text.Prepared,
	increment_label : Text.Prepared,
	toggle_label : Text.Prepared,
	counter_labels : List(Text.Prepared),
	field_labels : List(Text.Prepared),
}

program = { init!, update!, render! }

## Frames recorded before the host finalizes the file and the app exits.
recorded_frames : U64
recorded_frames = 240

## Highest click count the demo can reach, so its labels can be prepared once.
max_clicks : U64
max_clicks = 4

increment_button : { x : F32, y : F32, width : F32, height : F32 }
increment_button = { x: 60, y: 150, width: 170, height: 56 }

toggle_button : { x : F32, y : F32, width : F32, height : F32 }
toggle_button = { x: 260, y: 150, width: 170, height: 56 }

slider_track : { x : F32, y : F32, width : F32, height : F32 }
slider_track = { x: 60, y: 260, width: 370, height: 12 }

text_field : { x : F32, y : F32, width : F32, height : F32 }
text_field = { x: 60, y: 300, width: 370, height: 46 }

## What the script types, one character per typed frame.
field_text : List(Str)
field_text = ["r", "o", "c", "-", "r", "a", "y", "!"]

## Frame the first character is entered on, and the gap between characters.
first_type_frame : U64
first_type_frame = 165

type_every : U64
type_every = 6

## Frame the script holds backspace on, deleting the trailing `!`.
##
## One frame, so the field's `key_pressed` handling deletes exactly one
## character however long the recording runs at.
backspace_frame : U64
backspace_frame = 215

## Backspace lands after the last character and before the recording ends.
expect backspace_frame > first_type_frame + (List.len(field_text) - 1) * type_every
expect backspace_frame < recorded_frames

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("RocRay Capture: UI demo")
		.with_size({ width: 490, height: 380 })
		.with_frame_pacing(Capped(60))
		.with_visible(Bool.False)
		.with_output_dir("captures")
		.with_recording(
			Capture.default
				.with_path("ui_demo.gif")
				.with_format(Gif)
				.with_fps(25)
				.with_max_frames(recorded_frames)
				.with_scale(Full)
				.with_timing(FixedStep)
				.with_cursor(DrawCursor),
		),
	|_startup| {
		font = Draw.default_font!()
		Ok({
			frame: 0,
			pointer: { x: 40, y: 300 },
			mouse: { x: 40, y: 300 },
			held: Bool.False,
			clicks: 0,
			toggled: Bool.False,
			slider: 0,
			focused: Bool.False,
			typed: 0,
			title: Text.from("Scripted Input", font).size(24).prepare!()?,
			increment_label: Text.from("Increment", font).size(18).prepare!()?,
			toggle_label: Text.from("Toggle", font).size(18).prepare!()?,
			counter_labels: prepare_counter_labels!(font, 0, [])?,
			field_labels: prepare_field_labels!(font, 0, [])?,
		})
	},
)

## Prepare one label per reachable click count, so `render!` never lays out text.
prepare_counter_labels! : Draw.Font, U64, List(Text.Prepared) => Try(List(Text.Prepared), [ResourceLimit, ..])
prepare_counter_labels! = |font, index, acc|
	if index > max_clicks {
		Ok(acc)
	} else {
		label = Text.from("clicks: ${U64.to_str(index)}", font).size(18).prepare!()?
		prepare_counter_labels!(font, index + 1, List.append(acc, label))
	}

## Prepare one label per prefix of `field_text`, for the same reason.
##
## The script types that string in order and backspace only ever removes from
## its end, so every state the field can reach is one of these prefixes.
prepare_field_labels! : Draw.Font, U64, List(Text.Prepared) => Try(List(Text.Prepared), [ResourceLimit, ..])
prepare_field_labels! = |font, index, acc|
	if index > List.len(field_text) {
		Ok(acc)
	} else {
		label = Text.from(field_prefix(index), font).size(20).prepare!()?
		prepare_field_labels!(font, index + 1, List.append(acc, label))
	}

## The first `count` characters of what the script types.
field_prefix : U64 -> Str
field_prefix = |count|
	List.fold(List.sublist(field_text, { start: 0, len: count }), "", Str.concat)

expect field_prefix(0) == ""
expect field_prefix(3) == "roc"
expect field_prefix(List.len(field_text)) == "roc-ray!"

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices
	# Drive the pointer for the *next* frame from the script.
	pointer_step = pointer_for_frame(model.frame)

	# Where the pointer is *this* frame: the position scripted on the previous
	# one, which the model already kept. Reading it back off `input.mouse` would
	# work -- the host samples the scripted pointer into the input exactly as it
	# does a hardware one -- but the app is the thing that scripted it, so it
	# has no reason to ask the host what it already said.
	mouse = model.pointer
	over_increment = inside(mouse, increment_button)
	over_toggle = inside(mouse, toggle_button)

	# Ordinary edge-triggered click handling. The virtual pointer
	# produces real pressed-this-frame bits, so this needs no special
	# casing.
	pressed = input.mouse.button_pressed(Left)
	clicks = if pressed and over_increment and model.clicks < max_clicks model.clicks + 1 else model.clicks
	toggled = if pressed and over_toggle !(model.toggled) else model.toggled

	held = input.mouse.button_down(Left)
	slider =
		if held and inside_slider(mouse) {
			clamp_unit((mouse.x - slider_track.x) / slider_track.width)
		} else {
			model.slider
		}

	# Ordinary focus handling: a click puts the keyboard wherever it landed.
	focused = if pressed inside(mouse, text_field) else model.focused

	# Ordinary text entry, from the two channels a keyboard has. Codepoints
	# arrive on `text_input`; backspace is key state, and its edge is produced
	# by the same detector that gives a hardware key one.
	typed = field_after_input(
		model.typed,
		focused,
		List.len(input.text_input),
		input.key_pressed(KeyBackspace),
	)

	# The scripted devices are installed here, before anything is drawn, and a
	# cycle before the host samples them back.
	Mouse.set_source!(
		if pointer_step.clicking Mouse.virtual_click_at(pointer_step.pos) else Mouse.virtual_at(pointer_step.pos),
	)
	Keys.set_source!(if model.frame == backspace_frame Keys.holding([KeyBackspace]) else Keys.holding([]))
	next_char = typed_char(model.frame)
	if !Str.is_empty(next_char) {
		Keys.set_text!(Keys.typing(next_char))
	}

	if model.frame >= recorded_frames {
		Err(Exit(0))
	} else {
		Ok({
			..model,
			frame: model.frame + 1,
			pointer: pointer_step.pos,
			mouse: mouse,
			held: held,
			clicks: clicks,
			toggled: toggled,
			slider: slider,
			focused: focused,
			typed: typed,
		})
	}
}

## Fold one cycle of keyboard input into the field's character count.
##
## Kept pure so the expects below cover it: the recording is the illustration,
## not the test.
field_after_input : U64, Bool, U64, Bool -> U64
field_after_input = |typed, focused, entered, backspace|
	if !focused {
		typed
	} else {
		grown = typed + entered
		filled = if grown > List.len(field_text) List.len(field_text) else grown
		if backspace and filled > 0 filled - 1 else filled
	}

## Text arriving while the field is not focused goes nowhere.
expect field_after_input(0, Bool.False, 2, Bool.False) == 0

expect field_after_input(0, Bool.True, 1, Bool.False) == 1
expect field_after_input(3, Bool.True, 0, Bool.True) == 2
expect field_after_input(0, Bool.True, 0, Bool.True) == 0

## The field stops at the string the script types, so `render!` always has a
## prepared label for the count.
expect field_after_input(List.len(field_text), Bool.True, 3, Bool.False) == List.len(field_text)

## The character the script enters on a given frame, or "" for frames that
## type nothing -- which is most of them.
typed_char : U64 -> Str
typed_char = |frame|
	if frame < first_type_frame or (frame - first_type_frame) % type_every != 0 {
		""
	} else {
		match List.get(field_text, (frame - first_type_frame) / type_every) {
			Ok(character) => character
			Err(_) => ""
		}
	}

expect typed_char(first_type_frame) == "r"
expect typed_char(first_type_frame + 1) == ""
expect typed_char(first_type_frame + type_every) == "o"
expect typed_char(first_type_frame + 7 * type_every) == "!"

## Typing stops when the string runs out rather than wrapping around.
expect typed_char(first_type_frame + 8 * type_every) == ""
expect typed_char(0) == ""

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	over_increment = inside(model.mouse, increment_button)
	over_toggle = inside(model.mouse, toggle_button)

	frame.clear!(theme.bg)
	model.title.draw!(frame, { pos: { x: 40, y: 22 }, color: theme.ink, align: Text.align_top_left })
	frame.text_at!({ pos: { x: 40, y: 54 }, text: "A scripted pointer and keyboard on the real input path", size: 13, color: theme.muted })
	frame.rounded_rectangle!({ x: widget_panel.x, y: widget_panel.y, width: widget_panel.width, height: widget_panel.height, radius: 12, segments: 8, style: Draw.filled_and_outlined(theme.panel, theme.edge, 1) })

	draw_button!(frame, increment_button, over_increment, model.held and over_increment, model.increment_label)
	draw_button!(frame, toggle_button, over_toggle, model.toggled, model.toggle_label)
	draw_slider!(frame, model.slider)
	draw_field_box!(frame, model.focused)

	match List.get(model.field_labels, model.typed) {
		Ok(label) => {
			label.draw!(frame, { pos: field_text_origin, color: theme.ink, align: Text.align_top_left })
			if model.focused and caret_visible(model.frame) {
				draw_caret!(frame, field_text_origin.x + label.bounds().width + 3)
			}
		}

		Err(_) => {}
	}

	match List.get(model.counter_labels, U64.to_u64(model.clicks)) {
		Ok(label) => label.draw!(frame, { pos: { x: 40, y: 92 }, color: Color.from_hex_rgb(0x3ddc97), align: Text.align_top_left })
		Err(_) => {}
	}

	frame.text_at!({ pos: { x: 40, y: 364 }, text: "Recording captures/ui_demo.gif", size: 11, color: theme.faint })

	Ok({})
}

## A caret that blinks about twice a second at the recorded frame rate.
caret_visible : U64 -> Bool
caret_visible = |frame| (frame / 15) % 2 == 0

expect caret_visible(0)
expect !caret_visible(15)
expect caret_visible(30)

## Where the scripted pointer is on a given frame, and whether it is clicking.
##
## Kept in the example rather than the platform: it is ordinary easing over
## `frame`, and baking a scripting DSL into the API would be premature.
pointer_for_frame : U64 -> { pos : { x : F32, y : F32 }, clicking : Bool }
pointer_for_frame = |frame| {
	f = U64.to_f32(frame)
	increment_center = { x: increment_button.x + increment_button.width / 2, y: increment_button.y + increment_button.height / 2 }
	toggle_center = { x: toggle_button.x + toggle_button.width / 2, y: toggle_button.y + toggle_button.height / 2 }
	slider_left = { x: slider_track.x + 8, y: slider_track.y + slider_track.height / 2 }
	slider_right = { x: slider_track.x + slider_track.width - 8, y: slider_track.y + slider_track.height / 2 }

	if frame < 25 {
		# Glide in from the corner and settle over the first button.
		{ pos: ease({ x: 40, y: 300 }, increment_center, f / 25), clicking: Bool.False }
	} else if frame < 40 {
		# Two clicks, each one frame down so an edge is produced.
		{ pos: increment_center, clicking: frame == 30 or frame == 36 }
	} else if frame < 60 {
		{ pos: ease(increment_center, toggle_center, (f - 40) / 20), clicking: Bool.False }
	} else if frame < 75 {
		{ pos: toggle_center, clicking: frame == 66 }
	} else if frame < 95 {
		{ pos: ease(toggle_center, slider_left, (f - 75) / 20), clicking: Bool.False }
	} else if frame < 135 {
		# Drag the slider end to end with the button held the whole way.
		{ pos: ease(slider_left, slider_right, (f - 95) / 40), clicking: Bool.True }
	} else if frame < 155 {
		{ pos: ease(slider_right, field_center, (f - 135) / 20), clicking: Bool.False }
	} else {
		# One click to give the field the keyboard, then the pointer rests
		# while the typing happens.
		{ pos: field_center, clicking: frame == 158 }
	}
}

## Where the pointer clicks to focus the text field.
field_center : { x : F32, y : F32 }
field_center = { x: text_field.x + text_field.width / 2, y: text_field.y + text_field.height / 2 }

## The field is focused before the first character is typed, so no keystroke
## is thrown away.
expect 158 < first_type_frame
expect inside(pointer_for_frame(158).pos, text_field)

## Smoothstep between two points, so the pointer accelerates and settles like a
## hand rather than sliding at a constant speed.
ease : { x : F32, y : F32 }, { x : F32, y : F32 }, F32 -> { x : F32, y : F32 }
ease = |from, to, raw| {
	t = clamp_unit(raw)
	smooth = t * t * (3 - 2 * t)
	{ x: from.x + (to.x - from.x) * smooth, y: from.y + (to.y - from.y) * smooth }
}

clamp_unit : F32 -> F32
clamp_unit = |value| if value < 0 0 else if value > 1 1 else value

inside : { x : F32, y : F32 }, { x : F32, y : F32, width : F32, height : F32 } -> Bool
inside = |point, box|
	point.x >= box.x and point.x <= box.x + box.width and point.y >= box.y and point.y <= box.y + box.height

## The slider grabs a taller band than it draws, the way a real one does.
inside_slider : { x : F32, y : F32 } -> Bool
inside_slider = |point|
	inside(point, { x: slider_track.x, y: slider_track.y - 14, width: slider_track.width, height: slider_track.height + 28 })

## The shared surface palette for the demo's chrome. The accent is what the
## recording is meant to show moving: hover, press, focus and fill all use it.
theme : { bg : Color.Rgba, panel : Color.Rgba, control : Color.Rgba, hover : Color.Rgba, edge : Color.Rgba, ink : Color.Rgba, muted : Color.Rgba, faint : Color.Rgba, accent : Color.Rgba }
theme = {
	bg: Color.from_hex_rgb(0x0e1420),
	panel: Color.from_hex_rgb(0x161f31),
	control: Color.from_hex_rgb(0x223052),
	hover: Color.from_hex_rgb(0x33507f),
	edge: Color.from_hex_rgb(0x2b3856),
	ink: Color.from_hex_rgb(0xe6ecf5),
	muted: Color.from_hex_rgb(0x8fa0bd),
	faint: Color.from_hex_rgb(0x5c6b87),
	accent: Color.from_hex_rgb(0x88c0d0),
}

## The card every widget sits on, so the recording reads as one surface.
widget_panel : { x : F32, y : F32, width : F32, height : F32 }
widget_panel = { x: 40, y: 126, width: 410, height: 232 }

draw_button! : Draw.Frame, { x : F32, y : F32, width : F32, height : F32 }, Bool, Bool, Text.Prepared => {}
draw_button! = |frame, box, hovered, active, label| {
	fill =
		if active {
			theme.accent
		} else if hovered {
			theme.hover
		} else {
			theme.control
		}

	frame.rounded_rectangle!({
		x: box.x,
		y: box.y,
		width: box.width,
		height: box.height,
		radius: 10,
		segments: 8,
		style: Draw.filled_and_outlined(fill, if active or hovered theme.accent else theme.edge, 2),
	})
	label.draw!(
		frame,
		{
			pos: { x: box.x + box.width / 2, y: box.y + box.height / 2 - 10 },
			color: if active Color.from_hex_rgb(0x08131f) else theme.ink,
			align: Text.align_top_center,
		},
	)
}

## Where the field's text starts, and where its caret is measured from.
field_text_origin : { x : F32, y : F32 }
field_text_origin = { x: text_field.x + 14, y: text_field.y + 12 }

## Draw the text field's box. A focused field is outlined the way a focused
## one is anywhere else, so the recording shows the keyboard's whereabouts.
draw_field_box! : Draw.Frame, Bool => {}
draw_field_box! = |frame, focused| {
	outline = if focused theme.accent else theme.edge
	frame.rounded_rectangle!({
		x: text_field.x,
		y: text_field.y,
		width: text_field.width,
		height: text_field.height,
		radius: 8,
		segments: 8,
		style: Draw.filled_and_outlined(Color.from_hex_rgb(0x111a2b), outline, 2),
	})
}

## Draw the insertion caret at an x within the field.
draw_caret! : Draw.Frame, F32 => {}
draw_caret! = |frame, x|
	frame.rectangle!({
		x,
		y: field_text_origin.y,
		width: 2,
		height: 22,
		style: Draw.filled(theme.accent),
	})

draw_slider! : Draw.Frame, F32 => {}
draw_slider! = |frame, value| {
	frame.rounded_rectangle!({
		x: slider_track.x,
		y: slider_track.y,
		width: slider_track.width,
		height: slider_track.height,
		radius: 6,
		segments: 6,
		style: Draw.filled(theme.control),
	})
	frame.rounded_rectangle!({
		x: slider_track.x,
		y: slider_track.y,
		width: slider_track.width * value,
		height: slider_track.height,
		radius: 6,
		segments: 6,
		style: Draw.filled(theme.accent),
	})
	frame.circle!({
		center: { x: slider_track.x + slider_track.width * value, y: slider_track.y + slider_track.height / 2 },
		radius: 11,
		style: Draw.filled_and_outlined(Color.white, theme.edge, 2),
	})
}

expect clamp_unit(-0.5) == 0
expect clamp_unit(1.5) == 1
expect inside({ x: 70, y: 160 }, increment_button)
expect !inside({ x: 10, y: 10 }, increment_button)

## The slider's grab band is taller than the track it draws.
expect inside_slider({ x: slider_track.x + 4, y: slider_track.y - 10 })

## Easing starts and ends exactly on its endpoints, so a script that eases into
## a button really does arrive over it.
expect ease({ x: 0, y: 0 }, { x: 100, y: 40 }, 0) == { x: 0, y: 0 }
expect ease({ x: 0, y: 0 }, { x: 100, y: 40 }, 1) == { x: 100, y: 40 }

## The two clicks on the counter are single frames, so each one is an edge the
## widget code sees exactly once.
expect pointer_for_frame(30).clicking
expect !pointer_for_frame(31).clicking

## Every scripted click lands inside the widget it is aimed at.
expect inside(pointer_for_frame(30).pos, increment_button)
expect inside(pointer_for_frame(66).pos, toggle_button)
