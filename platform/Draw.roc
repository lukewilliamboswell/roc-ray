## Immediate-mode 2D drawing, text, textures, cameras, and render effects.
##
## `render!` is handed a `Frame`, and everything drawn is drawn through it:
##
## ```roc
## render! = |model, frame| {
##     frame.clear!(Color.from_hex_rgb(0x0d1425))
##     draw = App.effects().render(frame)
##     draw.rectangle!({ x: 40, y: 40, width: 200, height: 90, style: Draw.filled(Color.white) })
##     draw.circle!({ center: model.pointer, radius: 18, style: Draw.outlined(Color.red, 3) })
##     Ok({})
## }
## ```
##
## `Frame` is render-scoped authority. Pass the callback's frame through draw
## helpers; do not retain it in the model. Nested camera, shader, scissor,
## render-texture, and blend scopes restore their outer state even when their
## callback returns `Err`.
##
## Reusable packages normally accept the companion package's canonical drawing
## handle. Applications obtain it without a direct package dependency:
##
## ```roc
## draw = App.effects().render(frame)
## Widgets.draw!(draw, model.widgets)
## ```
##
## The primitives on `Frame` remain available for application-specific or
## alternative package APIs.
##
## Every effect that takes a `Frame` is legal only in `render!`. Resource
## constructors `default_font!`, `font_from_bytes!`,
## `load_render_texture!`, `Shader.from_source!` and the `Shader.uniform_*!`
## resolvers allocate host resources from what the app already has, so they are
## legal in `init!`, `update!`, and tasks. The two
## that read files out of an asset store, `load_store_font!` and
## `Shader.from_store!`, wait instead: each is legal in `init!`, where it
## blocks startup, and in tasks, where it parks the task, and refused in
## `update!` and `render!`. Create long-lived resources in `init!` and retain
## them in the model.
##
## Package-owned drawing helpers live on `Draw.Effects`. Bind one once for the
## current frame or nested scope and pass it through rendering helpers.
##
## `Draw.text!` draws at an already-resolved top-left origin without a layout
## pass. Use `Text` for optional anchor alignment or prepared text.
import Assets
import Camera
import Color
import Host
import rrt.Font
import rrt.Drawing as RrtDrawing
import Math

