## Shared drawing records and the structural interface used by UI renderers.
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

	Fill : [NoFill, Fill(Color.Rgba)]

	Stroke : [NoStroke, Stroke({ color : Color.Rgba, thickness : F32 })]

	ShapeStyle : { fill : Fill, stroke : Stroke }

	Rectangle : { x : F32, y : F32, width : F32, height : F32, style : ShapeStyle }

	RoundedRectangle : { x : F32, y : F32, width : F32, height : F32, radius : F32, segments : I32, style : ShapeStyle }

	HAlign : [Left, Center, Right]

	VAlign : [Top, Middle, Bottom]

	TextAlign : { horizontal : HAlign, vertical : VAlign }

	Text(font) : { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color.Rgba, font : font, align : TextAlign }

	TextureDraw : { texture : Texture, source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color.Rgba }
}
