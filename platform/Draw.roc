## Draw module - provides drawing primitives for the Roc raylib platform
import Color

Draw := [].{

	Vector2 : {
		x : F32,
		y : F32,
	}

	Rectangle : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		color : Color,
	}

	RectangleGradientV : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		color_top : Color,
		color_bottom : Color,
	}

	RectangleGradientH : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		color_left : Color,
		color_right : Color,
	}

	Circle : {
		center : Vector2,
		radius : F32,
		color : Color,
	}

	CircleGradient : {
		center : Vector2,
		radius : F32,
		color_inner : Color,
		color_outer : Color,
	}

	Line : {
		start : Vector2,
		end : Vector2,
		color : Color,
	}

	Font : Box(U64)

	HAlign : [Left, Center, Right]

	VAlign : [Top, Middle, Bottom]

	TextAlign : {
		horizontal : HAlign,
		vertical : VAlign,
	}

	TextSize : {
		width : F32,
		height : F32,
	}

	Text : {
		pos : Vector2,
		text : Str,
		size : F32,
		spacing : F32,
		color : Color,
		font : Font,
		align : TextAlign,
	}

	TextRaw : {
		pos : Vector2,
		text : Str,
		size : F32,
		spacing : F32,
		color : Color,
		font : U64,
	}

	MeasureText : {
		text : Str,
		size : F32,
		spacing : F32,
		font : Font,
	}

	MeasureTextRaw : {
		text : Str,
		size : F32,
		spacing : F32,
		font : U64,
	}

	LoadFont : {
		path : Str,
		size : I32,
	}

	## Hosted effects - implemented by the host
	begin_frame! : () => {}
	circle! : Circle => {}
	circle_gradient! : CircleGradient => {}
	clear! : Color => {}
	end_frame! : () => {}
	line! : Line => {}
	rectangle! : Rectangle => {}
	rectangle_gradient_h! : RectangleGradientH => {}
	rectangle_gradient_v! : RectangleGradientV => {}
	text_raw! : TextRaw => {}
	measure_text_raw! : MeasureTextRaw => TextSize
	load_font_raw! : LoadFont => U64

	default_font : Font
	default_font = Box.box(0)

	default_spacing : F32
	default_spacing = 1

	align_top_left : TextAlign
	align_top_left = { horizontal: Left, vertical: Top }

	align_top_center : TextAlign
	align_top_center = { horizontal: Center, vertical: Top }

	align_top_right : TextAlign
	align_top_right = { horizontal: Right, vertical: Top }

	align_center : TextAlign
	align_center = { horizontal: Center, vertical: Middle }

	align_middle_left : TextAlign
	align_middle_left = { horizontal: Left, vertical: Middle }

	align_middle_right : TextAlign
	align_middle_right = { horizontal: Right, vertical: Middle }

	align_bottom_left : TextAlign
	align_bottom_left = { horizontal: Left, vertical: Bottom }

	align_bottom_center : TextAlign
	align_bottom_center = { horizontal: Center, vertical: Bottom }

	align_bottom_right : TextAlign
	align_bottom_right = { horizontal: Right, vertical: Bottom }

	align_offset : TextSize, TextAlign -> Vector2
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

	origin_for : Vector2, TextSize, TextAlign -> Vector2
	origin_for = |pos, size, align| {
		offset = Draw.align_offset(size, align)
		{ x: pos.x - offset.x, y: pos.y - offset.y }
	}

	center_in_rect : Rectangle, TextSize -> Vector2
	center_in_rect = |rect, size| {
		{
			x: rect.x + rect.width * 0.5 - size.width * 0.5,
			y: rect.y + rect.height * 0.5 - size.height * 0.5,
		}
	}

	measure_text! : MeasureText => TextSize
	measure_text! = |cfg| {
		Draw.measure_text_raw!(
			{
				text: cfg.text,
				size: cfg.size,
				spacing: cfg.spacing,
				font: Box.unbox(cfg.font),
			},
		)
	}

	load_font! : LoadFont => Try(Font, [FontLoadFailed, ..])
	load_font! = |cfg| {
		handle = Draw.load_font_raw!(cfg)
		if handle == 0 {
			Err(FontLoadFailed)
		} else {
			Ok(Box.box(handle))
		}
	}

	text! : Text => {}
	text! = |cfg| {
		size = Draw.measure_text!(
			{
				text: cfg.text,
				size: cfg.size,
				spacing: cfg.spacing,
				font: cfg.font,
			},
		)
		pos = Draw.origin_for(cfg.pos, size, cfg.align)
		Draw.text_raw!(
			{
				pos,
				text: cfg.text,
				size: cfg.size,
				spacing: cfg.spacing,
				color: cfg.color,
				font: Box.unbox(cfg.font),
			},
		)
	}

	## High-level draw function with callback pattern
	## Ensures begin/end frame are properly paired
	draw! : Color, (() => {}) => {}
	draw! = |bg_color, callback| {
		Draw.begin_frame!()
		Draw.clear!(bg_color)
		callback()
		Draw.end_frame!()
	}
}
