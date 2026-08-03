## Draw module - provides drawing primitives for the Roc raylib platform
import Assets
import Camera
import Color
import Math

TextureDrawConfig : {
	texture : Assets.Texture,
	source : Math.Rect,
	dest : Math.Rect,
	origin : Math.Vec2,
	rotation : F32,
	tint : Color,
}

TextureDrawOptions : {
	source : Math.Rect,
	source_set : Bool,
	dest : Math.Rect,
	dest_set : Bool,
	pos : Math.Vec2,
	origin : Math.Vec2,
	origin_set : Bool,
	origin_center : Bool,
	rotation : F32,
	scale : Math.Vec2,
	tint : Color,
}

TextureDrawBuilder(field) := {
	value : field,
	apply : TextureDrawOptions -> TextureDrawOptions,
}.{

	default_options : TextureDrawOptions
	default_options = {
		source: Math.rect(0, 0, 0, 0),
		source_set: Bool.False,
		dest: Math.rect(0, 0, 0, 0),
		dest_set: Bool.False,
		pos: Math.zero,
		origin: Math.zero,
		origin_set: Bool.False,
		origin_center: Bool.False,
		rotation: 0,
		scale: { x: 1, y: 1 },
		tint: Color.white,
	}

	map2 : TextureDrawBuilder(a), TextureDrawBuilder(b), (a, b -> c) -> TextureDrawBuilder(c)
	map2 = |left, right, combine| {
		value: combine(left.value, right.value),
		apply: |options| (right.apply)((left.apply)(options)),
	}

	empty : TextureDrawBuilder({})
	empty = { value: {}, apply: |options| options }

	run : TextureDrawBuilder(a), Assets.Texture -> TextureDrawConfig
	run = |builder, texture| {
		options = (builder.apply)(TextureDrawBuilder.default_options)
		source = if options.source_set options.source else Assets.rect(texture)

		dest = if options.dest_set {
			options.dest
		} else {
			{
				x: options.pos.x,
				y: options.pos.y,
				width: source.width * options.scale.x,
				height: source.height * options.scale.y,
			}
		}

		origin = if options.origin_set {
			options.origin
		} else if options.origin_center {
			{ x: dest.width * 0.5, y: dest.height * 0.5 }
		} else {
			Math.zero
		}

		{ texture, source, dest, origin, rotation: options.rotation, tint: options.tint }
	}

	pos : Math.Vec2 -> TextureDrawBuilder(Math.Vec2)
	pos = |value| {
		value,
		apply: |options| { ..options, pos: value },
	}

	source : Math.Rect -> TextureDrawBuilder(Math.Rect)
	source = |value| {
		value,
		apply: |options| { ..options, source: value, source_set: Bool.True },
	}

	dest : Math.Rect -> TextureDrawBuilder(Math.Rect)
	dest = |value| {
		value,
		apply: |options| { ..options, dest: value, dest_set: Bool.True },
	}

	origin : Math.Vec2 -> TextureDrawBuilder(Math.Vec2)
	origin = |value| {
		value,
		apply: |options| { ..options, origin: value, origin_set: Bool.True, origin_center: Bool.False },
	}

	origin_center : TextureDrawBuilder({})
	origin_center = {
		value: {},
		apply: |options| { ..options, origin_set: Bool.False, origin_center: Bool.True },
	}

	rotation : F32 -> TextureDrawBuilder(F32)
	rotation = |value| {
		value,
		apply: |options| { ..options, rotation: value },
	}

	scale : F32 -> TextureDrawBuilder(F32)
	scale = |value| {
		value,
		apply: |options| { ..options, scale: { x: value, y: value } },
	}

	scale_xy : Math.Vec2 -> TextureDrawBuilder(Math.Vec2)
	scale_xy = |value| {
		value,
		apply: |options| { ..options, scale: value },
	}

	tint : Color -> TextureDrawBuilder(Color)
	tint = |value| {
		value,
		apply: |options| { ..options, tint: value },
	}
}

