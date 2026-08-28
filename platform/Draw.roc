## Immediate-mode 2D drawing, text, textures, cameras, and render effects.
##
## `render!` is handed a `Frame`, and everything drawn is drawn through it:
##
## ```roc
## render! = |model, frame| {
##     frame.clear!(Color.from_hex_rgb(0x0d1425))
##     frame.rectangle!({ x: 40, y: 40, width: 200, height: 90, style: Draw.filled(Color.white) })
##     frame.circle!({ center: model.pointer, radius: 18, style: Draw.outlined(Color.red, 3) })
##     Ok({})
## }
## ```
##
## `Frame` is render-scoped authority. Pass the callback's frame through draw
## helpers; do not retain it in the model. Nested camera, shader, scissor,
## render-texture, and blend scopes restore their outer state even when their
## callback returns `Err`.
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
## Most shapes support equivalent receiver and free-function forms, such as
## `frame.circle!(cfg)` and `Draw.circle!(frame, cfg)`.
##
## `Draw.text!` draws at an already-resolved top-left origin without a layout
## pass. Use `Text` for optional anchor alignment or prepared text.
import Assets
import Camera
import Color
import Host
import rrt.Font
import Math

TextureDrawConfig : {
	texture : Assets.Texture,
	source : Math.Rect,
	dest : Math.Rect,
	origin : Math.Vec2,
	rotation : F32,
	tint : Color.Rgba,
}

TextureInstanceConfig : {
	source : Math.Rect,
	dest : Math.Rect,
	origin : Math.Vec2,
	rotation : F32,
	tint : Color.Rgba,
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
	tint : Color.Rgba,
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
		source = if options.source_set options.source else Math.rect(0, 0, texture.width, texture.height)

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

	tint : Color.Rgba -> TextureDrawBuilder(Color.Rgba)
	tint = |value| {
		value,
		apply: |options| { ..options, tint: value },
	}
}

vec_is_finite : Math.Vec2 -> Bool
vec_is_finite = |vec| F32.is_finite(vec.x) and F32.is_finite(vec.y)

corner_cross : Math.Vec2, Math.Vec2, Math.Vec2 -> F32
corner_cross = |a, b, c| (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)

crosses_have_one_sign : F32, F32, F32, F32 -> Bool
crosses_have_one_sign = |a, b, c, d| {
	all_positive = a > 0 and b > 0 and c > 0 and d > 0
	all_negative = a < 0 and b < 0 and c < 0 and d < 0
	all_positive or all_negative
}

