app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Color
import rr.Draw
import rr.Devices
import rr.Math
import rr.Mouse
import rr.Text

## A settings screen that rearranges itself as the window resizes.
##
## `layout_for` is a pure function of the surface size, and both callbacks call
## it: `update!` to decide what the pointer is over, `render!` to draw. Nothing
## about the geometry is stored, so the two can never disagree. The window is
## resizable with a minimum size, and `with_exit_key(NoExitKey)` frees Escape
## for the UI so the app owns shutdown itself.
Selection := [Display, AudioSettings, Controls].{
	is_eq : _
}

UiCopy : {
	title : Text.Prepared,
	subtitle : Text.Prepared,
	display : Text.Prepared,
	audio : Text.Prepared,
	controls : Text.Prepared,
	display_body : Text.Prepared,
	audio_body : Text.Prepared,
	controls_body : Text.Prepared,
	help : Text.Prepared,
}

## The window size is deliberately absent. `update` needs it to decide what the
## pointer is over, and reads it off the input; `render!` needs it to draw the
## same layout, and asks the frame. Neither reason is a reason to remember it.
Model : {
	ui : Box(UiCopy),
	selection : Selection,
	mouse : Math.Vec2,
	simulation_nanos : U64,
}

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("RocRay Responsive UI")
		.with_size({ width: 960, height: 640 })
		.with_resizable(Bool.True)
	# The layout stops being usable below this, so keep the window manager
	# out of that range. A minimum only binds on a resizable window.
		.with_min_size({ width: 480, height: 400 })
	# Escape is an ordinary key on a settings screen, so take it back from
	# raylib and own shutdown ourselves.
		.with_exit_key(NoExitKey)
		.with_frame_pacing(Capped(120)),
	|_startup| {
		font = Draw.default_font!()
		Ok({
			ui: Box.box({
				title: Text.from("Settings", font).size(38).prepare!()?,
				subtitle: Text.from("A resizable, input-aware application screen", font).size(18).prepare!()?,
				display: Text.from("Display", font).size(22).prepare!()?,
				audio: Text.from("Audio", font).size(22).prepare!()?,
				controls: Text.from("Controls", font).size(22).prepare!()?,
				display_body: Text.from("Live layout preview", font).size(24).prepare!()?,
				audio_body: Text.from("Mix groups", font).size(24).prepare!()?,
				controls_body: Text.from("Keyboard bindings", font).size(24).prepare!()?,
				help: Text.from("Arrow keys or click to select | ESC does nothing | Q quits", font).size(16).prepare!()?,
			}),
			selection: Display,
			mouse: { x: 0, y: 0 },
			simulation_nanos: 0,
		})
	},
)

previous_selection : Selection -> Selection
previous_selection = |selection|
	match selection {
		Display => Controls
		AudioSettings => Display
		Controls => AudioSettings
	}

next_selection : Selection -> Selection
next_selection = |selection|
	match selection {
		Display => AudioSettings
		AudioSettings => Controls
		Controls => Display
	}

keyboard_selection : Selection, Devices.Snapshot -> Selection
keyboard_selection = |selection, input|
	if input.key_pressed(KeyUp) {
		previous_selection(selection)
	} else if input.key_pressed(KeyDown) {
		next_selection(selection)
	} else if input.key_pressed(Key1) {
		Display
	} else if input.key_pressed(Key2) {
		AudioSettings
	} else if input.key_pressed(Key3) {
		Controls
	} else {
		selection
	}

draw_menu_item! : Draw.Frame, Math.Rect, Text.Prepared, Bool, Bool => {}
draw_menu_item! = |frame, bounds, label, selected, hovered| {
	fill = if selected Color.from_hex_rgb(0x2f6fed) else if hovered Color.from_hex_rgb(0x25314a) else Color.from_hex_rgb(0x192238)
	outline = if selected Color.from_hex_rgb(0x8fb4ff) else Color.with_alpha(Color.white, 24)
	frame.rounded_rectangle!({ x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height, radius: 10, segments: 8, style: Draw.filled_and_outlined(fill, outline, 2) })
	label.draw!(frame, { pos: { x: bounds.x + 18, y: bounds.y + bounds.height * 0.5 }, color: Color.white, align: Text.align_middle_left })
}

draw_key! : Draw.Frame, F32, F32, Str => {}
draw_key! = |frame, x, y, label| {
	frame.rounded_rectangle!({ x, y, width: 68, height: 44, radius: 8, segments: 8, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x202b43), Color.from_hex_rgb(0x7083a8), 2) })
	frame.text_centered!({ pos: { x: x + 34, y: y + 22 }, text: label, size: 18, color: Color.white })
}