Draw := [].{

	Vector2 : Math.Vec2

	Rect : Math.Rect

	Camera2D : Camera.Camera2D

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

	ScissorRaw : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
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

	## A simple convex polygon. Points must be ordered around the boundary (clockwise
	## or counter-clockwise). Filled concave or self-intersecting polygons are not
	## supported; outlines accept any ordered point path.
	ConvexPolygon : {
		points : List(Vector2),
		style : ShapeStyle,
	}

	## Compatibility alias for ConvexPolygon. Prefer `ConvexPolygon` and
	## `convex_polygon!` in new code so the fill constraint is visible at call sites.
	Polygon : ConvexPolygon

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

	## The built-in font is a zero-allocation tag. Loaded fonts carry a Box whose
	## allocation lives in a typed host heap and whose final ARC release unloads it.
	Font : [DefaultFont, LoadedFont(Box(U64))]

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

	SimpleText : {
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

	TextAlignedRaw : {
		pos : Vector2,
		text : Str,
		size : F32,
		spacing : F32,
		color : Color,
		font : U64,
		align_x : F32,
		align_y : F32,
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

	TextureDraw : TextureDrawConfig

	CameraMode : Camera2D

	TextureDrawRaw : {
		texture : U64,
		source : Math.Rect,
		dest : Math.Rect,
		origin : Math.Vec2,
		rotation : F32,
		tint : Color,
	}

	## ARC-owned framebuffer. Its texture-shaped box has a distinct host kind;
	## the host rejects ordinary textures before entering an offscreen scope.
	## Releasing the final reference unloads the framebuffer and both attachments.
	RenderTexture :: { texture : Assets.Texture }.{
		from_texture : Assets.Texture -> RenderTexture
		from_texture = |texture| { texture: texture }

		as_texture : RenderTexture -> Assets.Texture
		as_texture = |target| target.texture
	}

	RenderTextureSize : {
		width : I32,
		height : I32,
	}

	## ARC-owned GPU shader. Empty vertex/fragment strings select raylib's default
	## stage. Keep this value alive for every cached Uniform derived from it.
	Shader :: { resource : Box(U64) }.{
		from_box : Box(U64) -> Shader
		from_box = |resource| { resource: resource }

		handle : Shader -> U64
		handle = |shader| Box.unbox(shader.resource)
	}

	LoadShader : {
		vertex_path : Str,
		fragment_path : Str,
	}

	LoadShaderSource : {
		vertex_source : Str,
		fragment_source : Str,
	}

	## A cached location retains its shader. Resolve it once during initialization,
	## then setters cross the host boundary with only scalar tokens and values.
	Uniform : {
		shader : Shader,
		location : I32,
	}

	Vec3 : { x : F32, y : F32, z : F32 }

	Vec4 : { x : F32, y : F32, z : F32, w : F32 }

	BlendMode : [
		Alpha,
		Additive,
		Multiplied,
		AddColors,
		SubtractColors,
		AlphaPremultiply,
	]

	alpha_blend : BlendMode
	alpha_blend = Alpha

	additive_blend : BlendMode
	additive_blend = Additive

	multiplied_blend : BlendMode
	multiplied_blend = Multiplied

	add_colors_blend : BlendMode
	add_colors_blend = AddColors

	subtract_colors_blend : BlendMode
	subtract_colors_blend = SubtractColors

	premultiplied_alpha_blend : BlendMode
	premultiplied_alpha_blend = AlphaPremultiply

	ShaderLocationRaw : {
		shader : U64,
		name : Str,
	}

	ShaderFloatRaw : { shader : U64, location : I32, value : F32 }

	ShaderIntRaw : { shader : U64, location : I32, value : I32 }

	ShaderVec2Raw : { shader : U64, location : I32, value : Vector2 }

	ShaderVec3Raw : { shader : U64, location : I32, value : Vec3 }

	ShaderVec4Raw : { shader : U64, location : I32, value : Vec4 }

	ShaderTextureRaw : { shader : U64, location : I32, texture : U64 }

	TextureQuadRaw : {
		texture : U64,
		source : Math.Rect,
		top_left : Math.Vec2,
		bottom_left : Math.Vec2,
		bottom_right : Math.Vec2,
		top_right : Math.Vec2,
		tint : Color,
	}

	## Hosted effects - implemented by the host
	begin_camera! : CameraMode => {}
	begin_blend_raw! : U8 => Bool
	begin_frame! : () => {}
	begin_render_texture_raw! : U64 => Bool
	begin_scissor_raw! : ScissorRaw => {}
	begin_shader_raw! : U64 => Bool
	circle_raw! : CircleRaw => {}
	circle_gradient! : CircleGradient => {}
	circle_lines_raw! : CircleLinesRaw => {}
	clear! : Color => {}
	end_frame! : () => {}
	end_blend_raw! : () => {}
	end_render_texture_raw! : () => {}
	end_scissor_raw! : () => {}
	end_shader_raw! : () => {}
	fps! : Fps => {}
	line_raw! : LineRaw => {}
	load_font_raw! : LoadFont => Box(U64)
	load_render_texture_raw! : RenderTextureSize => Assets.Texture
	load_shader_raw! : LoadShader => Box(U64)
	load_shader_source_raw! : LoadShaderSource => Box(U64)
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
	text_aligned_raw! : TextAlignedRaw => {}
	draw_texture_raw! : TextureDrawRaw => {}
	draw_texture_quad_raw! : TextureQuadRaw => {}
	end_camera! : () => {}
	triangle_raw! : TriangleRaw => {}
	triangle_lines_raw! : TriangleLinesRaw => {}
	shader_location_raw! : ShaderLocationRaw => I32
	set_shader_float_raw! : ShaderFloatRaw => {}
	set_shader_int_raw! : ShaderIntRaw => {}
	set_shader_vec2_raw! : ShaderVec2Raw => {}
	set_shader_vec3_raw! : ShaderVec3Raw => {}
	set_shader_vec4_raw! : ShaderVec4Raw => {}
	set_shader_texture_raw! : ShaderTextureRaw => {}

	filled : Color -> ShapeStyle
	filled = |color| { fill: Fill(color), stroke: NoStroke }

	stroke : Color, F32 -> Stroke
	stroke = |color, thickness| Stroke({ color, thickness })

	outlined : Color, F32 -> ShapeStyle
	outlined = |color, thickness| { fill: NoFill, stroke: Draw.stroke(color, thickness) }

	filled_and_outlined : Color, Color, F32 -> ShapeStyle
	filled_and_outlined = |fill, outline, thickness| { fill: Fill(fill), stroke: Draw.stroke(outline, thickness) }

	default_font : Font
	default_font = DefaultFont

	font_handle : Font -> U64
	font_handle = |font|
		match font {
			DefaultFont => 0
			LoadedFont(handle) => Box.unbox(handle)
		}

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

	align_factor : TextAlign -> Vector2
	align_factor = |align| {
		x = match align.horizontal {
			Left => 0
			Center => 0.5
			Right => 1
		}

		y = match align.vertical {
			Top => 0
			Middle => 0.5
			Bottom => 1
		}

		{ x, y }
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
	polygon! = |cfg| Draw.convex_polygon!(cfg)

	## Draw a convex filled polygon and/or an ordered polygon outline. The host
	## triangulates the fill without allocating; fewer than three points do not fill.
	convex_polygon! : ConvexPolygon => {}
	convex_polygon! = |cfg| {
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
		Draw.measure_text_raw!({
			text: cfg.text,
			size: cfg.size,
			spacing: cfg.spacing,
			font: Draw.font_handle(cfg.font),
		})
	}

	load_font! : LoadFont => Try(Font, [FontLoadFailed, ..])
	load_font! = |cfg| {
		handle = Draw.load_font_raw!(cfg)
		if Box.unbox(handle) == 0 {
			Err(FontLoadFailed)
		} else {
			Ok(LoadedFont(handle))
		}
	}

	texture_draw : Assets.Texture -> TextureDraw
	texture_draw = |texture| TextureDrawBuilder.run(TextureDrawBuilder.empty, texture)

	texture_at : Assets.Texture, Math.Vec2 -> TextureDraw
	texture_at = |texture, pos| TextureDrawBuilder.run(TextureDrawBuilder.pos(pos), texture)

	texture! : TextureDraw => {}
	texture! = |cfg| {
		texture_info = Assets.info(cfg.texture)
		Draw.draw_texture_raw!({
			texture: texture_info.handle,
			source: cfg.source,
			dest: cfg.dest,
			origin: cfg.origin,
			rotation: cfg.rotation,
			tint: cfg.tint,
		})
	}

	draw_texture! : TextureDraw => {}
	draw_texture! = |cfg| Draw.texture!(cfg)

	## Allocate an offscreen framebuffer. Do this during initialization, not per
	## frame; creation allocates GPU resources and one fixed host-heap slot.
	load_render_texture! : RenderTextureSize => Try(RenderTexture, [RenderTextureLoadFailed, ..])
	load_render_texture! = |size| {
		texture = Draw.load_render_texture_raw!(size)
		if (Box.unbox(texture)).handle == 0 {
			Err(RenderTextureLoadFailed)
		} else {
			Ok(RenderTexture.from_texture(texture))
		}
	}

	## View the color attachment as a normal Texture without allocating or copying.
	## The returned ARC reference keeps the owning framebuffer alive.
	render_texture : RenderTexture -> Assets.Texture
	render_texture = |target| target.as_texture()

	## Render textures use OpenGL framebuffer coordinates, so their color
	## attachment is vertically inverted when sampled on screen.
	render_texture_source : RenderTexture -> Math.Rect
	render_texture_source = |target| {
		info = Assets.info(target.as_texture())
		{ x: 0, y: 0, width: info.width, height: -info.height }
	}

	shader_handle : Shader -> U64
	shader_handle = |shader| shader.handle()

	## Load shader stages from files. Pass an empty string to use raylib's default
	## vertex or fragment stage.
	load_shader! : LoadShader => Try(Shader, [ShaderLoadFailed, ..])
	load_shader! = |cfg| {
		resource = Draw.load_shader_raw!(cfg)
		if Box.unbox(resource) == 0 {
			Err(ShaderLoadFailed)
		} else {
			Ok(Shader.from_box(resource))
		}
	}

	## Compile shader stages from source strings. Empty strings select the default
	## stage, which is useful for fragment-only 2D post-processing.
	load_shader_source! : LoadShaderSource => Try(Shader, [ShaderLoadFailed, ..])
	load_shader_source! = |cfg| {
		resource = Draw.load_shader_source_raw!(cfg)
		if Box.unbox(resource) == 0 {
			Err(ShaderLoadFailed)
		} else {
			Ok(Shader.from_box(resource))
		}
	}

	## Resolve a uniform name once and retain the shader beside its location.
	uniform! : Shader, Str => Try(Uniform, [UniformNotFound, ..])
	uniform! = |shader, name| {
		location = Draw.shader_location_raw!({ shader: Draw.shader_handle(shader), name })
		if location < 0 {
			Err(UniformNotFound)
		} else {
			Ok({ shader, location })
		}
	}

	set_uniform_f32! : Uniform, F32 => {}
	set_uniform_f32! = |uniform, value| Draw.set_shader_float_raw!({ shader: Draw.shader_handle(uniform.shader), location: uniform.location, value })

	set_uniform_i32! : Uniform, I32 => {}
	set_uniform_i32! = |uniform, value| Draw.set_shader_int_raw!({ shader: Draw.shader_handle(uniform.shader), location: uniform.location, value })

	set_uniform_vec2! : Uniform, Vector2 => {}
	set_uniform_vec2! = |uniform, value| Draw.set_shader_vec2_raw!({ shader: Draw.shader_handle(uniform.shader), location: uniform.location, value })

	set_uniform_vec3! : Uniform, Vec3 => {}
	set_uniform_vec3! = |uniform, value| Draw.set_shader_vec3_raw!({ shader: Draw.shader_handle(uniform.shader), location: uniform.location, value })

	set_uniform_vec4! : Uniform, Vec4 => {}
	set_uniform_vec4! = |uniform, value| Draw.set_shader_vec4_raw!({ shader: Draw.shader_handle(uniform.shader), location: uniform.location, value })

	set_uniform_color! : Uniform, Color => {}
	set_uniform_color! = |uniform, color|
		Draw.set_uniform_vec4!(
			uniform,
			{
				x: U8.to_f32(color.r) / 255,
				y: U8.to_f32(color.g) / 255,
				z: U8.to_f32(color.b) / 255,
				w: U8.to_f32(color.a) / 255,
			},
		)

	set_uniform_texture! : Uniform, Assets.Texture => {}
	set_uniform_texture! = |uniform, texture| Draw.set_shader_texture_raw!({
		shader: Draw.shader_handle(uniform.shader),
		location: uniform.location,
		texture: (Assets.info(texture)).handle,
	})

	blend_mode_raw : BlendMode -> U8
	blend_mode_raw = |mode|
		match mode {
			Alpha => 0
			Additive => 1
			Multiplied => 2
			AddColors => 3
			SubtractColors => 4
			AlphaPremultiply => 5
		}

	## Scope offscreen rendering so BeginTextureMode/EndTextureMode stay paired.
	with_render_texture! : RenderTexture, (() => {}) => {}
	with_render_texture! = |target, callback| {
		if Draw.begin_render_texture_raw!((Assets.info(target.as_texture())).handle) {
			callback()
			Draw.end_render_texture_raw!()
		}
	}

	## Scope shader application so the default shader is always restored.
	with_shader! : Shader, (() => {}) => {}
	with_shader! = |shader, callback| {
		if Draw.begin_shader_raw!(Draw.shader_handle(shader)) {
			callback()
			Draw.end_shader_raw!()
		}
	}

	## Scope one of raylib's built-in blend equations. Custom blend factors are
	## deliberately excluded until they can be represented without global state.
	with_blend_mode! : BlendMode, (() => {}) => {}
	with_blend_mode! = |mode, callback| {
		if Draw.begin_blend_raw!(Draw.blend_mode_raw(mode)) {
			callback()
			Draw.end_blend_raw!()
		}
	}

	with_camera! : CameraMode, (() => {}) => {}
	with_camera! = |camera, callback| {
		Draw.begin_camera!(camera)
		callback()
		Draw.end_camera!()
	}

	with_mode_2d! : CameraMode, (() => {}) => {}
	with_mode_2d! = |camera, callback| Draw.with_camera!(camera, callback)

	## Restrict callback drawing to screen-space `bounds`, then always close the
	## scissor before returning. Use this instead of manually pairing the raw effects.
	with_scissor! : Math.Rect, (() => {}) => {}
	with_scissor! = |bounds, callback| {
		Draw.begin_scissor_raw!(bounds)
		callback()
		Draw.end_scissor_raw!()
	}

	text! : Text => {}
	text! = |cfg| {
		align = Draw.align_factor(cfg.align)
		Draw.text_aligned_raw!({
			pos: cfg.pos,
			text: cfg.text,
			size: cfg.size,
			spacing: cfg.spacing,
			color: cfg.color,
			font: Draw.font_handle(cfg.font),
			align_x: align.x,
			align_y: align.y,
		})
	}

	debug_text! : DebugText => {}
	debug_text! = |cfg|
		Draw.text!({
			pos: cfg.pos,
			text: cfg.text,
			size: cfg.size,
			spacing: Draw.default_spacing,
			color: cfg.color,
			font: Draw.default_font,
			align: Draw.align_top_left,
		})

	text_at! : SimpleText => {}
	text_at! = |cfg|
		Draw.text!({
			pos: cfg.pos,
			text: cfg.text,
			size: cfg.size,
			spacing: Draw.default_spacing,
			color: cfg.color,
			font: Draw.default_font,
			align: Draw.align_top_left,
		})

	text_centered! : SimpleText => {}
	text_centered! = |cfg|
		Draw.text!({
			pos: cfg.pos,
			text: cfg.text,
			size: cfg.size,
			spacing: Draw.default_spacing,
			color: cfg.color,
			font: Draw.default_font,
			align: Draw.align_center,
		})

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

expect (TextureDrawBuilder.run(TextureDrawBuilder.empty, Box.box({ handle: 1, width: 8, height: 4 }))).source == Math.rect(0, 0, 8, 4)
expect (TextureDrawBuilder.run(TextureDrawBuilder.scale(2), Box.box({ handle: 1, width: 8, height: 4 }))).dest == Math.rect(0, 0, 16, 8)
expect (TextureDrawBuilder.run(TextureDrawBuilder.origin_center, Box.box({ handle: 1, width: 8, height: 4 }))).origin == { x: 4, y: 2 }
expect Draw.align_factor(Draw.align_top_left) == { x: 0, y: 0 }
expect Draw.align_factor(Draw.align_center) == { x: 0.5, y: 0.5 }
expect Draw.align_factor(Draw.align_bottom_right) == { x: 1, y: 1 }
expect Draw.blend_mode_raw(Draw.alpha_blend) == 0
expect Draw.blend_mode_raw(Draw.premultiplied_alpha_blend) == 5
expect Draw.render_texture_source(Draw.RenderTexture.from_texture(Box.box({ handle: 7, width: 320, height: 180 }))) == Math.rect(0, 0, 320, -180)
