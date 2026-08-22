## The shapes a drawing call takes, and the interface a UI package draws
## through.
##
## Everything here is a plain record or tag union. `Draw` re-exports these, so
## an app writes `Draw.filled(Color.white)` and never names this module. A
## package that renders widgets does name it: `Drawable` is the set of calls
## such a package needs from whatever frame it is handed, so the package can be
## written once and used with any frame that offers them -- the platform's
## `Draw.Frame`, or a recording frame a test supplies.
import Color
import Math
import Texture

frame.Drawable(font) :
	where [
		frame.clear! : frame, Color.Rgba => {},
		frame.rectangle! : frame, { x : F32, y : F32, width : F32, height : F32, style : { fill : [NoFill, Fill(Color.Rgba)], stroke : [NoStroke, Stroke({ color : Color.Rgba, thickness : F32 })] } } => {},
		frame.rounded_rectangle! : frame, { x : F32, y : F32, width : F32, height : F32, radius : F32, segments : I32, style : { fill : [NoFill, Fill(Color.Rgba)], stroke : [NoStroke, Stroke({ color : Color.Rgba, thickness : F32 })] } } => {},
		frame.text! : frame, { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color.Rgba, font : font, align : { horizontal : [Left, Center, Right], vertical : [Top, Middle, Bottom] } } => {},
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

	## Which horizontal edge or center of a text box `pos` refers to.
	HAlign : [Left, Center, Right]

	## Which vertical edge or center of a text box `pos` refers to.
	VAlign : [Top, Middle, Bottom]

	## Where `pos` sits within the text it places, in both axes at once.
	TextAlign : { horizontal : HAlign, vertical : VAlign }

	## A string, where to put it, and how to paint it. `font` is left open so a
	## package can lay text out with whatever font type its caller has.
	Text(font) : { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color.Rgba, font : font, align : TextAlign }

	## One textured quad: which part of the texture to read (`source`), where to
	## put it (`dest`), the point within `dest` that `rotation` turns around
	## (`origin`), and the color the sample is multiplied by (`tint`).
	TextureDraw : { texture : Texture, source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color.Rgba }
}
