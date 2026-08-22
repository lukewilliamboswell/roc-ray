app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Color
import rr.Draw
import rr.Devices
import rr.Math
import rr.Mouse
import rr.Text
import rr.Window

## A settings screen that rearranges itself as the window resizes.
##
## `layout_for` is a pure function of the surface size, and both callbacks call
## it: `update!` to decide what the pointer is over, `render!` to draw. Nothing
## about the geometry is stored, so the two can never disagree. The window is
## resizable with a minimum size, and `with_exit_key(NoExitKey)` frees Escape
## for the UI so the app owns shutdown itself.
##
## The Display panel is where the window looks at the display it is on. It
## reads `Window.scale!` while drawing -- a factor the backend already holds,
## so it costs nothing mid-frame -- to report the framebuffer resolution behind
## the logical size, and `M` walks the window across the monitors
## `Window.monitors!` found.
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

## The window size is deliberately absent. `update!` needs it to decide what the
## pointer is over, and reads it off the input; `render!` needs it to draw the
## same layout, and asks the frame. Neither reason is a reason to remember it.
## The monitor list is remembered because it is not free to ask for: it
## allocates a name per display. It is re-read whenever the app acts on it, so
## a display plugged in mid-run still shows up.
Model : {
	ui : Box(UiCopy),
	selection : Selection,
	mouse : Math.Vec2,
	simulation_nanos : U64,
	monitors : List(Window.Monitor),
	monitor_choice : U64,
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
				help: Text.from("Arrow keys or click to select | M moves display | ESC does nothing | Q quits", font).size(16).prepare!()?,
			}),
			selection: Display,
			mouse: { x: 0, y: 0 },
			simulation_nanos: 0,
			monitors: Window.monitors!(),
			monitor_choice: 0,
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

## Walk the window on to the next display, re-reading the monitor list first so
## the move is decided from what is connected now rather than from what was
## connected at startup.
##
## `Window.suggest_monitor!` is a suggestion: the window manager decides where
## the window ends up, and an index that has just gone away is ignored.
next_monitor! : Model => { monitors : List(Window.Monitor), choice : U64 }
next_monitor! = |model| {
	monitors = Window.monitors!()
	count = List.len(monitors)
	if count == 0 {
		{ monitors, choice: 0 }
	} else {
		choice = (model.monitor_choice + 1) % count
		match List.get(monitors, choice) {
			Ok(monitor) => Window.suggest_monitor!(monitor.index)
			Err(_) => {}
		}
		{ monitors, choice }
	}
}

## How the Display panel names the monitor the window was last sent to.
monitor_line : List(Window.Monitor), U64 -> Str
monitor_line = |monitors, choice|
	match List.get(monitors, choice) {
		Ok(monitor) =>
			Str.join_with(
				[
					monitor.name,
					Str.join_with([I32.to_str(monitor.size.width), I32.to_str(monitor.size.height)], " x "),
					Str.concat(I32.to_str(monitor.refresh_hz), " Hz"),
				],
				"  |  ",
			)

		Err(_) => "No monitor reported"
	}

## The framebuffer the logical size is drawn into, which is the resolution a
## `Capture` of this window records at.
framebuffer_line : Draw.FrameSize, { x : F32, y : F32 } -> Str
framebuffer_line = |screen, scale|
	Str.concat(
		Str.join_with(
			[
				I32.to_str(F32.to_i32_wrap(screen.width * scale.x)),
				I32.to_str(F32.to_i32_wrap(screen.height * scale.y)),
			],
			" x ",
		),
		" framebuffer pixels",
	)

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

draw_preview! : Draw.Frame, Math.Rect, Selection, UiCopy, Draw.FrameSize, Model => {}
draw_preview! = |frame, bounds, selection, ui, screen, model| {
	simulation_nanos = model.simulation_nanos
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
			# Asked for here rather than remembered: the scale belongs to the
			# surface being drawn to, and reading it mid-frame is free.
			scale = Window.scale!()
			frame.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 98 }, text: framebuffer_line(screen, scale), size: 16, color: Color.from_hex_rgb(0x91a0bd) })
			frame.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 122 }, text: monitor_line(model.monitors, model.monitor_choice), size: 16, color: Color.from_hex_rgb(0x91a0bd) })
			phase = U64.to_f32(simulation_nanos % 3_000_000_000) / 3_000_000_000
			preview_x = bounds.x + bounds.width * phase
			frame.circle_gradient!({ center: { x: preview_x, y: bounds.y + bounds.height * 0.62 }, radius: 105, color_inner: Color.with_alpha(Color.from_hex_rgb(0x2f6fed), 150), color_outer: Color.with_alpha(Color.from_hex_rgb(0x2f6fed), 0) })
			frame.rounded_rectangle!({ x: bounds.x + 28, y: bounds.y + 152, width: bounds.width - 56, height: 78, radius: 12, segments: 8, style: Draw.outlined(Color.with_alpha(Color.white, 70), 2) })
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

## Layout is a pure function of the surface size, so `update!` (deciding what the
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

	# Enumerating displays allocates, so it happens on the keypress that acts
	# on the answer rather than every cycle.
	display = if input.key_pressed(KeyM) next_monitor!(model) else { monitors: model.monitors, choice: model.monitor_choice }

	# With `with_exit_key(NoExitKey)` no key closes the window on its
	# own, so the app decides. Escape is left free for the UI to use.
	if input.key_pressed(KeyQ) {
		Err(Exit(0))
	} else {
		Ok({ ..model, selection, mouse, simulation_nanos: program_input.time.simulation_nanos, monitors: display.monitors, monitor_choice: display.choice })
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
			draw_preview!(clipped_frame, view.preview, model.selection, ui, screen, model)
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

## A doubled HiDPI display records twice the logical size, which is the whole
## reason `Window.scale!` is worth reading before exporting anything.
expect framebuffer_line({ width: 960, height: 640 }, { x: 1, y: 1 }) == "960 x 640 framebuffer pixels"
expect framebuffer_line({ width: 960, height: 640 }, { x: 2, y: 2 }) == "1920 x 1280 framebuffer pixels"

## A monitor list can be empty on a backend that reports none, and the choice
## can outlive the display it pointed at, so neither may be assumed present.
expect monitor_line([], 0) == "No monitor reported"
expect monitor_line([{ index: 0, name: "Headless", size: { width: 800, height: 600 }, position: { x: 0, y: 0 }, refresh_hz: 60 }], 1) == "No monitor reported"
expect monitor_line([{ index: 0, name: "Headless", size: { width: 800, height: 600 }, position: { x: 0, y: 0 }, refresh_hz: 60 }], 0) == "Headless  |  800 x 600  |  60 Hz"

## Every nav item stays inside the nav panel at either size, which is what
## makes hit-testing against the same layout `render!` draws safe.
expect {
	view = layout_for({ width: 360, height: 360 })
	view.display_bounds.x >= view.nav.x and view.controls_bounds.x + view.controls_bounds.width <= view.nav.x + view.nav.width
}
