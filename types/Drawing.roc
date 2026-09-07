## Pure drawing configuration and the interface used by rendering packages.
##
## Apps use the platform's `Draw` re-exports. Rendering packages can accept
## `Drawable`, which is implemented by `Draw.Frame` and by compatible test or
## recording frames.
import Color
import resources/Font as Font
import Math
import resources/Texture as Texture

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
}
