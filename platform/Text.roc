## Text module - fonts, text measurement, and prepared text drawing.
##
## `Draw.Font` enables pure layout measurement. Prepare text when rendering
## needs host-owned cached bytes and bounds.
import Color
import Draw
import DrawHost
import Math
import rrt.Font as RrtFont

Text := [].{

	HAlign : [Left, Center, Right]

	VAlign : [Top, Middle, Bottom]

	Align : {
		horizontal : HAlign,
		vertical : VAlign,
	}

	Size : RrtFont.Size

	Placement : {
		pos : Math.Vec2,
		color : Color.Rgba,
		align : Align,
	}

	Builder :: {
		content : Str,
		size : F32,
		spacing : F32,
		font : Draw.Font,
	}.{
		size : Builder, F32 -> Builder
		size = |builder, value| { ..builder, size: value }

		spacing : Builder, F32 -> Builder
		spacing = |builder, value| { ..builder, spacing: value }

		font : Builder, Draw.Font -> Builder
		font = |builder, value| { ..builder, font: value }

		## Cache immutable UTF-8 text, font/style, and measurement in the host.
		prepare! : Builder => Try(Prepared, [ResourceLimit, ..])
		prepare! = |builder| Text.prepare_builder!(builder)
	}

	## Host-owned immutable text. Its ARC handle retains any loaded font and its
	## cached native NUL-terminated bytes are reused by every draw.
	Prepared :: {
		resource : DrawHost.PreparedText,
		measured : Size,
	}.{
		bounds : Prepared -> Size
		bounds = |Prepared.(prepared)| prepared.measured

		draw! : Prepared, Draw.Frame, Placement => {}
		draw! = |prepared, frame, placement|
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

	default_spacing : F32
	default_spacing = Draw.default_spacing

	from : Str, Draw.Font -> Builder
	from = |content, font| {
		content,
		size: 20,
		spacing: Text.default_spacing,
		font,
	}

	prepare_builder! : Builder => Try(Prepared, [ResourceLimit, ..])
	prepare_builder! = |builder| {
		result = DrawHost.prepare_text!({
			text: builder.content,
			size: builder.size,
			spacing: builder.spacing,
			font: builder.font.for_host(),
		})
		if result.err == 2 {
			Err(ResourceLimit)
		} else if result.err != 0 {
			crash "prepared text host invariant failed"
		} else {
			Ok(
				Prepared.(
					{
						resource: result.prepared,
						measured: { width: result.width, height: result.height },
					},
				),
			)
		}
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

	draw_prepared! : Draw.Frame, { text : Prepared, pos : Math.Vec2, color : Color.Rgba, align : Align } => {}
	draw_prepared! = |_frame, cfg| {
		Prepared.(prepared) = cfg.text
		pos = Text.origin_for(cfg.pos, prepared.measured, cfg.align)
		DrawHost.draw_prepared_text!({ prepared: prepared.resource, pos, color: cfg.color })
	}
}

expect Text.align_offset({ width: 100, height: 40 }, Text.align_center) == { x: 50, y: 20 }