draw_preview! : Draw.Frame, Math.Rect, Selection, UiCopy, Draw.FrameSize, U64 => {}
draw_preview! = |frame, bounds, selection, ui, screen, simulation_nanos| {
	frame.rectangle_gradient_v!({ x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height, color_top: Color.from_hex_rgb(0x15213a), color_bottom: Color.from_hex_rgb(0x0d1425) })

	body = match selection {
		Display => ui.display_body
		AudioSettings => ui.audio_body
		Controls => ui.controls_body
	}
	body.draw!(frame, { pos: { x: bounds.x + 28, y: bounds.y + 28 }, color: Color.white, align: Text.align_top_left })

	match selection {
		Display => {
			size_text = Str.concat(I32.to_str(F32.to_i32_wrap(screen.width)), Str.concat(" x ", I32.to_str(F32.to_i32_wrap(screen.height))))
			frame.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 72 }, text: size_text, size: 20, color: Color.from_hex_rgb(0x8fb4ff) })
			phase = U64.to_f32(simulation_nanos % 3_000_000_000) / 3_000_000_000
			preview_x = bounds.x + bounds.width * phase
			frame.circle_gradient!({ center: { x: preview_x, y: bounds.y + bounds.height * 0.62 }, radius: 105, color_inner: Color.with_alpha(Color.from_hex_rgb(0x2f6fed), 150), color_outer: Color.with_alpha(Color.from_hex_rgb(0x2f6fed), 0) })
			frame.rounded_rectangle!({ x: bounds.x + 28, y: bounds.y + 118, width: bounds.width - 56, height: 112, radius: 12, segments: 8, style: Draw.outlined(Color.with_alpha(Color.white, 70), 2) })
		}
		AudioSettings => {
			frame.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 74 }, text: "Music", size: 18, color: Color.light_gray })
			frame.rectangle!({ x: bounds.x + 28, y: bounds.y + 106, width: bounds.width - 90, height: 14, style: Draw.filled(Color.from_hex_rgb(0x27334c)) })
			frame.rectangle!({ x: bounds.x + 28, y: bounds.y + 106, width: (bounds.width - 90) * 0.72, height: 14, style: Draw.filled(Color.from_hex_rgb(0x43aa8b)) })
			frame.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 154 }, text: "Effects", size: 18, color: Color.light_gray })
			frame.rectangle!({ x: bounds.x + 28, y: bounds.y + 186, width: bounds.width - 90, height: 14, style: Draw.filled(Color.from_hex_rgb(0x27334c)) })
			frame.rectangle!({ x: bounds.x + 28, y: bounds.y + 186, width: (bounds.width - 90) * 0.9, height: 14, style: Draw.filled(Color.from_hex_rgb(0xf9c74f)) })
		}
		Controls => {
			frame.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 76 }, text: "Move", size: 18, color: Color.light_gray })
			draw_key!(frame, bounds.x + 28, bounds.y + 112, "WASD")
			frame.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 182 }, text: "Command", size: 18, color: Color.light_gray })
			draw_key!(frame, bounds.x + 28, bounds.y + 218, "SPACE")
		}
	}
}

## Layout is a pure function of the surface size, so `update` (deciding what the
## pointer is over) and `render!` (drawing it) derive the same value rather than
## storing it -- one less thing that can disagree with itself.
##
## `update!` gets the size from the input's window, because which arrangement to
## use is application logic. `render!` gets it from `frame.size!()`, because by
## then it is a property of what is being drawn to.
Layout : {
	margin : F32,
	screen_h : F32,
	nav : Math.Rect,
	preview : Math.Rect,
	display_bounds : Math.Rect,
	audio_bounds : Math.Rect,
	controls_bounds : Math.Rect,
}

