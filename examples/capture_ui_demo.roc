app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Capture
import rr.Color
import rr.Draw
import rr.Host
import rr.Text

## Record a UI demo driven by a scripted pointer.
##
## `Capture.set_virtual_mouse!` replaces only what the host reports to
## `render!`, so the widget code below is ordinary hover and hit-test logic
## reading `host.mouse` -- it has no idea the pointer is scripted. That is the
## point: the recording exercises the real input path instead of a parallel
## fake one, so what you see in the GIF is what a real click would do.
##
## The recording asks for `DrawCursor`, because the operating-system cursor is
## not part of the framebuffer and would otherwise be missing from the file.
##
## Run it, then open `captures/ui_demo.gif`.
Model : {
	frame : U64,
	pointer : { x : F32, y : F32 },
	clicking : Bool,
	clicks : U64,
	toggled : Bool,
	slider : F32,
	title : Text.Prepared,
	increment_label : Text.Prepared,
	toggle_label : Text.Prepared,
	counter_labels : List(Text.Prepared),
}

program = { init!, render! }

## Frames recorded before the host finalizes the file and the app exits.
recorded_frames : U64
recorded_frames = 150

## Highest click count the demo can reach, so its labels can be prepared once.
max_clicks : U64
max_clicks = 4

increment_button : { x : F32, y : F32, width : F32, height : F32 }
increment_button = { x: 60, y: 150, width: 170, height: 56 }

toggle_button : { x : F32, y : F32, width : F32, height : F32 }
toggle_button = { x: 260, y: 150, width: 170, height: 56 }

slider_track : { x : F32, y : F32, width : F32, height : F32 }
slider_track = { x: 60, y: 260, width: 370, height: 12 }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("RocRay Capture: UI demo")
		.with_size({ width: 490, height: 320 })
		.with_frame_pacing(Capped(60))
		.with_visible(Bool.False)
		.with_output_dir("captures")
		.with_recording(
			Record(
				Capture.default
					.with_path("ui_demo.gif")
					.with_format(Gif)
					.with_fps(25)
					.with_max_frames(recorded_frames)
					.with_scale(Full)
					.with_timing(FixedStep)
					.with_cursor(DrawCursor),
			),
		),
	|_host|
		Ok({
			frame: 0,
			pointer: { x: 40, y: 300 },
			clicking: Bool.False,
			clicks: 0,
			toggled: Bool.False,
			slider: 0,
			title: Text.from("Scripted pointer").size(24).prepare!()?,
			increment_label: Text.from("Increment").size(18).prepare!()?,
			toggle_label: Text.from("Toggle").size(18).prepare!()?,
			counter_labels: prepare_counter_labels!(0, [])?,
		}),
)

## Prepare one label per reachable click count, so `render!` never lays out text.
prepare_counter_labels! : U64, List(Text.Prepared) => Try(List(Text.Prepared), [ResourceLimit, ..])
prepare_counter_labels! = |index, acc|
	if index > max_clicks {
		Ok(acc)
	} else {
		label = Text.from("clicks: ${U64.to_str(index)}").size(18).prepare!()?
		prepare_counter_labels!(index + 1, List.append(acc, label))
	}

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, host, frame| {
	# Drive the pointer for the *next* frame from the script, then read
	# `host.mouse` exactly as any app would.
	step = pointer_for_frame(model.frame)
	Capture.set_virtual_mouse!(
		if step.clicking Capture.clicking_at(step.pos) else Capture.at(step.pos),
	)

	mouse = host.mouse.position()
	over_increment = inside(mouse, increment_button)
	over_toggle = inside(mouse, toggle_button)

	# Ordinary edge-triggered click handling. The virtual pointer produces real
	# pressed-this-frame bits, so this needs no special casing.
	pressed = host.mouse.button_pressed(Left)
	clicks = if pressed and over_increment and model.clicks < max_clicks model.clicks + 1 else model.clicks
	toggled = if pressed and over_toggle !(model.toggled) else model.toggled

	held = host.mouse.button_down(Left)
	slider =
		if held and inside_slider(mouse) {
			clamp_unit((mouse.x - slider_track.x) / slider_track.width)
		} else {
			model.slider
		}

	frame.clear!(Color.from_hex_rgb(0x121420))
	model.title.draw!(frame, { pos: { x: 60, y: 60 }, color: Color.white, align: Text.align_top_left })

	draw_button!(frame, increment_button, over_increment, held and over_increment, model.increment_label)
	draw_button!(frame, toggle_button, over_toggle, toggled, model.toggle_label)
	draw_slider!(frame, slider)

	when_counter = List.get(model.counter_labels, U64.to_u64(clicks))
	match when_counter {
		Ok(label) => label.draw!(frame, { pos: { x: 60, y: 100 }, color: Color.from_hex_rgb(0xa3be8c), align: Text.align_top_left })
		Err(_) => {}
	}

	if model.frame >= recorded_frames {
		host.exit!(0)
	}

	Ok({
		..model,
		frame: model.frame + 1,
		pointer: step.pos,
		clicking: step.clicking,
		clicks: clicks,
		toggled: toggled,
		slider: slider,
	})
}

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
	} else {
		{ pos: slider_right, clicking: Bool.False }
	}
}

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

draw_button! : Draw.Frame, { x : F32, y : F32, width : F32, height : F32 }, Bool, Bool, Text.Prepared => {}
draw_button! = |frame, box, hovered, active, label| {
	fill =
		if active {
			Color.from_hex_rgb(0x88c0d0)
		} else if hovered {
			Color.from_hex_rgb(0x4c6a92)
		} else {
			Color.from_hex_rgb(0x2b3550)
		}

	frame.rounded_rectangle!({
		x: box.x,
		y: box.y,
		width: box.width,
		height: box.height,
		radius: 10,
		segments: 8,
		style: Draw.filled_and_outlined(fill, Color.with_alpha(Color.white, 60), 2),
	})
	label.draw!(
		frame,
		{
			pos: { x: box.x + box.width / 2, y: box.y + box.height / 2 - 10 },
			color: Color.white,
			align: Text.align_top_center,
		},
	)
}

draw_slider! : Draw.Frame, F32 => {}
draw_slider! = |frame, value| {
	frame.rounded_rectangle!({
		x: slider_track.x,
		y: slider_track.y,
		width: slider_track.width,
		height: slider_track.height,
		radius: 6,
		segments: 6,
		style: Draw.filled(Color.from_hex_rgb(0x2b3550)),
	})
	frame.rounded_rectangle!({
		x: slider_track.x,
		y: slider_track.y,
		width: slider_track.width * value,
		height: slider_track.height,
		radius: 6,
		segments: 6,
		style: Draw.filled(Color.from_hex_rgb(0x88c0d0)),
	})
	frame.circle!({
		center: { x: slider_track.x + slider_track.width * value, y: slider_track.y + slider_track.height / 2 },
		radius: 11,
		style: Draw.filled_and_outlined(Color.white, Color.from_hex_rgb(0x2b3550), 2),
	})
}