Draw := [].{

	## Convert a structural RGBA value at an adapter boundary into roc-ray's color.
	from_rgba : { r : U8, g : U8, b : U8, a : U8 } -> Color.Rgba
	from_rgba = |value| Color.rgba(value.r, value.g, value.b, value.a)

	## Package-owned drawing effects bound to the current render frame.
	##
	## Obtain this with `App.effects().render(frame)` and pass it through reusable
	## drawing helpers so the bundle is configured once per scope.
	Effects : RrtDrawing.Effects

	## Opaque, zero-sized authority the host supplies only while it runs
	## `render!`.
	##
	## Holding one is what makes a draw call expressible, so drawing cannot
	## reach `init!` or `update!`. Roc does not enforce affine use or encode a
	## frame epoch, so do not retain a `Frame` in the model: pass the
	## callback's own frame down through helpers.
	Frame :: Host.DrawFrame.{
		from_host : Host.DrawFrame -> Frame
		from_host = |frame| Frame.(frame)

		## How big the surface being drawn to right now is.
		##
		## Normally this is the window's logical drawing size -- the same value
		## `Window.Snapshot.size` reports, in the same coordinate space as mouse
		## input and every drawing call. Inside `with_render_texture!` it is the
		## render target's size instead, because that is what the callback's
		## coordinates are relative to.
		##
		## This is the size of the drawing surface, so it is `F32` where
		## `Window.Snapshot.size` is `I32`: it feeds rectangles, text anchors and
		## centre points directly, and a render target's dimensions are already `F32`
		## on `Texture`. `Window.Snapshot.size` stays `I32` because it is also the
		## thing `Window.suggest_size` sets.
		##
		## Reach for this when laying something out against the surface -- a HUD in a
		## corner, a title centred across the top. Layout decisions that `update!`
		## also has to make, such as which arrangement to use or what the pointer is
		## over, belong on `input.window` where the rest of application logic can see
		## them.
		##
		## Legal in `render!` only.
		size! : Frame => FrameSize
		size! = |_frame| Host.draw_frame_size!()
	}

	## Dimensions of the surface `render!` is currently drawing to.
	FrameSize : {
		width : F32,
		height : F32,
	}

	## Host-owned GPU texture, the same type `Assets` loads and generates.
	##
	## Named here as well so drawing code can keep a texture in its model
	## without importing `Assets`; `Draw.Texture`, `Assets.Texture` and the
	## companion package's `Texture` are one type, not three.
	Texture : Assets.Texture

	## Two-dimensional vector used by drawing records.
	Vector2 : Math.Vec2

	## Axis-aligned rectangle used by drawing records.
	Rect : Math.Rect

	## Pure 2D camera settings.
	Camera2D : Camera.Camera2D

	## Optional shape fill.
	Fill : RrtDrawing.Fill

	## Optional shape outline with color and thickness.
	Stroke : RrtDrawing.Stroke

	## Combined fill and outline applied by shape helpers.
	ShapeStyle : RrtDrawing.ShapeStyle

	## Fillable geometry shared with package-defined drawing APIs.
	Geometry : RrtDrawing.Geometry

	## One solid fill or stroke applied by the low-level `shape!` primitive.
	Paint : RrtDrawing.Paint

	## Axis-aligned rectangle and its style.
	Rectangle : RrtDrawing.Rectangle

	## Rounded rectangle; radius and segment count control corner tessellation.
	RoundedRectangle : RrtDrawing.RoundedRectangle

	## Vertical rectangle gradient from top to bottom.
	RectangleGradientV : RrtDrawing.RectangleGradientV

	## Horizontal rectangle gradient from left to right.
	RectangleGradientH : RrtDrawing.RectangleGradientH

	## Circle and its style.
	Circle : RrtDrawing.Circle

	## Radial gradient from inner to outer color.
	CircleGradient : RrtDrawing.CircleGradient

	## Line segment and stroke.
	Line : RrtDrawing.Line

	## Triangle vertices and style.
	Triangle : RrtDrawing.Triangle

	## A simple convex polygon. Points must be ordered around the boundary (clockwise
	## or counter-clockwise). Filled concave or self-intersecting polygons are not
	## supported; outlines accept any ordered point path.
	ConvexPolygon : RrtDrawing.ConvexPolygon

	## Deprecated: use `ConvexPolygon`.
	##
	## The same type under its older name. `ConvexPolygon` says the constraint
	## the host relies on, so it is visible at the call site.
	Polygon : RrtDrawing.Polygon

	## Position, size, and color for the FPS counter.
	Fps : RrtDrawing.Fps

	## Scalar metrics for one glyph, shared with platform-independent packages.
	GlyphMetrics : Font.GlyphMetrics

	## Text measurement result.
	TextSize : Font.Size

	## Fully configured text draw at a resolved top-left origin.
	Text : {
		pos : Vector2,
		text : Str,
		size : F32,
		spacing : F32,
		color : Color.Rgba,
		font : Font,
	}

	## Built-in-font text intended for quick diagnostics.
	DebugText : RrtDrawing.DebugText

	## Built-in-font text with default spacing.
	SimpleText : RrtDrawing.SimpleText

	## Font path and base pixel size.
	LoadFont : {
		path : Str,
		size : I32,
	}

	## Resolved texture draw configuration: which texture, which part of it,
	## where it goes, and how it is rotated and tinted.
	##
	## `TextureDrawConfig` in the signature is the module-private record this
	## aliases; `Draw.TextureDraw` is the name to write. Build one with
	## `texture_draw`, `texture_at`, or the `TextureDrawBuilder` combinators.
	TextureDraw : RrtDrawing.TextureDraw

	## One instance of a batched texture draw. These are the fields of
	## `TextureDraw` minus the texture, which the batch supplies once.
	##
	## `TextureInstanceConfig` in the signature is the module-private record
	## this aliases; `Draw.TextureInstance` is the name to write.
	TextureInstance : RrtDrawing.TextureInstance

	TextureDrawOptions : RrtDrawing.TextureDrawOptions
	TextureDrawBuilder(field) : RrtDrawing.TextureDrawBuilder(field)

	## Four ordered corners of a projected planar surface.
	ProjectiveQuadCorners : RrtDrawing.ProjectiveQuadCorners
	ProjectiveQuadFields : RrtDrawing.ProjectiveQuadFields
	ProjectiveQuad : RrtDrawing.ProjectiveQuad

	## Texture and source region projected exactly onto a validated planar quad.
	ProjectiveTexture : RrtDrawing.ProjectiveTexture

	## Sampled texture view projected exactly onto a validated planar quad.
	ProjectiveTextureView : RrtDrawing.ProjectiveTextureView

	## Camera accepted by scoped 2D drawing.
	CameraMode : Camera2D

	## Host-owned framebuffer. Its texture-shaped box has a distinct host kind;
	## the host rejects ordinary textures before entering an offscreen scope.
	## Releasing the final reference unloads the framebuffer and both attachments.
	RenderTexture :: Host.TextureRenderTarget.{

		## Allocate an offscreen framebuffer.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		load! : RenderTextureSize => Try(RenderTexture, [RenderTextureLoadFailed, ResourceLimit, ..])
		load! = |size| {
			result = Host.texture_load_render_target!(size)
			if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(RenderTextureLoadFailed) else Ok(RenderTexture.(result.target))
		}

		## Read-only view of this render target's color attachment.
		texture : RenderTexture -> Texture
		texture = |RenderTexture.(target)| target

		## Vertically inverted full-source rectangle for drawing the color attachment.
		source : RenderTexture -> Math.Rect
		source = |target| {
			view = target.texture()
			{ x: 0, y: 0, width: view.width, height: 0 - view.height }
		}

		## Resource-free render target for pure tests.
		##
		## The handle never resolves to a host resource, so entering a scope with
		## it is refused the way a released target is. Its color attachment is
		## the package's `Texture.stub` with zero dimensions; copy it with the
		## dimensions
		## the test needs. Do not use it to test drawing, offscreen scopes, or
		## resource lifetime.
		stub : RenderTexture
		stub = RenderTexture.(Texture.stub)

		## Internal bridge for capture operations that use a render target.
		for_host : RenderTexture -> Host.TextureRenderTarget
		for_host = |RenderTexture.(target)| target
	}

	## Pixel dimensions for a new offscreen render target.
	RenderTextureSize : {
		width : I32,
		height : I32,
	}

	## Host-owned GPU shader. Empty vertex/fragment strings select raylib's default
	## stage. Keep this value alive for every cached Uniform derived from it.
	Shader :: Host.Shader.{

		## Compile shader stages from source strings.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		from_source! : LoadShaderSource => Try(Shader, [ShaderLoadFailed, ResourceLimit, ..])
		from_source! = |cfg| {
			result = Host.shader_load_source!(cfg)
			if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(ShaderLoadFailed) else Ok(Shader.(result.shader))
		}

		## Compile shader stage files resolved through an explicit asset store.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it
		## parks the task; refused in `update!` and `render!`. The sources are
		## read off the frame thread and compiled when the bytes are back. To
		## compile from `update!`, use `from_source!` with strings the app
		## already holds.
		from_store! : Assets.Store, LoadShader => Try(Shader, [PathInvalid, NotFound, ReadFailed, ShaderLoadFailed, ResourceLimit, ..])
		from_store! = |store, cfg| {
			result = Host.shader_load_store!({ store: store.for_host(), vertex_path: cfg.vertex_path, fragment_path: cfg.fragment_path })
			if result.err == 1 {
				Err(PathInvalid)
			} else if result.err == 2 {
				Err(NotFound)
			} else if result.err == 3 {
				Err(ReadFailed)
			} else if result.err == 4 {
				Err(ShaderLoadFailed)
			} else if result.err != 0 {
				Err(ResourceLimit)
			} else {
				Ok(Shader.(result.shader))
			}
		}

		## Resolve a scalar floating-point uniform once.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`. Resolving a
		## uniform is a lookup against the compiled program, so it belongs beside the
		## load. Setting one is the opposite: `set!` on the resolved handle is legal
		## in `render!` only.
		uniform_f32! : Shader, Str => Try(F32Uniform, [UniformNotFound, ..])
		uniform_f32! = |Shader.(shader), name| Ok(F32Uniform.(uniform_host!(shader, name)?))

		## Resolve a scalar integer uniform once. Same phases as `uniform_f32!`.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		uniform_i32! : Shader, Str => Try(I32Uniform, [UniformNotFound, ..])
		uniform_i32! = |Shader.(shader), name| Ok(I32Uniform.(uniform_host!(shader, name)?))

		## Resolve a two-component vector uniform once. Same phases as
		## `uniform_f32!`.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		uniform_vec2! : Shader, Str => Try(Vec2Uniform, [UniformNotFound, ..])
		uniform_vec2! = |Shader.(shader), name| Ok(Vec2Uniform.(uniform_host!(shader, name)?))

		## Resolve a three-component vector uniform once. Same phases as
		## `uniform_f32!`.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		uniform_vec3! : Shader, Str => Try(Vec3Uniform, [UniformNotFound, ..])
		uniform_vec3! = |Shader.(shader), name| Ok(Vec3Uniform.(uniform_host!(shader, name)?))

		## Resolve a four-component vector uniform once. Same phases as
		## `uniform_f32!`.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		uniform_vec4! : Shader, Str => Try(Vec4Uniform, [UniformNotFound, ..])
		uniform_vec4! = |Shader.(shader), name| Ok(Vec4Uniform.(uniform_host!(shader, name)?))

		## Resolve a color-valued vec4 uniform once. Same phases as `uniform_f32!`.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		uniform_color! : Shader, Str => Try(ColorUniform, [UniformNotFound, ..])
		uniform_color! = |Shader.(shader), name| Ok(ColorUniform.(uniform_host!(shader, name)?))

		## Resolve a sampled-texture uniform once. Same phases as `uniform_f32!`.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		uniform_texture! : Shader, Str => Try(TextureUniform, [UniformNotFound, ..])
		uniform_texture! = |Shader.(shader), name| Ok(TextureUniform.(uniform_host!(shader, name)?))

		## Resource-free shader value for pure tests.
		##
		## The handle never resolves to a host resource, so entering a scope with
		## it is refused the way a released shader is, and setting a uniform
		## derived from it does nothing. Put it in a model to reach the app's
		## real `update!` from an `expect`. Do not use it to test compilation,
		## uniforms, or resource lifetime.
		stub : Shader
		stub = Shader.(Box.box(U64.highest))
	}

	## Store-relative shader stage names. An empty path selects raylib's default
	## stage; non-empty paths are resolved only through `Shader.from_store!`.
	LoadShader : {
		vertex_path : Str,
		fragment_path : Str,
	}

	## Shader stages as GLSL source strings rather than store paths, for
	## `Shader.from_source!`. An empty string selects raylib's default stage,
	## which is what a fragment-only 2D post-processing effect wants.
	LoadShaderSource : {
		vertex_source : Str,
		fragment_source : Str,
	}

	## Which font file format `FontBytes` carries. The bytes are decoded by
	## format rather than by sniffing them, so a mislabelled file fails to load
	## instead of loading as something else.
	FontFormat := [Ttf, Otf]

	## An authored font embedded with a compile-time file import, plus the pixel
	## size to rasterize its glyph atlas at. `size` is baked into the atlas, so
	## drawing at a much larger size scales that atlas up rather than
	## re-rasterizing; load the font again at the size you need instead.
	FontBytes : { format : FontFormat, bytes : List(U8), size : I32 }

	## A resolved `F32` uniform location, from `Shader.uniform_f32!`.
	##
	## The typed uniform handles are zero-cost nominal wrappers over the cached
	## host location plus its owning shader. Their distinct types prevent using
	## the wrong setter without adding a tag, allocation, or host lookup.
	F32Uniform :: Host.ShaderUniform.{

		## Send a scalar float to this uniform for the draws that follow.
		##
		## Legal in `render!` only.
		set! : F32Uniform, F32 => {}
		set! = |F32Uniform.(uniform), value| Host.shader_set_float!({ uniform, value })
	}

	## A resolved `I32` uniform location, from `Shader.uniform_i32!`.
	I32Uniform :: Host.ShaderUniform.{

		## Send a scalar integer to this uniform for the draws that follow.
		##
		## Legal in `render!` only.
		set! : I32Uniform, I32 => {}
		set! = |I32Uniform.(uniform), value| Host.shader_set_int!({ uniform, value })
	}

	## A resolved two-component uniform location, from `Shader.uniform_vec2!`.
	Vec2Uniform :: Host.ShaderUniform.{

		## Send a two-component vector to this uniform for the draws that follow.
		##
		## Legal in `render!` only.
		set! : Vec2Uniform, Vector2 => {}
		set! = |Vec2Uniform.(uniform), value| Host.shader_set_vec2!({ uniform, value })
	}

	## A resolved `Vec3` uniform location, from `Shader.uniform_vec3!`.
	Vec3Uniform :: Host.ShaderUniform.{

		## Send a three-component vector to this uniform for the draws that follow.
		##
		## Legal in `render!` only.
		set! : Vec3Uniform, Vec3 => {}
		set! = |Vec3Uniform.(uniform), value| Host.shader_set_vec3!({ uniform, value })
	}

	## A resolved `Vec4` uniform location, from `Shader.uniform_vec4!`.
	Vec4Uniform :: Host.ShaderUniform.{

		## Send a four-component vector to this uniform for the draws that follow.
		##
		## Legal in `render!` only.
		set! : Vec4Uniform, Vec4 => {}
		set! = |Vec4Uniform.(uniform), value| Host.shader_set_vec4!({ uniform, value })
	}

	## A resolved color uniform location, from `Shader.uniform_color!`. GLSL has
	## no color type, so this is a `vec4` whose components the setter normalizes
	## from the 0-to-255 bytes of an `Rgba` to the 0-to-1 floats a shader reads.
	ColorUniform :: Host.ShaderUniform.{

		## Send a color to this uniform for the draws that follow, normalized to
		## the 0-to-1 range GLSL uses.
		##
		## Legal in `render!` only.
		set! : ColorUniform, Color.Rgba => {}
		set! = |ColorUniform.(uniform), color| Host.shader_set_vec4!({
			uniform,
			value: normalized_color(color),
		})
	}

	TextureUniform :: Host.ShaderUniform.{

		## Bind any sampled texture view, including a render-target attachment.
		##
		## Legal in `render!` only.
		##
		## This is the one to reach for. `set_texture!` is the same call named
		## for the ordinary case, and exists only because binding a plain
		## texture is what most shaders want and `set!` does not say so.
		set! : TextureUniform, Texture => {}
		set! = |TextureUniform.(uniform), texture| Host.shader_set_texture!({
			uniform,
			texture,
		})

		## Bind an ordinary texture, as `set!` does. Prefer `set!`, which also
		## accepts a render-target attachment; this spelling reads better when
		## the value at hand is plainly a texture.
		##
		## Legal in `render!` only.
		set_texture! : TextureUniform, Texture => {}
		set_texture! = |uniform, texture| uniform.set!(texture)
	}

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

	## A scoped renderer could not be opened because its bounded native stack is
	## full or a transferred host resource no longer resolves.
	ScopeError : [ScopeLimit, ScopeUnavailable]

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
	filled : Color.Rgba -> ShapeStyle
	filled = RrtDrawing.filled

	## Create a stroke with color and thickness in logical pixels.
	stroke : Color.Rgba, F32 -> Stroke
	stroke = RrtDrawing.stroke

	## Create a stroke-only shape style.
	outlined : Color.Rgba, F32 -> ShapeStyle
	outlined = RrtDrawing.outlined

	## Create a shape style with both fill and outline.
	filled_and_outlined : Color.Rgba, Color.Rgba, F32 -> ShapeStyle
	filled_and_outlined = RrtDrawing.filled_and_outlined

	## Snapshot raylib's built-in font, metrics included.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	default_font! : () => Font
	default_font! = || font_from_host!(Host.text_default_font!())

	## Default text glyph spacing in logical pixels.
	default_spacing : F32
	default_spacing = RrtDrawing.default_spacing

	## Find the top-left position that centers measured text in a rectangle.
	center_in_rect : Rectangle, TextSize -> Vector2
	center_in_rect = RrtDrawing.center_in_rect

	## Clear the active drawing target to a solid color.
	##
	## Legal in `render!` only.
	clear! : Frame, Color.Rgba => {}
	clear! = |_frame, color| Host.draw_clear!(color)

	## Apply one solid fill or stroke to a supported geometry.
	##
	## This is the flexible low-level shape operation used by package-defined
	## drawing APIs. It selects an existing hosted primitive, so it adds no host
	## ABI operation and preserves one hosted call per paint.
	##
	## Legal in `render!` only.
	shape! : Frame, Geometry, Paint => {}
	shape! = |_frame, geometry, paint|
		match geometry {
			Rectangle(bounds) =>
				match paint {
					SolidFill(color) => Host.draw_rectangle!({
						x: bounds.x,
						y: bounds.y,
						width: bounds.width,
						height: bounds.height,
						color,
					})
					SolidStroke(stroke_cfg) => Host.draw_rectangle_lines!({
						x: bounds.x,
						y: bounds.y,
						width: bounds.width,
						height: bounds.height,
						color: stroke_cfg.color,
						thickness: stroke_cfg.thickness,
					})
				}

			RoundedRectangle(cfg) =>
				match paint {
					SolidFill(color) => Host.draw_rounded_rectangle!({
						x: cfg.bounds.x,
						y: cfg.bounds.y,
						width: cfg.bounds.width,
						height: cfg.bounds.height,
						radius: cfg.radius,
						segments: cfg.segments,
						color,
					})
					SolidStroke(stroke_cfg) => Host.draw_rounded_rectangle_lines!({
						x: cfg.bounds.x,
						y: cfg.bounds.y,
						width: cfg.bounds.width,
						height: cfg.bounds.height,
						radius: cfg.radius,
						segments: cfg.segments,
						color: stroke_cfg.color,
						thickness: stroke_cfg.thickness,
					})
				}

			Circle(cfg) =>
				match paint {
					SolidFill(color) => Host.draw_circle!({ center: cfg.center, radius: cfg.radius, color })
					SolidStroke(stroke_cfg) => Host.draw_circle_lines!({
						center: cfg.center,
						radius: cfg.radius,
						color: stroke_cfg.color,
						thickness: stroke_cfg.thickness,
					})
				}

			Triangle(cfg) =>
				match paint {
					SolidFill(color) => Host.draw_triangle!({ a: cfg.a, b: cfg.b, c: cfg.c, color })
					SolidStroke(stroke_cfg) => Host.draw_triangle_lines!({
						a: cfg.a,
						b: cfg.b,
						c: cfg.c,
						color: stroke_cfg.color,
						thickness: stroke_cfg.thickness,
					})
				}

			ConvexPolygon(points) =>
				match paint {
					SolidFill(color) => Host.draw_polygon!({ points, color })
					SolidStroke(stroke_cfg) => Host.draw_polygon_lines!({
						points,
						color: stroke_cfg.color,
						thickness: stroke_cfg.thickness,
					})
				}
			}

	## Draw a vertical rectangle gradient.
	##
	## Legal in `render!` only.
	rectangle_gradient_v! : Frame, RectangleGradientV => {}
	rectangle_gradient_v! = |frame, cfg| package_effects(frame).rectangle_gradient_v!(cfg)

	## Draw a horizontal rectangle gradient.
	##
	## Legal in `render!` only.
	rectangle_gradient_h! : Frame, RectangleGradientH => {}
	rectangle_gradient_h! = |frame, cfg| package_effects(frame).rectangle_gradient_h!(cfg)

	## Draw a radial circle gradient.
	##
	## Legal in `render!` only.
	circle_gradient! : Frame, CircleGradient => {}
	circle_gradient! = |frame, cfg| package_effects(frame).circle_gradient!(cfg)

	## Draw raylib's current frames-per-second counter.
	##
	## Legal in `render!` only.
	fps! : Frame, Fps => {}
	fps! = |frame, cfg| package_effects(frame).fps!(cfg)

	## Draw a filled and/or outlined axis-aligned rectangle.
	##
	## Legal in `render!` only.
	rectangle! : Frame, Rectangle => {}
	rectangle! = |frame, cfg| package_effects(frame).rectangle!(cfg)

	## Draw a filled and/or outlined rounded rectangle.
	##
	## Legal in `render!` only.
	rounded_rectangle! : Frame, RoundedRectangle => {}
	rounded_rectangle! = |frame, cfg| package_effects(frame).rounded_rectangle!(cfg)

	## Draw a filled and/or outlined circle.
	##
	## Legal in `render!` only.
	circle! : Frame, Circle => {}
	circle! = |frame, cfg| package_effects(frame).circle!(cfg)

	## Draw a stroked line segment. `NoStroke` performs no drawing.
	##
	## Legal in `render!` only.
	line! : Frame, Line => {}
	line! = |frame, cfg| package_effects(frame).line!(cfg)

	## Draw a filled and/or outlined triangle.
	##
	## Legal in `render!` only.
	triangle! : Frame, Triangle => {}
	triangle! = |frame, cfg| package_effects(frame).triangle!(cfg)

	## Deprecated: use `convex_polygon!`.
	##
	## Legal in `render!` only.
	polygon! : Frame, Polygon => {}
	polygon! = |frame, cfg| package_effects(frame).polygon!(cfg)

	## Draw a convex filled polygon and/or an ordered polygon outline. The host
	## triangulates the fill without allocating; fewer than three points do not
	## fill.
	##
	## Legal in `render!` only.
	convex_polygon! : Frame, ConvexPolygon => {}
	convex_polygon! = |frame, cfg| package_effects(frame).convex_polygon!(cfg)

	## Load a font relative to an explicit asset store.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`. The file is read off the
	## frame thread and rasterized when the bytes are back. To load a font from
	## `update!`, use `font_from_bytes!` with bytes the app already holds.
	load_store_font! : Assets.Store, LoadFont => Try(Font, [PathInvalid, NotFound, ReadFailed, FontLoadFailed, ResourceLimit, ..])
	load_store_font! = |store, cfg| {
		result = Host.text_load_store_font!({ store: store.for_host(), path: cfg.path, size: cfg.size })
		if result.err == 1 {
			Err(PathInvalid)
		} else if result.err == 2 {
			Err(NotFound)
		} else if result.err == 3 {
			Err(ReadFailed)
		} else if result.err == 4 {
			Err(FontLoadFailed)
		} else if result.err != 0 {
			Err(ResourceLimit)
		} else {
			Ok(font_from_host!(result.font))
		}
	}

	## Decode an authored, compile-time embedded font.
	##
	## The bytes are borrowed while raylib copies and decodes them, so no extra
	## Roc payload-sized buffer is created. Legal in `init!`, `update!`, and
	## tasks; refused in `render!`.
	font_from_bytes! : FontBytes => Try(Font, [FontLoadFailed, ResourceLimit, ..])
	font_from_bytes! = |cfg| {
		result = Host.text_load_font_bytes!({ format: font_format_code(cfg.format), bytes: cfg.bytes, size: cfg.size })
		if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(FontLoadFailed) else Ok(font_from_host!(result.font))
	}

	## Create a draw configuration covering the whole texture at the origin.
	texture_draw : Texture -> TextureDraw
	texture_draw = |texture| RrtDrawing.texture_draw(texture)

	## Create a draw configuration covering the whole texture at `pos`.
	texture_at : Texture, Math.Vec2 -> TextureDraw
	texture_at = |texture, pos| RrtDrawing.texture_at(texture, pos)

	## Create a draw configuration covering a read-only sampled view.
	texture_view_draw : Texture -> TextureDraw
	texture_view_draw = |texture| RrtDrawing.texture_view_draw(texture)

	## Create a sampled-view draw configuration at `pos`.
	texture_view_at : Texture, Math.Vec2 -> TextureDraw
	texture_view_at = |texture, pos| RrtDrawing.texture_view_at(texture, pos)

	## Draw a texture with explicit source, destination, origin, rotation, and
	## tint.
	##
	## Legal in `render!` only.
	texture! : Frame, TextureDraw => {}
	texture! = |frame, cfg| package_effects(frame).texture!(cfg)

	## Deprecated: use `texture!`.
	##
	## Legal in `render!` only.
	draw_texture! : Frame, TextureDraw => {}
	draw_texture! = |frame, cfg| frame.texture!(cfg)

	## Draw many instances of one texture, in list order, with a single hosted
	## call.
	##
	## `texture!` crosses the Roc/host boundary once per sprite, and that crossing
	## is what caps how many sprites a frame can afford. This crosses once for the
	## whole batch and lets the host loop over it, so the cost per instance is the
	## `DrawTexturePro` call alone. Build the list from application state and pass
	## it straight through; an empty list does not cross at all.
	##
	## Legal in `render!` only.
	texture_instances! : Frame, Texture, List(TextureInstance) => {}
	texture_instances! = |frame, texture, instances| package_effects(frame).texture_instances!(texture, instances)

	## Project a texture onto a validated planar quad with exact homogeneous UV
	## interpolation. This remains one hosted call and preserves active shaders.
	##
	## Legal in `render!` only.
	projective_texture! : Frame, ProjectiveTexture => {}
	projective_texture! = |frame, cfg| package_effects(frame).projective_texture!(cfg)

	## Project a sampled texture view onto a validated planar quad.
	##
	## Legal in `render!` only.
	projective_texture_view! : Frame, ProjectiveTextureView => {}
	projective_texture_view! = |frame, cfg| package_effects(frame).projective_texture_view!(cfg)

	## Allocate an offscreen framebuffer.
	##
	## Creation allocates GPU resources and one fixed host-heap slot, so do it
	## in `init!` rather than per frame. Legal in `init!`, `update!`, and
	## tasks; refused in `render!`.
	load_render_texture! : RenderTextureSize => Try(RenderTexture, [RenderTextureLoadFailed, ResourceLimit, ..])
	load_render_texture! = |size| RenderTexture.load!(size)

	## View the color attachment as a sampled texture without allocating or copying.
	## The returned reference keeps the owning framebuffer alive.
	render_texture : RenderTexture -> Texture
	render_texture = |target| target.texture()

	## The source rectangle that samples a render target's colour attachment.
	##
	## Its height is negative. Render textures use OpenGL framebuffer
	## coordinates, so the attachment is vertically inverted when sampled on
	## screen, and a negative-height source is how a draw flips it back.
	render_texture_source : RenderTexture -> Math.Rect
	render_texture_source = |target| target.source()

	## Compile shader stages from source strings. Empty strings select the default
	## stage, which is useful for fragment-only 2D post-processing.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	load_shader_source! : LoadShaderSource => Try(Shader, [ShaderLoadFailed, ResourceLimit, ..])
	load_shader_source! = |cfg| Shader.from_source!(cfg)

	## Scope offscreen rendering so BeginTextureMode/EndTextureMode stay paired.
	## Callback errors are returned only after the native target has been
	## restored.
	##
	## Legal in `render!` only.
	with_render_texture! : Frame, RenderTexture, (Frame => Try(result, [ScopeLimit, ScopeUnavailable, ..errors])) => Try(result, [ScopeLimit, ScopeUnavailable, ..errors])
	with_render_texture! = |frame, RenderTexture.(target), callback| {
		status = Host.draw_begin_render_texture!(target)
		if status == scope_ok {
			result = callback(frame)
			Host.draw_end_render_texture!()
			result
		} else if status == scope_limit {
			Err(ScopeLimit)
		} else {
			Err(ScopeUnavailable)
		}
	}

	## Scope shader application so the default shader is always restored. Callback
	## errors are returned only after the previous shader has been restored.
	##
	## Legal in `render!` only.
	with_shader! : Frame, Shader, (Frame => Try(result, [ScopeLimit, ScopeUnavailable, ..errors])) => Try(result, [ScopeLimit, ScopeUnavailable, ..errors])
	with_shader! = |frame, Shader.(shader), callback| {
		status = Host.draw_begin_shader!(shader)
		if status == scope_ok {
			result = callback(frame)
			Host.draw_end_shader!()
			result
		} else if status == scope_limit {
			Err(ScopeLimit)
		} else {
			Err(ScopeUnavailable)
		}
	}

	## Scope one of raylib's built-in blend equations. Custom blend factors are
	## deliberately excluded until they can be represented without global state.
	##
	## Legal in `render!` only.
	with_blend_mode! : Frame, BlendMode, (Frame => Try(result, [ScopeLimit, ..errors])) => Try(result, [ScopeLimit, ..errors])
	with_blend_mode! = |frame, mode, callback| {
		status = Host.draw_begin_blend!(blend_mode_code(mode))
		if status == scope_ok {
			result = callback(frame)
			Host.draw_end_blend!()
			result
		} else if status == scope_limit {
			Err(ScopeLimit)
		} else {
			crash "blend scope host invariant failed"
		}
	}

	## Draw the callback in world space using this camera.
	##
	## Legal in `render!` only.
	with_camera! : Frame, CameraMode, (Frame => Try(result, [ScopeLimit, ..errors])) => Try(result, [ScopeLimit, ..errors])
	with_camera! = |frame, camera, callback| {
		status = Host.draw_begin_camera!(camera)
		if status == scope_ok {
			result = callback(frame)
			Host.draw_end_camera!()
			result
		} else if status == scope_limit {
			Err(ScopeLimit)
		} else {
			crash "camera scope host invariant failed"
		}
	}

	## Deprecated: use `with_camera!`.
	##
	## Legal in `render!` only.
	with_mode_2d! : Frame, CameraMode, (Frame => Try(result, [ScopeLimit, ..errors])) => Try(result, [ScopeLimit, ..errors])
	with_mode_2d! = |frame, camera, callback| frame.with_camera!(camera, callback)

	## Restrict callback drawing to screen-space `bounds`, and close the scissor
	## however the callback ends, error included.
	##
	## `bounds` is in the same logical coordinates as every other drawing call,
	## so it is a rectangle on the surface rather than in framebuffer pixels.
	##
	## Legal in `render!` only.
	with_scissor! : Frame, Math.Rect, (Frame => Try(result, [ScopeLimit, ..errors])) => Try(result, [ScopeLimit, ..errors])
	with_scissor! = |frame, bounds, callback| {
		# Reconstruct the internal transport record at the hosted boundary. Keeping
		# this annotation explicit prevents the compiler from specializing the
		# extern with Math.Rect's public ability-bearing alias.
		scissor : Host.DrawScissor
		scissor = { x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height }
		status = Host.draw_begin_scissor!(scissor)
		if status == scope_ok {
			result = callback(frame)
			Host.draw_end_scissor!()
			result
		} else if status == scope_limit {
			Err(ScopeLimit)
		} else {
			crash "scissor scope host invariant failed"
		}
	}

	## Draw text using an explicit font, spacing, color, and resolved top-left
	## origin. This performs no measurement or alignment pass.
	##
	## Legal in `render!` only.
	text! : Frame, Text => {}
	text! = |_frame, cfg|
		Host.draw_text!({
			pos: cfg.pos,
			text: cfg.text,
			size: cfg.size,
			spacing: cfg.spacing,
			color: cfg.color,
			font: cfg.font.handle,
		})

	## Draw top-left aligned text with the built-in font and default spacing.
	##
	## Legal in `render!` only.
	debug_text! : Frame, DebugText => {}
	debug_text! = |frame, cfg| package_effects(frame).debug_text!(cfg)

	## Draw simple top-left aligned text with the built-in font.
	##
	## Legal in `render!` only.
	text_at! : Frame, SimpleText => {}
	text_at! = |frame, cfg| package_effects(frame).text_at!(cfg)

}