layout_for : { width : F32, height : F32 } -> Layout
layout_for = |screen| {
	screen_w = F32.max(screen.width, 360)
	screen_h = F32.max(screen.height, 360)
	compact = screen_w < 700
	margin = if compact 16 else 30
	content_top = 104
	content_w = screen_w - margin * 2
	content_h = F32.max(screen_h - content_top - 52, 220)

	nav = if compact Math.rect(margin, content_top, content_w, 176) else Math.rect(margin, content_top, 240, content_h)
	preview = if compact Math.rect(margin, content_top + 192, content_w, F32.max(content_h - 192, 120)) else Math.rect(margin + 256, content_top, content_w - 256, content_h)
	item_w = nav.width - 24

	{
		margin,
		screen_h,
		nav,
		preview,
		display_bounds: Math.rect(nav.x + 12, nav.y + 14, item_w, 46),
		audio_bounds: Math.rect(nav.x + 12, nav.y + 66, item_w, 46),
		controls_bounds: Math.rect(nav.x + 12, nav.y + 118, item_w, 46),
	}
}

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices

	# Layout follows the window, pointing follows the mouse, and the preview
	# animates on the clock -- three separate observations off one input.
	view = layout_for({ width: I32.to_f32(program_input.window.size.width), height: I32.to_f32(program_input.window.size.height) })
	mouse = input.mouse.position()
	hover_display = view.display_bounds.contains(mouse)
	hover_audio = view.audio_bounds.contains(mouse)
	hover_controls = view.controls_bounds.contains(mouse)
	Mouse.set_cursor!(if hover_display or hover_audio or hover_controls PointingHand else Arrow)

	from_keyboard = keyboard_selection(model.selection, input)
	selection = if input.mouse.button_pressed(Left) and hover_display {
		Display
	} else if input.mouse.button_pressed(Left) and hover_audio {
		AudioSettings
	} else if input.mouse.button_pressed(Left) and hover_controls {
		Controls
	} else {
		from_keyboard
	}

	# With `with_exit_key(NoExitKey)` no key closes the window on its
	# own, so the app decides. Escape is left free for the UI to use.
	if input.key_pressed(KeyQ) {
		Err(Exit(0))
	} else {
		Ok({ ..model, selection, mouse, simulation_nanos: program_input.time.simulation_nanos })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
render! = |model, frame| {
	ui = Box.unbox(model.ui)
	# The surface being drawn to, asked for where it is used. A resize is
	# visible here on the cycle it happens, without a copy in the model that
	# could be a frame behind it.
	screen = frame.size!()
	view = layout_for(screen)
	hover_display = view.display_bounds.contains(model.mouse)
	hover_audio = view.audio_bounds.contains(model.mouse)
	hover_controls = view.controls_bounds.contains(model.mouse)

	frame.clear!(Color.from_hex_rgb(0x090f1c))
	ui.title.draw!(frame, { pos: { x: view.margin, y: 24 }, color: Color.white, align: Text.align_top_left })
	ui.subtitle.draw!(frame, { pos: { x: view.margin, y: 70 }, color: Color.from_hex_rgb(0x91a0bd), align: Text.align_top_left })
	frame.rounded_rectangle!({ x: view.nav.x, y: view.nav.y, width: view.nav.width, height: view.nav.height, radius: 14, segments: 8, style: Draw.filled(Color.from_hex_rgb(0x111a2b)) })
	draw_menu_item!(frame, view.display_bounds, ui.display, model.selection == Display, hover_display)
	draw_menu_item!(frame, view.audio_bounds, ui.audio, model.selection == AudioSettings, hover_audio)
	draw_menu_item!(frame, view.controls_bounds, ui.controls, model.selection == Controls, hover_controls)
	frame.with_scissor!(
		view.preview,
		|clipped_frame| {
			draw_preview!(clipped_frame, view.preview, model.selection, ui, screen, model.simulation_nanos)
			Ok({})
		},
	)?
	ui.help.draw!(frame, { pos: { x: view.margin, y: view.screen_h - 24 }, color: Color.from_hex_rgb(0x91a0bd), align: Text.align_bottom_left })

	Ok({})
}

## Selection wraps in both directions, so an arrow key never dead-ends.
expect previous_selection(Display) == Controls
expect next_selection(Controls) == Display
expect keyboard_selection(Display, Devices.none.with_key_pressed(Key3)) == Controls
expect keyboard_selection(Display, Devices.none) == Display

## The wide layout puts the preview beside the nav; the narrow one stacks it
## below. This is the only thing the 700px breakpoint does.
expect {
	wide = layout_for({ width: 960, height: 640 })
	wide.preview.x > wide.nav.x + wide.nav.width
}

expect {
	narrow = layout_for({ width: 480, height: 640 })
	narrow.preview.y > narrow.nav.y + narrow.nav.height
}

## Every nav item stays inside the nav panel at either size, which is what
## makes hit-testing against the same layout `render!` draws safe.
expect {
	view = layout_for({ width: 360, height: 360 })
	view.display_bounds.x >= view.nav.x and view.controls_bounds.x + view.controls_bounds.width <= view.nav.x + view.nav.width
}