Draw := [].{

	## Convert a structural RGBA value at an adapter boundary into roc-ray's color.
	from_rgba : { r : U8, g : U8, b : U8, a : U8 } -> Color.Rgba
	from_rgba = |value| Color.rgba(value.r, value.g, value.b, value.a)

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
	Fill : [NoFill, Fill(Color.Rgba)]

	## Optional shape outline with color and thickness.
	Stroke : [NoStroke, Stroke({ color : Color.Rgba, thickness : F32 })]

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
		color_top : Color.Rgba,
		color_bottom : Color.Rgba,
	}

	## Horizontal rectangle gradient from left to right.
	RectangleGradientH : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		color_left : Color.Rgba,
		color_right : Color.Rgba,
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
		color_inner : Color.Rgba,
		color_outer : Color.Rgba,
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

	## Deprecated: use `ConvexPolygon`.
	##
	## The same type under its older name. `ConvexPolygon` says the constraint
	## the host relies on, so it is visible at the call site.
	Polygon : ConvexPolygon

	## Position, size, and color for the FPS counter.
	Fps : {
		pos : Vector2,
		size : F32,
		color : Color.Rgba,
	}

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
	DebugText : {
		pos : Vector2,
		text : Str,
		size : F32,
		color : Color.Rgba,
	}

	## Built-in-font text with default spacing.
	SimpleText : {
		pos : Vector2,
		text : Str,
		size : F32,
		color : Color.Rgba,
	}

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
	TextureDraw : TextureDrawConfig

	## One instance of a batched texture draw. These are the fields of
	## `TextureDraw` minus the texture, which the batch supplies once.
	##
	## `TextureInstanceConfig` in the signature is the module-private record
	## this aliases; `Draw.TextureInstance` is the name to write.
	TextureInstance : TextureInstanceConfig

	## Four ordered corners of a projected planar surface.
	ProjectiveQuadCorners : {
		top_left : Math.Vec2,
		bottom_left : Math.Vec2,
		bottom_right : Math.Vec2,
		top_right : Math.Vec2,
	}

	## A finite, convex planar projection with a bounded homography. Construct it
	## with `ProjectiveQuad.from_corners`; the opaque representation carries the
	## homogeneous weights needed for exact perspective-correct interpolation.
	ProjectiveQuad :: {
		top_left : Math.Vec2,
		bottom_left : Math.Vec2,
		bottom_right : Math.Vec2,
		top_right : Math.Vec2,
		q_top_left : F32,
		q_bottom_left : F32,
		q_bottom_right : F32,
		q_top_right : F32,
	}.{

		## Validate four boundary-ordered corners and solve their projective weights.
		## A single homography cannot represent a concave, self-intersecting, or
		## horizon-crossing destination, so those states are rejected here.
		from_corners : ProjectiveQuadCorners -> Try(ProjectiveQuad, [NonFiniteQuad, DegenerateQuad, NonConvexQuad, ProjectiveHorizon, ..])
		from_corners = |corners| {
			finite = vec_is_finite(corners.top_left)
				and vec_is_finite(corners.bottom_left)
					and vec_is_finite(corners.bottom_right)
						and vec_is_finite(corners.top_right)
			if !finite {
				Err(NonFiniteQuad)
			} else {
				cross_0 = corner_cross(corners.top_left, corners.bottom_left, corners.bottom_right)
				cross_1 = corner_cross(corners.bottom_left, corners.bottom_right, corners.top_right)
				cross_2 = corner_cross(corners.bottom_right, corners.top_right, corners.top_left)
				cross_3 = corner_cross(corners.top_right, corners.top_left, corners.bottom_left)
				if cross_0 == 0 or cross_1 == 0 or cross_2 == 0 or cross_3 == 0 {
					Err(DegenerateQuad)
				} else if !crosses_have_one_sign(cross_0, cross_1, cross_2, cross_3) {
					Err(NonConvexQuad)
				} else {
					dx_1 = corners.top_right.x - corners.bottom_right.x
					dx_2 = corners.bottom_left.x - corners.bottom_right.x
					dx_3 = corners.top_left.x - corners.top_right.x + corners.bottom_right.x - corners.bottom_left.x
					dy_1 = corners.top_right.y - corners.bottom_right.y
					dy_2 = corners.bottom_left.y - corners.bottom_right.y
					dy_3 = corners.top_left.y - corners.top_right.y + corners.bottom_right.y - corners.bottom_left.y
					denominator = dx_1 * dy_2 - dx_2 * dy_1
					if denominator == 0 {
						Err(DegenerateQuad)
					} else {
						projective_x = (dx_3 * dy_2 - dx_2 * dy_3) / denominator
						projective_y = (dx_1 * dy_3 - dx_3 * dy_1) / denominator
						q_top_left = 1
						q_top_right = 1 + projective_x
						q_bottom_left = 1 + projective_y
						q_bottom_right = 1 + projective_x + projective_y
						weights_finite = F32.is_finite(q_top_right) and F32.is_finite(q_bottom_left) and F32.is_finite(q_bottom_right)
						q_max = F32.max(q_top_left, F32.max(F32.abs(q_top_right), F32.max(F32.abs(q_bottom_left), F32.abs(q_bottom_right))))
						normalized_top_left = q_top_left / q_max
						normalized_top_right = q_top_right / q_max
						normalized_bottom_left = q_bottom_left / q_max
						normalized_bottom_right = q_bottom_right / q_max
						bounded = normalized_top_left > 0.000001
							and normalized_top_right > 0.000001
								and normalized_bottom_left > 0.000001
									and normalized_bottom_right > 0.000001
						if !weights_finite or !bounded {
							Err(ProjectiveHorizon)
						} else {
							Ok({
								top_left: corners.top_left,
								bottom_left: corners.bottom_left,
								bottom_right: corners.bottom_right,
								top_right: corners.top_right,
								q_top_left: normalized_top_left,
								q_bottom_left: normalized_bottom_left,
								q_bottom_right: normalized_bottom_right,
								q_top_right: normalized_top_right,
							})
						}
					}
				}
			}
		}

		## Project a unit-square coordinate onto the destination surface. This uses
		## the same homography as rendering and is useful for aligned overlays.
		project : ProjectiveQuad, Math.Vec2 -> Math.Vec2
		project = |quad, uv| {
			one_minus_u = 1 - uv.x
			one_minus_v = 1 - uv.y
			top_left_weight = one_minus_u * one_minus_v * quad.q_top_left
			top_right_weight = uv.x * one_minus_v * quad.q_top_right
			bottom_left_weight = one_minus_u * uv.y * quad.q_bottom_left
			bottom_right_weight = uv.x * uv.y * quad.q_bottom_right
			weight_sum = top_left_weight + top_right_weight + bottom_left_weight + bottom_right_weight
			{
				x: (quad.top_left.x * top_left_weight + quad.top_right.x * top_right_weight + quad.bottom_left.x * bottom_left_weight + quad.bottom_right.x * bottom_right_weight) / weight_sum,
				y: (quad.top_left.y * top_left_weight + quad.top_right.y * top_right_weight + quad.bottom_left.y * bottom_left_weight + quad.bottom_right.y * bottom_right_weight) / weight_sum,
			}
		}
	}

	## Texture and source region projected exactly onto a validated planar quad.
	ProjectiveTexture : {
		texture : Texture,
		source : Math.Rect,
		quad : ProjectiveQuad,
		tint : Color.Rgba,
	}

	## Sampled texture view projected exactly onto a validated planar quad.
	ProjectiveTextureView : {
		texture : Texture,
		source : Math.Rect,
		quad : ProjectiveQuad,
		tint : Color.Rgba,
	}

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
	filled = |color| { fill: Fill(color), stroke: NoStroke }

	## Create a stroke with color and thickness in logical pixels.
	stroke : Color.Rgba, F32 -> Stroke
	stroke = |color, thickness| Stroke({ color, thickness })

	## Create a stroke-only shape style.
	outlined : Color.Rgba, F32 -> ShapeStyle
	outlined = |color, thickness| { fill: NoFill, stroke: Draw.stroke(color, thickness) }

	## Create a shape style with both fill and outline.
	filled_and_outlined : Color.Rgba, Color.Rgba, F32 -> ShapeStyle
	filled_and_outlined = |fill, outline, thickness| { fill: Fill(fill), stroke: Draw.stroke(outline, thickness) }

	## Snapshot raylib's built-in font, metrics included.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	default_font! : () => Font
	default_font! = || font_from_host!(Host.text_default_font!())

	## Default text glyph spacing in logical pixels.
	default_spacing : F32
	default_spacing = 1

	## Find the top-left position that centers measured text in a rectangle.
	center_in_rect : Rectangle, TextSize -> Vector2
	center_in_rect = |rect, size| {
		{
			x: rect.x + rect.width * 0.5 - size.width * 0.5,
			y: rect.y + rect.height * 0.5 - size.height * 0.5,
		}
	}

	## Clear the active drawing target to a solid color.
	##
	## Legal in `render!` only.
	clear! : Frame, Color.Rgba => {}
	clear! = |_frame, color| Host.draw_clear!(color)

	## Draw a vertical rectangle gradient.
	##
	## Legal in `render!` only.
	rectangle_gradient_v! : Frame, RectangleGradientV => {}
	rectangle_gradient_v! = |_frame, cfg| Host.draw_rectangle_gradient_v!(cfg)

	## Draw a horizontal rectangle gradient.
	##
	## Legal in `render!` only.
	rectangle_gradient_h! : Frame, RectangleGradientH => {}
	rectangle_gradient_h! = |_frame, cfg| Host.draw_rectangle_gradient_h!(cfg)

	## Draw a radial circle gradient.
	##
	## Legal in `render!` only.
	circle_gradient! : Frame, CircleGradient => {}
	circle_gradient! = |_frame, cfg| Host.draw_circle_gradient!(cfg)

	## Draw raylib's current frames-per-second counter.
	##
	## Legal in `render!` only.
	fps! : Frame, Fps => {}
	fps! = |_frame, cfg| Host.draw_fps!(cfg)

	## Draw a filled and/or outlined axis-aligned rectangle.
	##
	## Legal in `render!` only.
	rectangle! : Frame, Rectangle => {}
	rectangle! = |_frame, cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => Host.draw_rectangle!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => Host.draw_rectangle_lines!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

	## Draw a filled and/or outlined rounded rectangle.
	##
	## Legal in `render!` only.
	rounded_rectangle! : Frame, RoundedRectangle => {}
	rounded_rectangle! = |_frame, cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => Host.draw_rounded_rectangle!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, radius: cfg.radius, segments: cfg.segments, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => Host.draw_rounded_rectangle_lines!({ x: cfg.x, y: cfg.y, width: cfg.width, height: cfg.height, radius: cfg.radius, segments: cfg.segments, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

	## Draw a filled and/or outlined circle.
	##
	## Legal in `render!` only.
	circle! : Frame, Circle => {}
	circle! = |_frame, cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => Host.draw_circle!({ center: cfg.center, radius: cfg.radius, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => Host.draw_circle_lines!({ center: cfg.center, radius: cfg.radius, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

	## Draw a stroked line segment. `NoStroke` performs no drawing.
	##
	## Legal in `render!` only.
	line! : Frame, Line => {}
	line! = |_frame, cfg|
		match cfg.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => Host.draw_line!({ start: cfg.start, end: cfg.end, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}

	## Draw a filled and/or outlined triangle.
	##
	## Legal in `render!` only.
	triangle! : Frame, Triangle => {}
	triangle! = |_frame, cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => Host.draw_triangle!({ a: cfg.a, b: cfg.b, c: cfg.c, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => Host.draw_triangle_lines!({ a: cfg.a, b: cfg.b, c: cfg.c, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

	## Deprecated: use `convex_polygon!`.
	##
	## Legal in `render!` only.
	polygon! : Frame, Polygon => {}
	polygon! = |frame, cfg| frame.convex_polygon!(cfg)

	## Draw a convex filled polygon and/or an ordered polygon outline. The host
	## triangulates the fill without allocating; fewer than three points do not
	## fill.
	##
	## Legal in `render!` only.
	convex_polygon! : Frame, ConvexPolygon => {}
	convex_polygon! = |_frame, cfg| {
		match cfg.style.fill {
			NoFill => {}
			Fill(color) => Host.draw_polygon!({ points: cfg.points, color })
		}

		match cfg.style.stroke {
			NoStroke => {}
			Stroke(stroke_cfg) => Host.draw_polygon_lines!({ points: cfg.points, color: stroke_cfg.color, thickness: stroke_cfg.thickness })
		}
	}

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
	texture_draw = |texture| TextureDrawBuilder.run(TextureDrawBuilder.empty, texture)

	## Create a draw configuration covering the whole texture at `pos`.
	texture_at : Texture, Math.Vec2 -> TextureDraw
	texture_at = |texture, pos| TextureDrawBuilder.run(TextureDrawBuilder.pos(pos), texture)

	## Create a draw configuration covering a read-only sampled view.
	texture_view_draw : Texture -> TextureDraw
	texture_view_draw = |texture| TextureDrawBuilder.run(TextureDrawBuilder.empty, texture)

	## Create a sampled-view draw configuration at `pos`.
	texture_view_at : Texture, Math.Vec2 -> TextureDraw
	texture_view_at = |texture, pos| TextureDrawBuilder.run(TextureDrawBuilder.pos(pos), texture)

	## Draw a texture with explicit source, destination, origin, rotation, and
	## tint.
	##
	## Legal in `render!` only.
	texture! : Frame, TextureDraw => {}
	texture! = |_frame, cfg| {
		Host.draw_draw_texture!({
			texture: cfg.texture,
			source: cfg.source,
			dest: cfg.dest,
			origin: cfg.origin,
			rotation: cfg.rotation,
			tint: cfg.tint,
		})
	}

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
	texture_instances! = |_frame, texture, instances| {
		if List.len(instances) == 0 {
			{}
		} else {
			Host.draw_draw_texture_instances!({ texture, instances })
		}
	}

	## Project a texture onto a validated planar quad with exact homogeneous UV
	## interpolation. This remains one hosted call and preserves active shaders.
	##
	## Legal in `render!` only.
	projective_texture! : Frame, ProjectiveTexture => {}
	projective_texture! = |_frame, cfg| Host.draw_draw_texture_quad!({
		texture: cfg.texture,
		source: cfg.source,
		top_left: cfg.quad.top_left,
		bottom_left: cfg.quad.bottom_left,
		bottom_right: cfg.quad.bottom_right,
		top_right: cfg.quad.top_right,
		q_top_left: cfg.quad.q_top_left,
		q_bottom_left: cfg.quad.q_bottom_left,
		q_bottom_right: cfg.quad.q_bottom_right,
		q_top_right: cfg.quad.q_top_right,
		tint: cfg.tint,
	})

	## Project a sampled texture view onto a validated planar quad.
	##
	## Legal in `render!` only.
	projective_texture_view! : Frame, ProjectiveTextureView => {}
	projective_texture_view! = |_frame, cfg| Host.draw_draw_texture_quad!({
		texture: cfg.texture,
		source: cfg.source,
		top_left: cfg.quad.top_left,
		bottom_left: cfg.quad.bottom_left,
		bottom_right: cfg.quad.bottom_right,
		top_right: cfg.quad.top_right,
		q_top_left: cfg.quad.q_top_left,
		q_bottom_left: cfg.quad.q_bottom_left,
		q_bottom_right: cfg.quad.q_bottom_right,
		q_top_right: cfg.quad.q_top_right,
		tint: cfg.tint,
	})

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
	debug_text! = |frame, cfg|
		Draw.text!(
			frame,
			{
				pos: cfg.pos,
				text: cfg.text,
				size: cfg.size,
				spacing: Draw.default_spacing,
				color: cfg.color,
				font: Font.stub,
			},
		)

	## Draw simple top-left aligned text with the built-in font.
	##
	## Legal in `render!` only.
	text_at! : Frame, SimpleText => {}
	text_at! = |frame, cfg|
		Draw.text!(
			frame,
			{
				pos: cfg.pos,
				text: cfg.text,
				size: cfg.size,
				spacing: Draw.default_spacing,
				color: cfg.color,
				font: Font.stub,
			},
		)

}

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
expect match Draw.ProjectiveQuad.from_corners({
	top_left: { x: 0, y: 0 },
	bottom_left: { x: 0, y: 10 },
	bottom_right: { x: 20, y: 10 },
	top_right: { x: 20, y: 0 },
}) {
	Ok(quad) => quad.project({ x: 0.5, y: 0.5 }) == { x: 10, y: 5 }
	Err(_) => False
}
expect match Draw.ProjectiveQuad.from_corners({
	top_left: { x: 130, y: 90 },
	bottom_left: { x: 75, y: 525 },
	bottom_right: { x: 725, y: 475 },
	top_right: { x: 610, y: 155 },
}) {
	Ok(quad) => {
		center = quad.project({ x: 0.5, y: 0.5 })
		F32.abs(center.x - 426.54004) < 0.001 and F32.abs(center.y - 281.87885) < 0.001
	}
	Err(_) => False
}
expect match Draw.ProjectiveQuad.from_corners({
	top_left: { x: F32.nan, y: 0 },
	bottom_left: { x: 0, y: 10 },
	bottom_right: { x: 10, y: 10 },
	top_right: { x: 10, y: 0 },
}) {
	Err(NonFiniteQuad) => True
	_ => False
}
expect match Draw.ProjectiveQuad.from_corners({
	top_left: { x: 0, y: 0 },
	bottom_left: { x: 1, y: 1 },
	bottom_right: { x: 2, y: 2 },
	top_right: { x: 3, y: 3 },
}) {
	Err(DegenerateQuad) => True
	_ => False
}
expect match Draw.ProjectiveQuad.from_corners({
	top_left: { x: 0, y: 0 },
	bottom_left: { x: 0, y: 10 },
	bottom_right: { x: 3, y: 5 },
	top_right: { x: 10, y: 0 },
}) {
	Err(NonConvexQuad) => True
	_ => False
}
expect match Draw.ProjectiveQuad.from_corners({
	top_left: { x: 0, y: 0 },
	bottom_left: { x: 0, y: 10 },
	bottom_right: { x: 10, y: 10 },
	top_right: { x: 0.0000001, y: 0 },
}) {
	Err(ProjectiveHorizon) => True
	_ => False
}

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
