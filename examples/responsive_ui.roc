app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Color
import rr.Draw
import rr.Host
import rr.Math
import rr.Mouse
import rr.Text

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

Model : {
	ui : Box(UiCopy),
	selection : Selection,
}

program = { init!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("RocRay Responsive UI")
		.with_size({ width: 960, height: 640 })
		.with_resizable(Bool.True)
		.with_frame_pacing(Capped(120)),
	|_host|
		Ok({
			ui: Box.box({
				title: Text.from("Settings").size(38).prepare!()?,
				subtitle: Text.from("A resizable, input-aware application screen").size(18).prepare!()?,
				display: Text.from("Display").size(22).prepare!()?,
				audio: Text.from("Audio").size(22).prepare!()?,
				controls: Text.from("Controls").size(22).prepare!()?,
				display_body: Text.from("Live layout preview").size(24).prepare!()?,
				audio_body: Text.from("Mix groups").size(24).prepare!()?,
				controls_body: Text.from("Keyboard bindings").size(24).prepare!()?,
				help: Text.from("Arrow keys or click to select | ESC exits").size(16).prepare!()?,
			}),
			selection: Display,
		}),
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

keyboard_selection : Selection, Host -> Selection
keyboard_selection = |selection, host|
	if host.key_pressed(KeyUp) {
		previous_selection(selection)
	} else if host.key_pressed(KeyDown) {
		next_selection(selection)
	} else if host.key_pressed(Key1) {
		Display
	} else if host.key_pressed(Key2) {
		AudioSettings
	} else if host.key_pressed(Key3) {
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

draw_preview! : Draw.Frame, Math.Rect, Selection, UiCopy, I32, I32, U64 => {}
draw_preview! = |frame, bounds, selection, ui, screen_width, screen_height, timestamp_nanos| {
	frame.rectangle_gradient_v!({ x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height, color_top: Color.from_hex_rgb(0x15213a), color_bottom: Color.from_hex_rgb(0x0d1425) })

	body = match selection {
		Display => ui.display_body
		AudioSettings => ui.audio_body
		Controls => ui.controls_body
	}
	body.draw!(frame, { pos: { x: bounds.x + 28, y: bounds.y + 28 }, color: Color.white, align: Text.align_top_left })

	match selection {
		Display => {
			size_text = Str.concat(I32.to_str(screen_width), Str.concat(" x ", I32.to_str(screen_height)))
			frame.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 72 }, text: size_text, size: 20, color: Color.from_hex_rgb(0x8fb4ff) })
			phase = U64.to_f32(timestamp_nanos % 3_000_000_000) / 3_000_000_000
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
			frame.text_at!({ pos: { x: bounds.x + 28, y: bounds.y + 182 }, text: "Action", size: 18, color: Color.light_gray })
			draw_key!(frame, bounds.x + 28, bounds.y + 218, "SPACE")
		}
	}
}

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ScopeLimit, ..])
render! = |model, host, frame| {
	if host.key_pressed(KeyEscape) {
		host.exit!(0)
	}

	ui = Box.unbox(model.ui)
	screen_w = F32.max(I32.to_f32(host.screen.width), 360)
	screen_h = F32.max(I32.to_f32(host.screen.height), 360)
	compact = screen_w < 700
	margin = if compact 16 else 30
	content_top = 104
	content_w = screen_w - margin * 2
	content_h = F32.max(screen_h - content_top - 52, 220)

	nav = if compact Math.rect(margin, content_top, content_w, 176) else Math.rect(margin, content_top, 240, content_h)
	preview = if compact Math.rect(margin, content_top + 192, content_w, F32.max(content_h - 192, 120)) else Math.rect(margin + 256, content_top, content_w - 256, content_h)
	item_w = nav.width - 24
	display_bounds = Math.rect(nav.x + 12, nav.y + 14, item_w, 46)
	audio_bounds = Math.rect(nav.x + 12, nav.y + 66, item_w, 46)
	controls_bounds = Math.rect(nav.x + 12, nav.y + 118, item_w, 46)

	mouse = host.mouse.position()
	hover_display = display_bounds.contains(mouse)
	hover_audio = audio_bounds.contains(mouse)
	hover_controls = controls_bounds.contains(mouse)
	hovered = hover_display or hover_audio or hover_controls
	host.set_cursor!(if hovered PointingHand else Arrow)

	from_keyboard = keyboard_selection(model.selection, host)
	selection = if host.mouse.button_pressed(Left) and hover_display {
		Display
	} else if host.mouse.button_pressed(Left) and hover_audio {
		AudioSettings
	} else if host.mouse.button_pressed(Left) and hover_controls {
		Controls
	} else {
		from_keyboard
	}

	frame.clear!(Color.from_hex_rgb(0x090f1c))
	ui.title.draw!(frame, { pos: { x: margin, y: 24 }, color: Color.white, align: Text.align_top_left })
	ui.subtitle.draw!(frame, { pos: { x: margin, y: 70 }, color: Color.from_hex_rgb(0x91a0bd), align: Text.align_top_left })
	frame.rounded_rectangle!({ x: nav.x, y: nav.y, width: nav.width, height: nav.height, radius: 14, segments: 8, style: Draw.filled(Color.from_hex_rgb(0x111a2b)) })
	draw_menu_item!(frame, display_bounds, ui.display, selection == Display, hover_display)
	draw_menu_item!(frame, audio_bounds, ui.audio, selection == AudioSettings, hover_audio)
	draw_menu_item!(frame, controls_bounds, ui.controls, selection == Controls, hover_controls)
	frame.with_scissor!(
		preview,
		|clipped_frame| {
			draw_preview!(clipped_frame, preview, selection, ui, host.screen.width, host.screen.height, host.timestamp_nanos)
			Ok({})
		},
	)?
	ui.help.draw!(frame, { pos: { x: margin, y: screen_h - 24 }, color: Color.from_hex_rgb(0x91a0bd), align: Text.align_bottom_left })

	Ok({ ..model, selection })
}
