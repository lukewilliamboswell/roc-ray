## Drawing configuration and caller-injected rendering effects.
##
## Applications obtain the package-owned `Effects` nominal through
## `App.effects().render(frame)` on their platform. Rendering packages accept
## that handle without importing the platform.
import Color
import Font
import Math
import Texture

Drawing := [].{

	## Whether a shape's interior is painted, and in what color.
	Fill : [NoFill, Fill(Color.Rgba)]

	## Whether a shape's outline is painted, in what color, and how thick.
	Stroke : [NoStroke, Stroke({ color : Color.Rgba, thickness : F32 })]

	## A shape's interior and outline together. `Draw.filled`,
	## `Draw.outlined` and `Draw.filled_and_outlined` build the usual three.
	ShapeStyle : { fill : Fill, stroke : Stroke }

	## An axis-aligned rectangle and the style to paint it with, as
	## `Draw.rectangle!` takes it.
	Rectangle : { x : F32, y : F32, width : F32, height : F32, style : ShapeStyle }

	## A rectangle with rounded corners. `radius` is the corner radius in the
	## same units as the size, and `segments` is how many line segments
	## approximate each corner arc.
	RoundedRectangle : { x : F32, y : F32, width : F32, height : F32, radius : F32, segments : I32, style : ShapeStyle }

	## A circle and the fill and/or stroke applied to it.
	Circle : { center : Math.Vec2, radius : F32, style : ShapeStyle }

	## Three vertices and the fill and/or stroke applied to their triangle.
	Triangle : { a : Math.Vec2, b : Math.Vec2, c : Math.Vec2, style : ShapeStyle }

	## A convex fill and/or ordered polygon outline.
	##
	## Points must be ordered around the boundary. Filled concave or
	## self-intersecting polygons are unsupported; outlines accept any ordered
	## point path. Fewer than three points do not fill.
	ConvexPolygon : { points : List(Math.Vec2), style : ShapeStyle }

	## Deprecated compatibility name. Prefer `ConvexPolygon`, which states the
	## constraint required for a filled polygon.
	Polygon : ConvexPolygon

	RectangleGradientV : { x : F32, y : F32, width : F32, height : F32, color_top : Color.Rgba, color_bottom : Color.Rgba }
	RectangleGradientH : { x : F32, y : F32, width : F32, height : F32, color_left : Color.Rgba, color_right : Color.Rgba }
	CircleGradient : { center : Math.Vec2, radius : F32, color_inner : Color.Rgba, color_outer : Color.Rgba }
	Line : { start : Math.Vec2, end : Math.Vec2, stroke : Stroke }
	Fps : { pos : Math.Vec2, size : F32, color : Color.Rgba }

	## Create a fill-only shape style.
	filled : Color.Rgba -> ShapeStyle
	filled = |color| { fill: Fill(color), stroke: NoStroke }

	## Create a stroke with color and thickness in logical pixels.
	stroke : Color.Rgba, F32 -> Stroke
	stroke = |color, thickness| Stroke({ color, thickness })

	## Create a stroke-only shape style.
	outlined : Color.Rgba, F32 -> ShapeStyle
	outlined = |color, thickness| { fill: NoFill, stroke: Drawing.stroke(color, thickness) }

	## Create a shape style with both fill and outline.
	filled_and_outlined : Color.Rgba, Color.Rgba, F32 -> ShapeStyle
	filled_and_outlined = |fill, outline, thickness| { fill: Fill(fill), stroke: Drawing.stroke(outline, thickness) }

	## Find the top-left position that centers measured text in a rectangle.
	center_in_rect : Rectangle, Font.Size -> Math.Vec2
	center_in_rect = |rect, size| {
		{
			x: rect.x + rect.width * 0.5 - size.width * 0.5,
			y: rect.y + rect.height * 0.5 - size.height * 0.5,
		}
	}

	## A string, its resolved top-left origin, and how to paint it.
	Text : { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color.Rgba, font : Font }

	DebugText : { pos : Math.Vec2, text : Str, size : F32, color : Color.Rgba }
	SimpleText : DebugText

	default_spacing : F32
	default_spacing = 1

	## One textured quad: which part of the texture to read (`source`), where to
	## put it (`dest`), the point within `dest` that `rotation` turns around
	## (`origin`), and the color the sample is multiplied by (`tint`).
	TextureDraw : { texture : Texture, source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color.Rgba }

	## One instance of a batched texture draw. The batch supplies the texture once.
	TextureInstance : { source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color.Rgba }

	TextureDrawOptions : { source : Math.Rect, source_set : Bool, dest : Math.Rect, dest_set : Bool, pos : Math.Vec2, origin : Math.Vec2, origin_set : Bool, origin_center : Bool, rotation : F32, scale : Math.Vec2, tint : Color.Rgba }

	TextureDrawBuilder(field) := { value : field, apply : TextureDrawOptions -> TextureDrawOptions }.{
		default_options : TextureDrawOptions
		default_options = { source: Math.rect(0, 0, 0, 0), source_set: Bool.False, dest: Math.rect(0, 0, 0, 0), dest_set: Bool.False, pos: Math.zero, origin: Math.zero, origin_set: Bool.False, origin_center: Bool.False, rotation: 0, scale: { x: 1, y: 1 }, tint: Color.white }

		map2 : TextureDrawBuilder(a), TextureDrawBuilder(b), (a, b -> c) -> TextureDrawBuilder(c)
		map2 = |left, right, combine| { value: combine(left.value, right.value), apply: |options| (right.apply)((left.apply)(options)) }

		empty : TextureDrawBuilder({})
		empty = { value: {}, apply: |options| options }

		run : TextureDrawBuilder(a), Texture -> TextureDraw
		run = |builder, texture| {
			options = (builder.apply)(TextureDrawBuilder.default_options)
			source = if options.source_set options.source else Math.rect(0, 0, texture.width, texture.height)
			dest = if options.dest_set options.dest else { x: options.pos.x, y: options.pos.y, width: source.width * options.scale.x, height: source.height * options.scale.y }
			origin = if options.origin_set options.origin else if options.origin_center { x: dest.width * 0.5, y: dest.height * 0.5 } else Math.zero
			{ texture, source, dest, origin, rotation: options.rotation, tint: options.tint }
		}

		pos = |value| { value, apply: |options| { ..options, pos: value } }
		source = |value| { value, apply: |options| { ..options, source: value, source_set: Bool.True } }
		dest = |value| { value, apply: |options| { ..options, dest: value, dest_set: Bool.True } }
		origin = |value| { value, apply: |options| { ..options, origin: value, origin_set: Bool.True, origin_center: Bool.False } }
		origin_center = { value: {}, apply: |options| { ..options, origin_set: Bool.False, origin_center: Bool.True } }
		rotation = |value| { value, apply: |options| { ..options, rotation: value } }
		scale = |value| { value, apply: |options| { ..options, scale: { x: value, y: value } } }
		scale_xy = |value| { value, apply: |options| { ..options, scale: value } }
		tint = |value| { value, apply: |options| { ..options, tint: value } }
	}

	ProjectiveQuadCorners : { top_left : Math.Vec2, bottom_left : Math.Vec2, bottom_right : Math.Vec2, top_right : Math.Vec2 }
	ProjectiveQuadFields : { top_left : Math.Vec2, bottom_left : Math.Vec2, bottom_right : Math.Vec2, top_right : Math.Vec2, q_top_left : F32, q_bottom_left : F32, q_bottom_right : F32, q_top_right : F32 }

	## Validated finite, convex planar projection with bounded homogeneous weights.
	ProjectiveQuad :: ProjectiveQuadFields.{
		from_corners : ProjectiveQuadCorners -> Try(ProjectiveQuad, [NonFiniteQuad, DegenerateQuad, NonConvexQuad, ProjectiveHorizon, ..])
		from_corners = |corners| projective_quad_from_corners(corners)

		project : ProjectiveQuad, Math.Vec2 -> Math.Vec2
		project = |ProjectiveQuad.(quad), uv| projective_quad_project(quad, uv)

		## Expose validated fields read-only for platform adapters. Construction
		## remains restricted to `from_corners`.
		fields : ProjectiveQuad -> ProjectiveQuadFields
		fields = |ProjectiveQuad.(quad)| quad
	}

	ProjectiveTexture : { texture : Texture, source : Math.Rect, quad : ProjectiveQuad, tint : Color.Rgba }
	ProjectiveTextureView : ProjectiveTexture

	texture_draw : Texture -> TextureDraw
	texture_draw = |texture| TextureDrawBuilder.run(TextureDrawBuilder.empty, texture)

	texture_at : Texture, Math.Vec2 -> TextureDraw
	texture_at = |texture, pos| TextureDrawBuilder.run(TextureDrawBuilder.pos(pos), texture)

	texture_view_draw : Texture -> TextureDraw
	texture_view_draw = |texture| Drawing.texture_draw(texture)

	texture_view_at : Texture, Math.Vec2 -> TextureDraw
	texture_view_at = |texture, pos| Drawing.texture_at(texture, pos)

	## Fillable geometry accepted by the low-level package drawing effect.
	## Every variant deliberately supports both `SolidFill` and `SolidStroke`.
	Geometry : [
		Rectangle(Math.Rect),
		RoundedRectangle({ bounds : Math.Rect, radius : F32, segments : I32 }),
		Circle({ center : Math.Vec2, radius : F32 }),
		Triangle({ a : Math.Vec2, b : Math.Vec2, c : Math.Vec2 }),
		ConvexPolygon(List(Math.Vec2)),
	]

	## One operation to apply to a fillable geometry.
	Paint : [
		SolidFill(Color.Rgba),
		SolidStroke({ color : Color.Rgba, thickness : F32 }),
	]

	## Render-scoped drawing effects configured by an application's platform.
	##
	## Reusable packages accept this type without depending on RocRay. An
	## application obtains the identical nominal through
	## `App.effects().render(frame)`.
	Effects :: {
		shape_impl! : Geometry, Paint => {},
		draw_text_impl! : Text => {},
		rectangle_gradient_v_impl! : RectangleGradientV => {},
		rectangle_gradient_h_impl! : RectangleGradientH => {},
		circle_gradient_impl! : CircleGradient => {},
		fps_impl! : Fps => {},
		line_impl! : Line => {},
		texture_impl! : TextureDraw => {},
		texture_instances_impl! : Texture, List(TextureInstance) => {},
		projective_texture_impl! : ProjectiveTexture => {},
		with_scissor_impl! : Math.Rect, (Effects => Try({}, [ScopeLimit])) => Try({}, [ScopeLimit]),
	}.{

		## Apply one solid fill or stroke to a supported geometry.
		shape! : Effects, Geometry, Paint => {}
		shape! = |Effects.(implementation), geometry, paint|
			(implementation.shape_impl!)(geometry, paint)

		## Draw text using an explicit font, spacing, color, and resolved origin.
		text! : Effects, Text => {}
		text! = |Effects.(implementation), text|
			(implementation.draw_text_impl!)(text)

		rectangle_gradient_v! : Effects, RectangleGradientV => {}
		rectangle_gradient_v! = |Effects.(implementation), cfg| (implementation.rectangle_gradient_v_impl!)(cfg)

		rectangle_gradient_h! : Effects, RectangleGradientH => {}
		rectangle_gradient_h! = |Effects.(implementation), cfg| (implementation.rectangle_gradient_h_impl!)(cfg)

		circle_gradient! : Effects, CircleGradient => {}
		circle_gradient! = |Effects.(implementation), cfg| (implementation.circle_gradient_impl!)(cfg)

		fps! : Effects, Fps => {}
		fps! = |Effects.(implementation), cfg| (implementation.fps_impl!)(cfg)

		## Draw a line when its stroke is present. `NoStroke` performs no call.
		line! : Effects, Line => {}
		line! = |Effects.(implementation), cfg|
			match cfg.stroke {
				NoStroke => {}
				Stroke(_) => (implementation.line_impl!)(cfg)
			}

		texture! : Effects, TextureDraw => {}
		texture! = |Effects.(implementation), cfg| (implementation.texture_impl!)(cfg)

		## Deprecated compatibility spelling. Prefer `texture!`.
		draw_texture! : Effects, TextureDraw => {}
		draw_texture! = |effects, cfg| effects.texture!(cfg)

		## Empty batches perform no hosted call.
		texture_instances! : Effects, Texture, List(TextureInstance) => {}
		texture_instances! = |Effects.(implementation), texture, instances|
			if List.is_empty(instances) {} else (implementation.texture_instances_impl!)(texture, instances)

		projective_texture! : Effects, ProjectiveTexture => {}
		projective_texture! = |Effects.(implementation), cfg| (implementation.projective_texture_impl!)(cfg)

		projective_texture_view! : Effects, ProjectiveTextureView => {}
		projective_texture_view! = |effects, cfg| effects.projective_texture!(cfg)

		debug_text! : Effects, DebugText => {}
		debug_text! = |effects, cfg|
			effects.text!({ pos: cfg.pos, text: cfg.text, size: cfg.size, spacing: Drawing.default_spacing, color: cfg.color, font: Font.stub })

		text_at! : Effects, SimpleText => {}
		text_at! = |effects, cfg| effects.debug_text!(cfg)

		## Draw a filled and/or outlined axis-aligned rectangle.
		rectangle! : Effects, Rectangle => {}
		rectangle! = |effects, rectangle| {
			geometry = Rectangle({ x: rectangle.x, y: rectangle.y, width: rectangle.width, height: rectangle.height })
			paint_style!(effects, geometry, rectangle.style)
		}

		## Draw a filled and/or outlined rounded rectangle.
		rounded_rectangle! : Effects, RoundedRectangle => {}
		rounded_rectangle! = |effects, rectangle| {
			geometry = RoundedRectangle({
				bounds: {
					x: rectangle.x,
					y: rectangle.y,
					width: rectangle.width,
					height: rectangle.height,
				},
				radius: rectangle.radius,
				segments: rectangle.segments,
			})

			paint_style!(effects, geometry, rectangle.style)
		}

		## Draw a filled and/or outlined circle.
		circle! : Effects, Circle => {}
		circle! = |effects, circle| {
			geometry = Circle({ center: circle.center, radius: circle.radius })
			paint_style!(effects, geometry, circle.style)
		}

		## Draw a filled and/or outlined triangle.
		triangle! : Effects, Triangle => {}
		triangle! = |effects, triangle| {
			geometry = Triangle({ a: triangle.a, b: triangle.b, c: triangle.c })
			paint_style!(effects, geometry, triangle.style)
		}

		## Draw a convex fill and/or ordered polygon outline.
		convex_polygon! : Effects, ConvexPolygon => {}
		convex_polygon! = |effects, polygon| {
			geometry = ConvexPolygon(polygon.points)
			paint_style!(effects, geometry, polygon.style)
		}

		## Deprecated compatibility spelling. Prefer `convex_polygon!`.
		polygon! : Effects, Polygon => {}
		polygon! = |effects, polygon| effects.convex_polygon!(polygon)

		## Restrict drawing to `bounds` while the callback runs.
		##
		## The pinned compiler cannot generalize result and open-error variables
		## stored inside the private effect record, so this callback has a fixed
		## result and error shape.
		with_scissor! : Effects, Math.Rect, (Effects => Try({}, [ScopeLimit])) => Try({}, [ScopeLimit])
		with_scissor! = |Effects.(implementation), bounds, callback|
			(implementation.with_scissor_impl!)(bounds, callback)
	}

	## Bind a compatible low-level provider and its current frame into the
	## canonical package drawing handle.
	effects_for : provider, frame -> Effects
		where [
			provider.shape! : provider, frame, Geometry, Paint => {},
			provider.draw_text! : provider, frame, Text => {},
			provider.rectangle_gradient_v! : provider, frame, RectangleGradientV => {},
			provider.rectangle_gradient_h! : provider, frame, RectangleGradientH => {},
			provider.circle_gradient! : provider, frame, CircleGradient => {},
			provider.fps! : provider, frame, Fps => {},
			provider.line! : provider, frame, Line => {},
			provider.texture! : provider, frame, TextureDraw => {},
			provider.texture_instances! : provider, frame, Texture, List(TextureInstance) => {},
			provider.projective_texture! : provider, frame, ProjectiveTexture => {},
			provider.with_scissor! : provider, frame, Math.Rect, (frame => Try({}, [ScopeLimit])) => Try({}, [ScopeLimit]),
		]
	effects_for = |provider, frame|
		Effects.(
			{
				shape_impl!: |geometry, paint| provider.shape!(frame, geometry, paint),
				draw_text_impl!: |text| provider.draw_text!(frame, text),
				rectangle_gradient_v_impl!: |cfg| provider.rectangle_gradient_v!(frame, cfg),
				rectangle_gradient_h_impl!: |cfg| provider.rectangle_gradient_h!(frame, cfg),
				circle_gradient_impl!: |cfg| provider.circle_gradient!(frame, cfg),
				fps_impl!: |cfg| provider.fps!(frame, cfg),
				line_impl!: |cfg| provider.line!(frame, cfg),
				texture_impl!: |cfg| provider.texture!(frame, cfg),
				texture_instances_impl!: |texture, instances| provider.texture_instances!(frame, texture, instances),
				projective_texture_impl!: |cfg| provider.projective_texture!(frame, cfg),
				with_scissor_impl!: |bounds, callback|
					provider.with_scissor!(frame, bounds, |scoped_frame|
						callback(Drawing.effects_for(provider, scoped_frame))),
			},
		)
}

