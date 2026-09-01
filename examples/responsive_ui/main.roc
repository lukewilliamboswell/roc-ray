## Resize the window and select the Display, Audio, or Controls panel. Press M
## to suggest moving the window to another monitor and Escape to quit. Run with
## `--record-demo` to save a repeatable gallery recording.
##
## This example shows one shared layout calculation for drawing and pointer hit
## testing, resizable-window settings, and monitor information.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-31-86e69b4" }

import rr.App
import rr.Capture
import rr.Color
import rr.Draw
import rr.Devices
import rr.Math
import rr.Mouse
import rr.Text
import rr.Window

Selection := [Display, AudioSettings, Controls].{
	is_eq : _

	previous : Selection -> Selection
	previous = |selection|
		match selection {
			Display => Controls
			AudioSettings => Display
			Controls => AudioSettings
		}

	next : Selection -> Selection
	next = |selection|
		match selection {
			Display => AudioSettings
			AudioSettings => Controls
			Controls => Display
		}

	from_keyboard : Selection, Devices.Snapshot -> Selection
	from_keyboard = |selection, input|
		if input.key_pressed(KeyUp) {
			selection.previous()
		} else if input.key_pressed(KeyDown) {
			selection.next()
		} else if input.key_pressed(Key1) {
			Display
		} else if input.key_pressed(Key2) {
			AudioSettings
		} else if input.key_pressed(Key3) {
			Controls
		} else {
			selection
		}
}

