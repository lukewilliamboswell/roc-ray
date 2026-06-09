## Draw module - provides drawing primitives for the Roc raylib platform
import Color

Draw := [].{

	Vector2 : {
		x : F32,
		y : F32,
	}

	Fill : [NoFill, Fill(Color)]

	Stroke : [NoStroke, Stroke({ color : Color, thickness : F32 })]

	ShapeStyle : {
		fill : Fill,
		stroke : Stroke,
	}

	Rectangle : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		style : ShapeStyle,
	}

	RectangleRaw : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		color : Color,
	}

	RectangleLinesRaw : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		color : Color,
		thickness : F32,
	}

	RoundedRectangle : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		radius : F32,
		segments : I32,
		style : ShapeStyle,
	}

	RoundedRectangleRaw : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		radius : F32,
		segments : I32,
		color : Color,
	}

	RoundedRectangleLinesRaw : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		radius : F32,
		segments : I32,
		color : Color,
		thickness : F32,
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
		style : ShapeStyle,
	}

	CircleRaw : {
		center : Vector2,
		radius : F32,
		color : Color,
	}

	CircleLinesRaw : {
		center : Vector2,
		radius : F32,
		color : Color,
		thickness : F32,
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
		stroke : Stroke,
	}

	LineRaw : {
		start : Vector2,
		end : Vector2,
		color : Color,
		thickness : F32,
	}

	Triangle : {
		a : Vector2,
		b : Vector2,
		c : Vector2,
		style : ShapeStyle,
	}

	TriangleRaw : {
		a : Vector2,
		b : Vector2,
		c : Vector2,
		color : Color,
	}

	TriangleLinesRaw : {
		a : Vector2,
		b : Vector2,
		c : Vector2,
		color : Color,
		thickness : F32,
	}

	Polygon : {
		points : List(Vector2),
		style : ShapeStyle,
	}

	PolygonRaw : {
		points : List(Vector2),
		color : Color,
	}

	PolygonLinesRaw : {
		points : List(Vector2),
		color : Color,
		thickness : F32,
	}

	Fps : {
		pos : Vector2,
		size : F32,
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

	DebugText : {
		pos : Vector2,
		text : Str,
		size : F32,
		color : Color,
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
	circle_raw! : CircleRaw => {}
	circle_gradient! : CircleGradient => {}
	circle_lines_raw! : CircleLinesRaw => {}
	clear! : Color => {}
	end_frame! : () => {}
	fps! : Fps => {}
	line_raw! : LineRaw => {}
	load_font_raw! : LoadFont => U64
	measure_text_raw! : MeasureTextRaw => TextSize
	polygon_raw! : PolygonRaw => {}
	polygon_lines_raw! : PolygonLinesRaw => {}
	rectangle_raw! : RectangleRaw => {}
	rectangle_gradient_h! : RectangleGradientH => {}
	rectangle_gradient_v! : RectangleGradientV => {}
	rectangle_lines_raw! : RectangleLinesRaw => {}
	rounded_rectangle_raw! : RoundedRectangleRaw => {}
	rounded_rectangle_lines_raw! : RoundedRectangleLinesRaw => {}
	text_raw! : TextRaw => {}
	triangle_raw! : TriangleRaw => {}
	triangle_lines_raw! : TriangleLinesRaw => {}

	filled : Color -> ShapeStyle
	filled = |color| { fill: Fill(color), stroke: NoStroke }

	stroke : Color, F32 -> Stroke
	stroke = |color, thickness| Stroke({ color, thickness })

	outlined : Color, F32 -> ShapeStyle
	outlined = |color, thickness| { fill: NoFill, stroke: Draw.stroke(color, thickness) }

	filled_and_outlined : Color, Color, F32 -> ShapeStyle
	filled_and_outlined = |fill, outline, thickness| { fill: Fill(fill), stroke: Draw.stroke(outline, thickness) }

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

	rectangle! : Rectangle => {}
	rectangle! = |cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => Draw.rectangle_raw!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => Draw.rectangle_lines_raw!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

	rounded_rectangle! : RoundedRectangle => {}
	rounded_rectangle! = |cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => Draw.rounded_rectangle_raw!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, radius: cfg.radius, segments: cfg.segments, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => Draw.rounded_rectangle_lines_raw!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, radius: cfg.radius, segments: cfg.segments, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

	circle! : Circle => {}
	circle! = |cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => Draw.circle_raw!({ center: cfg.center, radius: cfg.radius, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => Draw.circle_lines_raw!({ center: cfg.center, radius: cfg.radius, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

	line! : Line => {}
	line! = |cfg|
		match cfg.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => Draw.line_raw!({ start: cfg.start, end: cfg.end, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}

	triangle! : Triangle => {}
	triangle! = |cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => Draw.triangle_raw!({ a: cfg.a, b: cfg.b, c: cfg.c, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => Draw.triangle_lines_raw!({ a: cfg.a, b: cfg.b, c: cfg.c, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

	polygon! : Polygon => {}
	polygon! = |cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => Draw.polygon_raw!({ points: cfg.points, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => Draw.polygon_lines_raw!({ points: cfg.points, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
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

	debug_text! : DebugText => {}
	debug_text! = |cfg|
		Draw.text!(
			{
				pos: cfg.pos,
				text: cfg.text,
				size: cfg.size,
				spacing: Draw.default_spacing,
				color: cfg.color,
				font: Draw.default_font,
				align: Draw.align_top_left,
			},
		)

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