## Apply a high-level shape style in the same order as the platform helpers:
## fill first, then stroke. Each selected paint remains one hosted call.
paint_style! : Drawing.Effects, Drawing.Geometry, Drawing.ShapeStyle => {}
paint_style! = |effects, geometry, style| {
	match style.fill {
		NoFill => {}
		Fill(color) => effects.shape!(geometry, SolidFill(color))
	}

	match style.stroke {
		NoStroke => {}
		Stroke(stroke) => effects.shape!(geometry, SolidStroke(stroke))
	}
}

vec_is_finite = |vec| F32.is_finite(vec.x) and F32.is_finite(vec.y)

corner_cross = |a, b, c| (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)

crosses_have_one_sign = |a, b, c, d| (a > 0 and b > 0 and c > 0 and d > 0) or (a < 0 and b < 0 and c < 0 and d < 0)

projective_quad_from_corners = |corners| {
	finite = vec_is_finite(corners.top_left) and vec_is_finite(corners.bottom_left) and vec_is_finite(corners.bottom_right) and vec_is_finite(corners.top_right)
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
				fields = { top_left: corners.top_left, bottom_left: corners.bottom_left, bottom_right: corners.bottom_right, top_right: corners.top_right, q_top_left: q_top_left / q_max, q_bottom_left: q_bottom_left / q_max, q_bottom_right: q_bottom_right / q_max, q_top_right: q_top_right / q_max }
				bounded = fields.q_top_left > 0.000001 and fields.q_top_right > 0.000001 and fields.q_bottom_left > 0.000001 and fields.q_bottom_right > 0.000001
				if !weights_finite or !bounded Err(ProjectiveHorizon) else Ok(Drawing.ProjectiveQuad.(fields))
			}
		}
	}
}