UiCopy : {
	font : Text.Font,
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

## State retained between updates: the font and prepared labels, the selected
## panel and pointer position, animation time, monitor choices, and demo mode.
## Window size is intentionally omitted because `update!` and `render!` each
## receive the current size when they need it.
Model : {
	ui : Box(UiCopy),
	selection : Selection,
	mouse : Math.Vec2,
	simulation_nanos : U64,
	monitors : List(Window.Monitor),
	monitor_choice : U64,
	demo : Bool,
}

program = { init!, update!, render! }

demo_frames = 150.U64

record_demo_flag = "--record-demo"

responsive_config : List(Str) -> App.Config
responsive_config = |args| {
	base =
		App.default
			.with_title("RocRay Responsive UI")
			.with_size({ width: 960, height: 640 })
			.with_resizable(Bool.True)
			.with_min_size({ width: 480, height: 400 })
			.with_exit_key(NoExitKey)
			.with_frame_pacing(Capped(120))

	if List.contains(args, record_demo_flag) {
		base
			.with_visible(Bool.False)
			.with_output_dir("examples/gallery")
			.with_recording(
				Capture.default
					.with_path("responsive_ui.gif")
					.with_format(Gif)
					.with_fps(25)
					.with_max_frames(demo_frames)
					.with_scale(Half)
					.with_timing(FixedStep),
			)
	} else {
		base
	}
}

init! : App.Init(Model, [ResourceLimit])
init! = App.init_for_args(
	responsive_config,
	|startup| {
		font = Draw.default_font!()
		Ok({
			ui: Box.box({
				font,
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
			demo: List.contains(App.args!(startup), record_demo_flag),
		})
	},
)

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

## The shared surface palette for this screen: one dark ground, one panel
## fill, one edge, and two accents.
theme : { bg : Color.Rgba, panel : Color.Rgba, panel_high : Color.Rgba, edge : Color.Rgba, ink : Color.Rgba, muted : Color.Rgba, faint : Color.Rgba, accent : Color.Rgba, accent_soft : Color.Rgba }
theme = {
	bg: Color.from_hex_rgb(0x0e1420),
	panel: Color.from_hex_rgb(0x161f31),
	panel_high: Color.from_hex_rgb(0x1e2942),
	edge: Color.from_hex_rgb(0x25314b),
	ink: Color.from_hex_rgb(0xe6ecf5),
	muted: Color.from_hex_rgb(0x8fa0bd),
	faint: Color.from_hex_rgb(0x5c6b87),
	accent: Color.from_hex_rgb(0x4c8dff),
	accent_soft: Color.from_hex_rgb(0x21386a),
}

## A nav row in one of three states: selected, hovered, or resting. The lit
## bar down the left edge is what makes the selected row readable at a glance
## without shouting over the panel it sits in.
draw_menu_item! : Draw.Frame, Math.Rect, Text.Prepared, Bool, Bool => {}
draw_menu_item! = |frame, bounds, label, selected, hovered| {
	draw = App.effects().render(frame)
	fill = if selected theme.accent_soft else if hovered theme.panel_high else Color.from_hex_rgb(0x141d2f)
	outline = if selected theme.accent else if hovered theme.edge else Color.with_alpha(theme.edge, 140)
	draw.rounded_rectangle!({ x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height, radius: 10, segments: 8, style: Draw.filled_and_outlined(fill, outline, if selected 2 else 1) })
	if selected {
		draw.rounded_rectangle!({ x: bounds.x + 8, y: bounds.y + 10, width: 4, height: bounds.height - 20, radius: 2, segments: 4, style: Draw.filled(theme.accent) })
	}
	label.draw!(frame, { pos: { x: bounds.x + 22, y: bounds.y + bounds.height * 0.5 }, color: if selected theme.ink else theme.muted, align: (Middle, Left) })
}

draw_key! : Draw.Frame, Text.Font, F32, F32, Str => {}
draw_key! = |frame, font, x, y, label| {
	draw = App.effects().render(frame)
	draw.rounded_rectangle!({ x, y, width: 68, height: 44, radius: 8, segments: 8, style: Draw.filled_and_outlined(theme.panel_high, theme.edge, 2) })
	Text.from(label, font).size(18).draw!(frame, { pos: { x: x + 34, y: y + 22 }, color: theme.ink, align: (Middle, Center) })
}

draw_preview! : Draw.Frame, Math.Rect, Selection, UiCopy, Draw.FrameSize, Model => {}
draw_preview! = |frame, bounds, selection, ui, screen, model| {
	draw = App.effects().render(frame)
	simulation_nanos = model.simulation_nanos
	draw.rectangle_gradient_v!({ x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height, color_top: Color.from_hex_rgb(0x182540), color_bottom: Color.from_hex_rgb(0x0f1728) })

	body = match selection {
		Display => ui.display_body
		AudioSettings => ui.audio_body
		Controls => ui.controls_body
	}
	# The preview reads as a card of its own, not as a hole in the background.
	draw.rectangle!({ x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height, style: Draw.outlined(theme.edge, 2) })
	body.draw!(frame, { pos: { x: bounds.x + 28, y: bounds.y + 28 }, color: theme.ink })

	match selection {
		Display => {
			size_text = Str.concat(I32.to_str(F32.to_i32_wrap(screen.width)), Str.concat(" x ", I32.to_str(F32.to_i32_wrap(screen.height))))
			draw.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 72 }, text: size_text, size: 20, color: theme.accent })
			# Asked for here rather than remembered: the scale belongs to the
			# surface being drawn to, and reading it mid-frame is free.
			scale = Window.scale!()
			draw.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 98 }, text: framebuffer_line(screen, scale), size: 16, color: theme.muted })
			draw.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 122 }, text: monitor_line(model.monitors, model.monitor_choice), size: 16, color: theme.muted })
			phase = U64.to_f32(simulation_nanos % 3_000_000_000) / 3_000_000_000
			preview_x = bounds.x + bounds.width * phase
			draw.circle_gradient!({ center: { x: preview_x, y: bounds.y + bounds.height * 0.62 }, radius: 105, color_inner: Color.with_alpha(theme.accent, 110), color_outer: Color.with_alpha(theme.accent, 0) })
			draw.rounded_rectangle!({ x: bounds.x + 28, y: bounds.y + 152, width: bounds.width - 56, height: 78, radius: 12, segments: 8, style: Draw.outlined(Color.with_alpha(theme.muted, 90), 2) })
		}
		AudioSettings => {
			draw.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 74 }, text: "Music", size: 18, color: theme.muted })
			draw.rectangle!({ x: bounds.x + 28, y: bounds.y + 106, width: bounds.width - 90, height: 14, style: Draw.filled(theme.panel_high) })
			draw.rectangle!({ x: bounds.x + 28, y: bounds.y + 106, width: (bounds.width - 90) * 0.72, height: 14, style: Draw.filled(Color.from_hex_rgb(0x43aa8b)) })
			draw.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 154 }, text: "Effects", size: 18, color: theme.muted })
			draw.rectangle!({ x: bounds.x + 28, y: bounds.y + 186, width: bounds.width - 90, height: 14, style: Draw.filled(theme.panel_high) })
			draw.rectangle!({ x: bounds.x + 28, y: bounds.y + 186, width: (bounds.width - 90) * 0.9, height: 14, style: Draw.filled(Color.from_hex_rgb(0xf9c74f)) })
		}
		Controls => {
			draw.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 76 }, text: "Move", size: 18, color: theme.muted })
			draw_key!(frame, ui.font, bounds.x + 28, bounds.y + 112, "WASD")
			draw.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 182 }, text: "Command", size: 18, color: theme.muted })
			draw_key!(frame, ui.font, bounds.x + 28, bounds.y + 218, "SPACE")
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
Layout := {
	margin : F32,
	screen_h : F32,
	nav : Math.Rect,
	preview : Math.Rect,
	display_bounds : Math.Rect,
	audio_bounds : Math.Rect,
	controls_bounds : Math.Rect,
}.{
	from_size : { width : F32, height : F32 } -> Layout
	from_size = |screen| {
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
}

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices

	# Layout follows the window, pointing follows the mouse, and the preview
	# animates on the clock -- three separate observations off one input.
	view = Layout.from_size({ width: I32.to_f32(program_input.window.size.width), height: I32.to_f32(program_input.window.size.height) })
	mouse = input.mouse.position()
	hover_display = view.display_bounds.contains(mouse)
	hover_audio = view.audio_bounds.contains(mouse)
	hover_controls = view.controls_bounds.contains(mouse)
	Mouse.set_cursor!(if hover_display or hover_audio or hover_controls PointingHand else Arrow)

	cycle = program_input.time.cycle_count
	selection_input =
		if model.demo and cycle == 38 Devices.none.with_key_pressed(KeyDown)
		else if model.demo and cycle == 78 Devices.none.with_key_pressed(KeyDown)
		else if model.demo and cycle == 118 Devices.none.with_key_pressed(KeyUp)
		else input
	from_keyboard = model.selection.from_keyboard(selection_input)
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
	if model.demo {
		match program_input.capture {
			Finished(_) => Err(Exit(0))
			Failed(_) => Err(Exit(1))
			_ => Ok({ ..model, selection, mouse, simulation_nanos: program_input.time.simulation_nanos, monitors: display.monitors, monitor_choice: display.choice })
		}
	} else if input.key_pressed(KeyQ) {
		Err(Exit(0))
	} else {
		Ok({ ..model, selection, mouse, simulation_nanos: program_input.time.simulation_nanos, monitors: display.monitors, monitor_choice: display.choice })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
render! = |model, frame| {
	draw = App.effects().render(frame)
	ui = Box.unbox(model.ui)
	# The surface being drawn to, asked for where it is used. A resize is
	# visible here on the cycle it happens, without a copy in the model that
	# could be a frame behind it.
	screen = frame.size!()
	view = Layout.from_size(screen)
	hover_display = view.display_bounds.contains(model.mouse)
	hover_audio = view.audio_bounds.contains(model.mouse)
	hover_controls = view.controls_bounds.contains(model.mouse)

	frame.clear!(theme.bg)
	ui.title.draw!(frame, { pos: { x: view.margin, y: 24 }, color: theme.ink })
	ui.subtitle.draw!(frame, { pos: { x: view.margin, y: 70 }, color: theme.muted })
	# A hairline under the header, drawn to the live width so it follows a resize.
	draw.rectangle!({ x: view.margin, y: 96, width: screen.width - view.margin * 2, height: 1, style: Draw.filled(theme.edge) })
	draw.rounded_rectangle!({ x: view.nav.x, y: view.nav.y, width: view.nav.width, height: view.nav.height, radius: 14, segments: 8, style: Draw.filled_and_outlined(theme.panel, theme.edge, 1) })
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
	ui.help.draw!(frame, { pos: { x: view.margin, y: view.screen_h - 24 }, color: theme.faint, align: (Bottom, Left) })

	Ok({})
}

## Selection wraps in both directions, so an arrow key never dead-ends.
expect {
	selection : Selection
	selection = Display
	selection.previous() == Controls
}

expect {
	selection : Selection
	selection = Controls
	selection.next() == Display
}

expect {
	selection : Selection
	selection = Display
	selection.from_keyboard(Devices.none.with_key_pressed(Key3)) == Controls
}

expect {
	selection : Selection
	selection = Display
	selection.from_keyboard(Devices.none) == Display
}

## The wide layout puts the preview beside the nav; the narrow one stacks it
## below. This is the only thing the 700px breakpoint does.
expect {
	wide = Layout.from_size({ width: 960, height: 640 })
	wide.preview.x > wide.nav.x + wide.nav.width
}

expect {
	narrow = Layout.from_size({ width: 480, height: 640 })
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
	view = Layout.from_size({ width: 360, height: 360 })
	view.display_bounds.x >= view.nav.x and view.controls_bounds.x + view.controls_bounds.width <= view.nav.x + view.nav.width
}
