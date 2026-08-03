## Text module - fonts, text measurement, and prepared text drawing.
##
## Measurement is a hosted effect. Prepare text once when content/style changes,
## then draw the prepared value without measuring again.
import Color
import Math

Text := [].{

	## Host-owned font handle. The host unloads fonts at shutdown, so this does
	## not need a refcounted Roc allocation.
	Font : U64

	HAlign : [Left, Center, Right]

	VAlign : [Top, Middle, Bottom]

	Align : {
		horizontal : HAlign,
		vertical : VAlign,
	}

	Size : {
		width : F32,
		height : F32,
	}

	LoadFont : {
		path : Str,
		size : I32,
	}

	Raw : {
		pos : Math.Vec2,
		text : Str,
		size : F32,
		spacing : F32,
		color : Color,
		font : U64,
	}

	MeasureRaw : {
		text : Str,
		size : F32,
		spacing : F32,
		font : U64,
	}

	Placement : {
		pos : Math.Vec2,
		color : Color,
		align : Align,
	}

	Measured : {
		pos : Math.Vec2,
		text : Str,
		size : F32,
		spacing : F32,
		color : Color,
		font : Font,
		align : Align,
	}

	Builder :: {
		content : Str,
		size : F32,
		spacing : F32,
		font : Font,
	}.{
		size : Builder, F32 -> Builder
		size = |builder, value| { ..builder, size: value }

		spacing : Builder, F32 -> Builder
		spacing = |builder, value| { ..builder, spacing: value }

		font : Builder, Font -> Builder
		font = |builder, value| { ..builder, font: value }

		measure! : Builder => Size
		measure! = |builder| Text.measure!(builder)

		prepare! : Builder => Prepared
		prepare! = |builder| Text.prepare!(builder)
	}

	Prepared :: {
		content : Str,
		size : F32,
		spacing : F32,
		font : Font,
		measured : Size,
	}.{
		bounds : Prepared -> Size
		bounds = |prepared| prepared.measured

		draw! : Prepared, Placement => {}
		draw! = |prepared, placement| {
			Text.draw!({
				text: prepared,
				pos: placement.pos,
				color: placement.color,
				align: placement.align,
			})
		}
	}

	## Hosted effects - implemented by the host.
	load_font_raw! : LoadFont => U64
	measure_raw! : MeasureRaw => Size
	draw_raw! : Raw => {}

	default_font : Font
	default_font = 0

	font_handle : Font -> U64
	font_handle = |handle| handle

	default_spacing : F32
	default_spacing = 1

	from : Str -> Builder
	from = |content| {
		content,
		size: 20,
		spacing: Text.default_spacing,
		font: Text.default_font,
	}

	load_font! : LoadFont => Try(Font, [FontLoadFailed, ..])
	load_font! = |cfg| {
		handle = Text.load_font_raw!(cfg)
		if handle == 0 {
			Err(FontLoadFailed)
		} else {
			Ok(handle)
		}
	}

	measure! : Builder => Size
	measure! = |builder| {
		Text.measure_raw!({
			text: builder.content,
			size: builder.size,
			spacing: builder.spacing,
			font: Text.font_handle(builder.font),
		})
	}

	prepare! : Builder => Prepared
	prepare! = |builder| {
		content: builder.content,
		size: builder.size,
		spacing: builder.spacing,
		font: builder.font,
		measured: Text.measure!(builder),
	}

	align_top_left : Align
	align_top_left = { horizontal: Left, vertical: Top }

	align_top_center : Align
	align_top_center = { horizontal: Center, vertical: Top }

	align_top_right : Align
	align_top_right = { horizontal: Right, vertical: Top }

	align_center : Align
	align_center = { horizontal: Center, vertical: Middle }

	align_middle_left : Align
	align_middle_left = { horizontal: Left, vertical: Middle }

	align_middle_right : Align
	align_middle_right = { horizontal: Right, vertical: Middle }

	align_bottom_left : Align
	align_bottom_left = { horizontal: Left, vertical: Bottom }

	align_bottom_center : Align
	align_bottom_center = { horizontal: Center, vertical: Bottom }

	align_bottom_right : Align
	align_bottom_right = { horizontal: Right, vertical: Bottom }

	align_offset : Size, Align -> Math.Vec2
	align_offset = |size, align| {
		x = match align.horizontal {
			Left => 0
			Center => size.width * 0.5
			Right => size.width
		}

		y = match align.vertical {
			Top => 0
			Middle => size.height * 0.5
			Bottom => size.height
		}

		{ x, y }
	}

	origin_for : Math.Vec2, Size, Align -> Math.Vec2
	origin_for = |pos, size, align| {
		offset = Text.align_offset(size, align)
		{ x: pos.x - offset.x, y: pos.y - offset.y }
	}

	draw! : { text : Prepared, pos : Math.Vec2, color : Color, align : Align } => {}
	draw! = |cfg| {
		pos = Text.origin_for(cfg.pos, cfg.text.measured, cfg.align)
		Text.draw_raw!({
			pos,
			text: cfg.text.content,
			size: cfg.text.size,
			spacing: cfg.text.spacing,
			color: cfg.color,
			font: Text.font_handle(cfg.text.font),
		})
	}

	draw_measured! : Measured => {}
	draw_measured! = |cfg| {
		prepared = Text.from(cfg.text).size(cfg.size).spacing(cfg.spacing).font(cfg.font).prepare!()
		Text.draw!({ text: prepared, pos: cfg.pos, color: cfg.color, align: cfg.align })
	}
}

expect {
	builder = Text.from("Hello").size(32).spacing(2)
	builder.size == 32 and builder.spacing == 2
}

expect Text.align_offset({ width: 100, height: 40 }, Text.align_center) == { x: 50, y: 20 }
