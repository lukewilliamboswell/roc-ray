## Immediate-mode 2D drawing, text, textures, cameras, and render effects.
##
## `draw!` owns the frame scope. Nested helpers such as `with_camera!`,
## `with_scissor!`, `with_render_texture!`, `with_shader!`, and
## `with_blend_mode!` keep raylib's begin/end state transitions paired. Create
## host-owned fonts, render textures, and shaders during initialization and keep
## them in the model; per-frame drawing and uniform updates do not allocate.
import Assets
import AssetsHost
import Camera
import Color
import DrawHost
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

	## Two-dimensional vector used by drawing records.
	Vector2 : Math.Vec2

	## Axis-aligned rectangle used by drawing records.
	Rect : Math.Rect

	## Pure 2D camera settings.
	Camera2D : Camera.Camera2D

	## Optional shape fill.
	Fill : [NoFill, Fill(Color)]

	## Optional shape outline with color and thickness.
	Stroke : [NoStroke, Stroke({ color : Color, thickness : F32 })]

	## Combined fill and outline applied by shape helpers.
	ShapeStyle : {
		fill : Fill,
		stroke : Stroke,
	}

	## Axis-aligned rectangle and its style.
	Rectangle : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		style : ShapeStyle,
	}

	## Rounded rectangle; radius and segment count control corner tessellation.
	RoundedRectangle : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		radius : F32,
		segments : I32,
		style : ShapeStyle,
	}

	## Vertical rectangle gradient from top to bottom.
	RectangleGradientV : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		color_top : Color,
		color_bottom : Color,
	}

	## Horizontal rectangle gradient from left to right.
	RectangleGradientH : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		color_left : Color,
		color_right : Color,
	}

	## Circle and its style.
	Circle : {
		center : Vector2,
		radius : F32,
		style : ShapeStyle,
	}

	## Radial gradient from inner to outer color.
	CircleGradient : {
		center : Vector2,
		radius : F32,
		color_inner : Color,
		color_outer : Color,
	}

	## Line segment and stroke.
	Line : {
		start : Vector2,
		end : Vector2,
		stroke : Stroke,
	}

	## Triangle vertices and style.
	Triangle : {
		a : Vector2,
		b : Vector2,
		c : Vector2,
		style : ShapeStyle,
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

	## Position, size, and color for the FPS counter.
	Fps : {
		pos : Vector2,
		size : F32,
		color : Color,
	}

	## The built-in font is allocation-free. A loaded font is an opaque host-owned
	## resource whose final reference unloads its texture automatically.
	Font : DrawHost.Font

	## Horizontal text anchor.
	HAlign : [Left, Center, Right]

	## Vertical text anchor.
	VAlign : [Top, Middle, Bottom]

	## Horizontal and vertical text anchor.
	TextAlign : {
		horizontal : HAlign,
		vertical : VAlign,
	}

	## Measured text dimensions in logical pixels.
	TextSize : {
		width : F32,
		height : F32,
	}

	## Fully configured text draw.
	Text : {
		pos : Vector2,
		text : Str,
		size : F32,
		spacing : F32,
		color : Color,
		font : Font,
		align : TextAlign,
	}

	## Built-in-font text intended for quick diagnostics.
	DebugText : {
		pos : Vector2,
		text : Str,
		size : F32,
		color : Color,
	}

	## Built-in-font text with default spacing.
	SimpleText : {
		pos : Vector2,
		text : Str,
		size : F32,
		color : Color,
	}

	## Text measurement configuration.
	MeasureText : {
		text : Str,
		size : F32,
		spacing : F32,
		font : Font,
	}

	## Font path and base pixel size.
	LoadFont : {
		path : Str,
		size : I32,
	}

	## Resolved texture draw configuration.
	TextureDraw : TextureDrawConfig

	## Camera accepted by scoped 2D drawing.
	CameraMode : Camera2D

	## Host-owned framebuffer. Its texture-shaped box has a distinct host kind;
	## the host rejects ordinary textures before entering an offscreen scope.
	## Releasing the final reference unloads the framebuffer and both attachments.
	RenderTexture : DrawHost.RenderTexture

	## Pixel dimensions for a new offscreen render target.
	RenderTextureSize : {
		width : I32,
		height : I32,
	}

	## Host-owned GPU shader. Empty vertex/fragment strings select raylib's default
	## stage. Keep this value alive for every cached Uniform derived from it.
	Shader : DrawHost.Shader

	## File paths for shader stages. An empty path selects the default stage.
	LoadShader : {
		vertex_path : Str,
		fragment_path : Str,
	}

	## Shader source strings. An empty string selects the default stage.
	LoadShaderSource : {
		vertex_source : Str,
		fragment_source : Str,
	}

	## A cached location retains its shader. Resolve it once during initialization;
	## setters transfer this owning value so the shader stays live for the call.
	Uniform : DrawHost.Uniform

	## Three-component shader uniform value.
	Vec3 : { x : F32, y : F32, z : F32 }

	## Four-component shader uniform value.
	Vec4 : { x : F32, y : F32, z : F32, w : F32 }

	## Built-in blend equations with scoped application through `with_blend_mode!`.
	BlendMode : [
		Alpha,
		Additive,
		Multiplied,
		AddColors,
		SubtractColors,
		AlphaPremultiply,
	]

	## Conventional source-alpha compositing.
	alpha_blend : BlendMode
	alpha_blend = Alpha

	## Add source and destination colors, useful for light and glow effects.
	additive_blend : BlendMode
	additive_blend = Additive

	## Multiply source and destination colors.
	multiplied_blend : BlendMode
	multiplied_blend = Multiplied

	## Add source and destination color channels.
	add_colors_blend : BlendMode
	add_colors_blend = AddColors

	## Subtract source color channels from the destination.
	subtract_colors_blend : BlendMode
	subtract_colors_blend = SubtractColors

	## Alpha compositing for textures whose RGB channels are premultiplied.
	premultiplied_alpha_blend : BlendMode
	premultiplied_alpha_blend = AlphaPremultiply

	## Create a fill-only shape style.
	filled : Color -> ShapeStyle
	filled = |color| { fill: Fill(color), stroke: NoStroke }

	## Create a stroke with color and thickness in logical pixels.
	stroke : Color, F32 -> Stroke
	stroke = |color, thickness| Stroke({ color, thickness })

	## Create a stroke-only shape style.
	outlined : Color, F32 -> ShapeStyle
	outlined = |color, thickness| { fill: NoFill, stroke: Draw.stroke(color, thickness) }

	## Create a shape style with both fill and outline.
	filled_and_outlined : Color, Color, F32 -> ShapeStyle
	filled_and_outlined = |fill, outline, thickness| { fill: Fill(fill), stroke: Draw.stroke(outline, thickness) }

	## The built-in font, which requires no loading or host-owned resource.
	default_font : Font
	default_font = DefaultFont

	## Default text glyph spacing in logical pixels.
	default_spacing : F32
	default_spacing = 1

	## Top-left text anchor.
	align_top_left : TextAlign
	align_top_left = { horizontal: Left, vertical: Top }

	## Top-center text anchor.
	align_top_center : TextAlign
	align_top_center = { horizontal: Center, vertical: Top }

	## Top-right text anchor.
	align_top_right : TextAlign
	align_top_right = { horizontal: Right, vertical: Top }

	## Centered text anchor.
	align_center : TextAlign
	align_center = { horizontal: Center, vertical: Middle }

	## Middle-left text anchor.
	align_middle_left : TextAlign
	align_middle_left = { horizontal: Left, vertical: Middle }

	## Middle-right text anchor.
	align_middle_right : TextAlign
	align_middle_right = { horizontal: Right, vertical: Middle }

	## Bottom-left text anchor.
	align_bottom_left : TextAlign
	align_bottom_left = { horizontal: Left, vertical: Bottom }

	## Bottom-center text anchor.
	align_bottom_center : TextAlign
	align_bottom_center = { horizontal: Center, vertical: Bottom }

	## Bottom-right text anchor.
	align_bottom_right : TextAlign
	align_bottom_right = { horizontal: Right, vertical: Bottom }

	## Convert a measured size and alignment into an anchor offset.
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

	## Find the top-left text origin for an anchored position.
	origin_for : Vector2, TextSize, TextAlign -> Vector2
	origin_for = |pos, size, align| {
		offset = Draw.align_offset(size, align)
		{ x: pos.x - offset.x, y: pos.y - offset.y }
	}

	## Convert text alignment into horizontal and vertical factors from 0 to 1.
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

	## Find the top-left position that centers measured text in a rectangle.
	center_in_rect : Rectangle, TextSize -> Vector2
	center_in_rect = |rect, size| {
		{
			x: rect.x + rect.width * 0.5 - size.width * 0.5,
			y: rect.y + rect.height * 0.5 - size.height * 0.5,
		}
	}

	## Clear the active drawing target to a solid color.
	clear! : Color => {}
	clear! = |color| DrawHost.clear!(color)

	## Draw a vertical rectangle gradient.
	rectangle_gradient_v! : RectangleGradientV => {}
	rectangle_gradient_v! = |cfg| DrawHost.rectangle_gradient_v!(cfg)

	## Draw a horizontal rectangle gradient.
	rectangle_gradient_h! : RectangleGradientH => {}
	rectangle_gradient_h! = |cfg| DrawHost.rectangle_gradient_h!(cfg)

	## Draw a radial circle gradient.
	circle_gradient! : CircleGradient => {}
	circle_gradient! = |cfg| DrawHost.circle_gradient!(cfg)

	## Draw raylib's current frames-per-second counter.
	fps! : Fps => {}
	fps! = |cfg| DrawHost.fps!(cfg)

	## Draw a filled and/or outlined axis-aligned rectangle.
	rectangle! : Rectangle => {}
	rectangle! = |cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => DrawHost.rectangle!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => DrawHost.rectangle_lines!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

	## Draw a filled and/or outlined rounded rectangle.
	rounded_rectangle! : RoundedRectangle => {}
	rounded_rectangle! = |cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => DrawHost.rounded_rectangle!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, radius: cfg.radius, segments: cfg.segments, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => DrawHost.rounded_rectangle_lines!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, radius: cfg.radius, segments: cfg.segments, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

	## Draw a filled and/or outlined circle.
	circle! : Circle => {}
	circle! = |cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => DrawHost.circle!({ center: cfg.center, radius: cfg.radius, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => DrawHost.circle_lines!({ center: cfg.center, radius: cfg.radius, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

	## Draw a stroked line segment. `NoStroke` performs no drawing.
	line! : Line => {}
	line! = |cfg|
		match cfg.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => DrawHost.line!({ start: cfg.start, end: cfg.end, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}

	## Draw a filled and/or outlined triangle.
	triangle! : Triangle => {}
	triangle! = |cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => DrawHost.triangle!({ a: cfg.a, b: cfg.b, c: cfg.c, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => DrawHost.triangle_lines!({ a: cfg.a, b: cfg.b, c: cfg.c, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

	## Compatibility alias for `convex_polygon!`.
	polygon! : Polygon => {}
	polygon! = |cfg| Draw.convex_polygon!(cfg)

	## Draw a convex filled polygon and/or an ordered polygon outline. The host
	## triangulates the fill without allocating; fewer than three points do not fill.
	convex_polygon! : ConvexPolygon => {}
	convex_polygon! = |cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => DrawHost.polygon!({ points: cfg.points, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => DrawHost.polygon_lines!({ points: cfg.points, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

	## Measure text without drawing it, using the selected font and spacing.
	measure_text! : MeasureText => TextSize
	measure_text! = |cfg| {
		DrawHost.measure_text!({
			text: cfg.text,
			size: cfg.size,
			spacing: cfg.spacing,
			font: cfg.font,
		})
	}

	## Load a host-owned font from disk at the requested base size.
	load_font! : LoadFont => Try(Font, [FontLoadFailed, ResourceLimit, ..])
	load_font! = |cfg| {
		result = DrawHost.load_font!(cfg)
		if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(FontLoadFailed) else Ok(LoadedFont(result.font))
	}

	## Create a draw configuration covering the whole texture at the origin.
	texture_draw : Assets.Texture -> TextureDraw
	texture_draw = |texture| TextureDrawBuilder.run(TextureDrawBuilder.empty, texture)

	## Create a draw configuration covering the whole texture at `pos`.
	texture_at : Assets.Texture, Math.Vec2 -> TextureDraw
	texture_at = |texture, pos| TextureDrawBuilder.run(TextureDrawBuilder.pos(pos), texture)

	## Draw a texture with explicit source, destination, origin, rotation, and tint.
	texture! : TextureDraw => {}
	texture! = |cfg| {
		DrawHost.draw_texture!({
			texture: cfg.texture,
			source: cfg.source,
			dest: cfg.dest,
			origin: cfg.origin,
			rotation: cfg.rotation,
			tint: cfg.tint,
		})
	}

	## Compatibility alias for `texture!`.
	draw_texture! : TextureDraw => {}
	draw_texture! = |cfg| Draw.texture!(cfg)

	## Allocate an offscreen framebuffer. Do this during initialization, not per
	## frame; creation allocates GPU resources and one fixed host-heap slot.
	load_render_texture! : RenderTextureSize => Try(RenderTexture, [RenderTextureLoadFailed, ResourceLimit, ..])
	load_render_texture! = |size| {
		result = DrawHost.load_render_texture!(size)
		if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(RenderTextureLoadFailed) else Ok(result.target)
	}

	## View the color attachment as a normal Texture without allocating or copying.
	## The returned reference keeps the owning framebuffer alive.
	render_texture : RenderTexture -> Assets.Texture
	render_texture = |target| DrawHost.RenderTexture.texture(target)

	## Render textures use OpenGL framebuffer coordinates, so their color
	## attachment is vertically inverted when sampled on screen.
	render_texture_source : RenderTexture -> Math.Rect
	render_texture_source = |target| {
		texture = Draw.render_texture(target)
		{ x: 0, y: 0, width: Assets.width(texture), height: 0 - Assets.height(texture) }
	}

	## Load shader stages from files. Pass an empty string to use raylib's default
	## vertex or fragment stage.
	load_shader! : LoadShader => Try(Shader, [ShaderLoadFailed, ResourceLimit, ..])
	load_shader! = |cfg| {
		result = DrawHost.load_shader!(cfg)
		if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(ShaderLoadFailed) else Ok(result.shader)
	}

	## Compile shader stages from source strings. Empty strings select the default
	## stage, which is useful for fragment-only 2D post-processing.
	load_shader_source! : LoadShaderSource => Try(Shader, [ShaderLoadFailed, ResourceLimit, ..])
	load_shader_source! = |cfg| {
		result = DrawHost.load_shader_source!(cfg)
		if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(ShaderLoadFailed) else Ok(result.shader)
	}

	## Resolve a uniform name once and retain the shader beside its location.
	uniform! : Shader, Str => Try(Uniform, [UniformNotFound, ..])
	uniform! = |shader, name| {
		location = DrawHost.shader_location!({ shader, name })
		if location < 0 {
			Err(UniformNotFound)
		} else {
			Ok(DrawHost.Uniform.from_shader_location(shader, location))
		}
	}

	## Update a cached scalar floating-point uniform.
	set_uniform_f32! : Uniform, F32 => {}
	set_uniform_f32! = |uniform, value| DrawHost.set_shader_float!({ uniform, value })

	## Update a cached scalar integer uniform.
	set_uniform_i32! : Uniform, I32 => {}
	set_uniform_i32! = |uniform, value| DrawHost.set_shader_int!({ uniform, value })

	## Update a cached two-component vector uniform.
	set_uniform_vec2! : Uniform, Vector2 => {}
	set_uniform_vec2! = |uniform, value| DrawHost.set_shader_vec2!({ uniform, value })

	## Update a cached three-component vector uniform.
	set_uniform_vec3! : Uniform, Vec3 => {}
	set_uniform_vec3! = |uniform, value| DrawHost.set_shader_vec3!({ uniform, value })

	## Update a cached four-component vector uniform.
	set_uniform_vec4! : Uniform, Vec4 => {}
	set_uniform_vec4! = |uniform, value| DrawHost.set_shader_vec4!({ uniform, value })

	## Update a vec4 uniform from normalized RGBA color channels.
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

	## Bind a host-owned texture to a cached sampler uniform.
	set_uniform_texture! : Uniform, Assets.Texture => {}
	set_uniform_texture! = |uniform, texture| DrawHost.set_shader_texture!({
		uniform,
		texture,
	})

	## Scope offscreen rendering so BeginTextureMode/EndTextureMode stay paired.
	with_render_texture! : RenderTexture, (() => {}) => {}
	with_render_texture! = |target, callback| {
		if DrawHost.begin_render_texture!(target) {
			callback()
			DrawHost.end_render_texture!()
		}
	}

	## Scope shader application so the default shader is always restored.
	with_shader! : Shader, (() => {}) => {}
	with_shader! = |shader, callback| {
		if DrawHost.begin_shader!(shader) {
			callback()
			DrawHost.end_shader!()
		}
	}

	## Scope one of raylib's built-in blend equations. Custom blend factors are
	## deliberately excluded until they can be represented without global state.
	with_blend_mode! : BlendMode, (() => {}) => {}
	with_blend_mode! = |mode, callback| {
		if DrawHost.begin_blend!(blend_mode_code(mode)) {
			callback()
			DrawHost.end_blend!()
		}
	}

	## Draw the callback in world space using this camera.
	with_camera! : CameraMode, (() => {}) => {}
	with_camera! = |camera, callback| {
		DrawHost.begin_camera!(camera)
		callback()
		DrawHost.end_camera!()
	}

	## Compatibility alias for `with_camera!`.
	with_mode_2d! : CameraMode, (() => {}) => {}
	with_mode_2d! = |camera, callback| Draw.with_camera!(camera, callback)

	## Restrict callback drawing to screen-space `bounds`, then always close the
	## scissor before returning. Use this instead of manually pairing the raw effects.
	with_scissor! : Math.Rect, (() => {}) => {}
	with_scissor! = |bounds, callback| {
		DrawHost.begin_scissor!(bounds)
		callback()
		DrawHost.end_scissor!()
	}

	## Draw text using explicit font, spacing, color, and anchor alignment.
	text! : Text => {}
	text! = |cfg| {
		align = Draw.align_factor(cfg.align)
		DrawHost.text_aligned!({
			pos: cfg.pos,
			text: cfg.text,
			size: cfg.size,
			spacing: cfg.spacing,
			color: cfg.color,
			font: cfg.font,
			align_x: align.x,
			align_y: align.y,
		})
	}

	## Draw top-left aligned text with the built-in font and default spacing.
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

	## Draw simple top-left aligned text with the built-in font.
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

	## Draw simple text centered on its position.
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
		DrawHost.begin_frame!()
		Draw.clear!(bg_color)
		callback()
		DrawHost.end_frame!()
	}
}

blend_mode_code : Draw.BlendMode -> U8
blend_mode_code = |mode|
	match mode {
		Alpha => 0
		Additive => 1
		Multiplied => 2
		AddColors => 3
		SubtractColors => 4
		AlphaPremultiply => 5
	}

test_texture = AssetsHost.Texture.from_resource(Box.box({ handle: 1, width: 8, height: 4 }))

expect (TextureDrawBuilder.run(TextureDrawBuilder.empty, test_texture)).source == Math.rect(0, 0, 8, 4)
expect (TextureDrawBuilder.run(TextureDrawBuilder.scale(2), test_texture)).dest == Math.rect(0, 0, 16, 8)
expect (TextureDrawBuilder.run(TextureDrawBuilder.origin_center, test_texture)).origin == { x: 4, y: 2 }
expect Draw.align_factor(Draw.align_top_left) == { x: 0, y: 0 }
expect Draw.align_factor(Draw.align_center) == { x: 0.5, y: 0.5 }
expect Draw.align_factor(Draw.align_bottom_right) == { x: 1, y: 1 }
expect blend_mode_code(Draw.alpha_blend) == 0
expect blend_mode_code(Draw.premultiplied_alpha_blend) == 5
expect Draw.render_texture_source(DrawHost.RenderTexture.from_texture(AssetsHost.Texture.from_resource(Box.box({ handle: 7, width: 320, height: 180 })))) == Math.rect(0, 0, 320, -180)