projective_quad_project = |quad, uv| {
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

expect match Drawing.ProjectiveQuad.from_corners({ top_left: { x: 0, y: 0 }, bottom_left: { x: 0, y: 10 }, bottom_right: { x: 20, y: 10 }, top_right: { x: 20, y: 0 } }) {
	Ok(quad) => quad.project({ x: 0.5, y: 0.5 }) == { x: 10, y: 5 }
	Err(_) => False
}

expect match Drawing.ProjectiveQuad.from_corners({ top_left: { x: 130, y: 90 }, bottom_left: { x: 75, y: 525 }, bottom_right: { x: 725, y: 475 }, top_right: { x: 610, y: 155 } }) {
	Ok(quad) => {
		center = quad.project({ x: 0.5, y: 0.5 })
		F32.abs(center.x - 426.54004) < 0.001 and F32.abs(center.y - 281.87885) < 0.001
	}
	Err(_) => False
}

expect match Drawing.ProjectiveQuad.from_corners({ top_left: { x: F32.nan, y: 0 }, bottom_left: { x: 0, y: 10 }, bottom_right: { x: 10, y: 10 }, top_right: { x: 10, y: 0 } }) {
	Err(NonFiniteQuad) => True
	_ => False
}

expect match Drawing.ProjectiveQuad.from_corners({ top_left: { x: 0, y: 0 }, bottom_left: { x: 1, y: 1 }, bottom_right: { x: 2, y: 2 }, top_right: { x: 3, y: 3 } }) {
	Err(DegenerateQuad) => True
	_ => False
}

expect match Drawing.ProjectiveQuad.from_corners({ top_left: { x: 0, y: 0 }, bottom_left: { x: 0, y: 10 }, bottom_right: { x: 3, y: 5 }, top_right: { x: 10, y: 0 } }) {
	Err(NonConvexQuad) => True
	_ => False
}

expect match Drawing.ProjectiveQuad.from_corners({ top_left: { x: 0, y: 0 }, bottom_left: { x: 0, y: 10 }, bottom_right: { x: 10, y: 10 }, top_right: { x: 0.0000001, y: 0 } }) {
	Err(ProjectiveHorizon) => True
	_ => False
}