## Adapt the platform's irreducible frame operations to the companion
## package's canonical drawing composition. Construction is pure; the eventual
## leaf call still reaches the same hosted operation and phase check.
PackageDrawingProvider :: {}.{
	new : {} -> PackageDrawingProvider
	new = |{}| PackageDrawingProvider.({})

	shape! : PackageDrawingProvider, Draw.Frame, Draw.Geometry, Draw.Paint => {}
	shape! = |_provider, frame, geometry, paint| frame.shape!(geometry, paint)

	draw_text! : PackageDrawingProvider, Draw.Frame, Draw.Text => {}
	draw_text! = |_provider, frame, text| frame.text!(text)

	rectangle_gradient_v! : PackageDrawingProvider, Draw.Frame, Draw.RectangleGradientV => {}
	rectangle_gradient_v! = |_provider, _frame, cfg| Host.draw_rectangle_gradient_v!(cfg)

	rectangle_gradient_h! : PackageDrawingProvider, Draw.Frame, Draw.RectangleGradientH => {}
	rectangle_gradient_h! = |_provider, _frame, cfg| Host.draw_rectangle_gradient_h!(cfg)

	circle_gradient! : PackageDrawingProvider, Draw.Frame, Draw.CircleGradient => {}
	circle_gradient! = |_provider, _frame, cfg| Host.draw_circle_gradient!(cfg)

	fps! : PackageDrawingProvider, Draw.Frame, Draw.Fps => {}
	fps! = |_provider, _frame, cfg| Host.draw_fps!(cfg)

	line! : PackageDrawingProvider, Draw.Frame, Draw.Line => {}
	line! = |_provider, _frame, cfg|
		match cfg.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => Host.draw_line!({ start: cfg.start, end: cfg.end, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}

	texture! : PackageDrawingProvider, Draw.Frame, Draw.TextureDraw => {}
	texture! = |_provider, _frame, cfg| Host.draw_draw_texture!(cfg)

	texture_instances! : PackageDrawingProvider, Draw.Frame, Draw.Texture, List(Draw.TextureInstance) => {}
	texture_instances! = |_provider, _frame, texture, instances| Host.draw_draw_texture_instances!({ texture, instances })

	projective_texture! : PackageDrawingProvider, Draw.Frame, Draw.ProjectiveTexture => {}
	projective_texture! = |_provider, _frame, cfg| {
		quad = cfg.quad.fields()
		Host.draw_draw_texture_quad!({
			texture: cfg.texture,
			source: cfg.source,
			top_left: quad.top_left,
			bottom_left: quad.bottom_left,
			bottom_right: quad.bottom_right,
			top_right: quad.top_right,
			q_top_left: quad.q_top_left,
			q_bottom_left: quad.q_bottom_left,
			q_bottom_right: quad.q_bottom_right,
			q_top_right: quad.q_top_right,
			tint: cfg.tint,
		})
	}

	with_scissor! : PackageDrawingProvider, Draw.Frame, Draw.Rect, (Draw.Frame => Try({}, [ScopeLimit])) => Try({}, [ScopeLimit])
	with_scissor! = |_provider, frame, bounds, callback| frame.with_scissor!(bounds, callback)
}

package_effects : Draw.Frame -> RrtDrawing.Effects
package_effects = |frame| RrtDrawing.effects_for(PackageDrawingProvider.new({}), frame)

## Take the metric snapshot a font value carries.
##
## This is the one impure step in a font's life: it asks the host for the atlas
## metrics once, when the font loads, so that every reader afterwards -- here,
## in an app, or in a package that never heard of this platform -- is pure.
## Private, because minting a live `Font` is the host's business.
font_from_host! : Font.Handle => Font
font_from_host! = |handle| {
	metrics = Host.text_font_metrics!(handle)
	{ handle, metrics }
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

font_format_code : Draw.FontFormat -> U8
font_format_code = |format|
	match format {
		Ttf => 0
		Otf => 1
	}

scope_ok : U8
scope_ok = 0

scope_limit : U8
scope_limit = 2

uniform_host! : Host.Shader, Str => Try(Host.ShaderUniform, [UniformNotFound, ..])
uniform_host! = |shader, name| {
	location = Host.shader_location!({ shader, name })
	if location < 0 {
		Err(UniformNotFound)
	} else {
		Ok({ shader, location })
	}
}

normalized_color : Color.Rgba -> Draw.Vec4
normalized_color = |color| {
	x: U8.to_f32(color.r) / 255,
	y: U8.to_f32(color.g) / 255,
	z: U8.to_f32(color.b) / 255,
	w: U8.to_f32(color.a) / 255,
}

expect blend_mode_code(Draw.alpha_blend) == 0
expect blend_mode_code(Draw.premultiplied_alpha_blend) == 5

## The resource-free stubs are pure values an app puts in a model to reach its
## own `update!` from an `expect`. What they must never do is pass for a loaded
## resource, so what is checked here is that they are inert.
##
## A `Texture`, a `Shader`, and a `RenderTexture` each hold a `Box` and cannot be
## compared -- a type reaching a host-resource box does not support equality --
## so these read the ordinary data beside the handle instead.
expect Font.stub.metrics.base_size == 1
expect Font.stub.metrics.line_spacing == 0
expect List.len(Font.stub.metrics.glyphs) == 1

## The synthetic stub measures one advance per Unicode scalar.
expect Font.measure(Font.stub, { text: "", size: 20, spacing: 1 }) == { width: 0, height: 0 }
expect Font.measure(Font.stub, { text: "inert", size: 20, spacing: 0 }) == { width: 100, height: 20 }

## A stub render target's colour attachment is the `roc-ray-types` package's
## `Texture.stub`, so it has no area and its vertically flipped source
## rectangle has none either.
expect Draw.RenderTexture.stub.texture().width == 0
expect Draw.RenderTexture.stub.texture().height == 0
expect Draw.RenderTexture.stub.source().width == 0
