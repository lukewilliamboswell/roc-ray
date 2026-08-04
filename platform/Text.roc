## Text module - fonts, text measurement, and prepared text drawing.
##
## Measurement is a hosted effect. Prepare text once when content/style changes,
## then draw the prepared value without measuring again.
import Color
import Draw
import DrawHost
import Math

Text := [].{

	## Draw owns the host resource lifecycle; prepared text retains loaded fonts
	## through the same ARC value as all other drawing APIs.
	Font : Draw.Font

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
		measure! = |builder| Text.measure_builder!(builder)

		prepare! : Builder => Prepared
		prepare! = |builder| Text.prepare_builder!(builder)
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

		draw! : Prepared, Draw.Frame, Placement => {}
		draw! = |prepared, frame, placement| {
			Text.draw_prepared!(
				frame,
				{
					text: prepared,
					pos: placement.pos,
					color: placement.color,
					align: placement.align,
				},
			)
		}
	}

	default_font : Font
	default_font = Draw.default_font

	default_spacing : F32
	default_spacing = Draw.default_spacing

	from : Str -> Builder
	from = |content| {
		content,
		size: 20,
		spacing: Text.default_spacing,
		font: Text.default_font,
	}

	load_font! : LoadFont => Try(Font, [FontLoadFailed, ResourceLimit, ..])
	load_font! = |cfg| Draw.load_font!(cfg)

	measure_builder! : Builder => Size
	measure_builder! = |builder| {
		Draw.measure_text!({
			text: builder.content,
			size: builder.size,
			spacing: builder.spacing,
			font: builder.font,
		})
	}

	prepare_builder! : Builder => Prepared
	prepare_builder! = |builder| {
		content: builder.content,
		size: builder.size,
		spacing: builder.spacing,
		font: builder.font,
		measured: Text.measure_builder!(builder),
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

	draw_prepared! : Draw.Frame, { text : Prepared, pos : Math.Vec2, color : Color, align : Align } => {}
	draw_prepared! = |_frame, cfg| {
		pos = Text.origin_for(cfg.pos, cfg.text.measured, cfg.align)
		DrawHost.text!({
			pos,
			text: cfg.text.content,
			size: cfg.text.size,
			spacing: cfg.text.spacing,
			color: cfg.color,
			font: cfg.text.font,
		})
	}

	draw_measured! : Draw.Frame, Measured => {}
	draw_measured! = |frame, cfg| {
		prepared = Text.from(cfg.text).size(cfg.size).spacing(cfg.spacing).font(cfg.font).prepare!()
		Text.draw_prepared!(frame, { text: prepared, pos: cfg.pos, color: cfg.color, align: cfg.align })
	}
}

expect {
	builder = Text.from("Hello").size(32).spacing(2)
	builder.size == 32 and builder.spacing == 2
}

expect Text.align_offset({ width: 100, height: 40 }, Text.align_center) == { x: 50, y: 20 }
