## Drawing configuration and caller-injected rendering effects.
##
## Applications obtain the package-owned `Effects` nominal through
## `App.effects().render(frame)` on their platform. Rendering packages accept
## that handle without importing the platform. `Drawable` remains the
## structural interface implemented by `Draw.Frame` and compatible recording
## frames.
import Color
import Font
import Math
import Texture

frame.Drawable :
	where [
		frame.clear! : frame, Color.Rgba => {},
		frame.rectangle! : frame, { x : F32, y : F32, width : F32, height : F32, style : { fill : [NoFill, Fill(Color.Rgba)], stroke : [NoStroke, Stroke({ color : Color.Rgba, thickness : F32 })] } } => {},
		frame.rounded_rectangle! : frame, { x : F32, y : F32, width : F32, height : F32, radius : F32, segments : I32, style : { fill : [NoFill, Fill(Color.Rgba)], stroke : [NoStroke, Stroke({ color : Color.Rgba, thickness : F32 })] } } => {},
		frame.text! : frame, { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color.Rgba, font : Font } => {},
		frame.texture! : frame, Drawing.TextureDraw => {},
		frame.with_scissor! : frame, Math.Rect, (frame => Try({}, [ScopeLimit])) => Try({}, [ScopeLimit]),
	]

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

	## A string, its resolved top-left origin, and how to paint it.
	Text : { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color.Rgba, font : Font }

	## One textured quad: which part of the texture to read (`source`), where to
	## put it (`dest`), the point within `dest` that `rotation` turns around
	## (`origin`), and the color the sample is multiplied by (`tint`).
	TextureDraw : { texture : Texture, source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color.Rgba }

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

			match rectangle.style.fill {
				NoFill => {}
				Fill(color) => effects.shape!(geometry, SolidFill(color))
			}

			match rectangle.style.stroke {
				NoStroke => {}
				Stroke(stroke) => effects.shape!(geometry, SolidStroke(stroke))
			}
		}

		## Restrict drawing to `bounds` while the callback runs.
		##
		## The spike uses the fixed result and error shape already used by the
		## package's `Drawable` boundary. The pinned compiler cannot generalize
		## result and open-error variables stored inside the private effect record.
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
			provider.with_scissor! : provider, frame, Math.Rect, (frame => Try({}, [ScopeLimit])) => Try({}, [ScopeLimit]),
		]
	effects_for = |provider, frame|
		Effects.(
			{
				shape_impl!: |geometry, paint| provider.shape!(frame, geometry, paint),
				draw_text_impl!: |text| provider.draw_text!(frame, text),
				with_scissor_impl!: |bounds, callback|
					provider.with_scissor!(frame, bounds, |scoped_frame|
						callback(Drawing.effects_for(provider, scoped_frame))),
			},
		)
}
