## Draw module - provides drawing primitives for the Roc raylib platform
import Color

Draw := [].{

	Vector2 : {
		x : F32,
		y : F32,
	}

	Rectangle : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		color : Color,
	}

	Circle : {
		center : Vector2,
		radius : F32,
		color : Color,
	}

	Line : {
		start : Vector2,
		end : Vector2,
		color : Color,
	}

	Text : {
		pos : Vector2,
		text : Str,
		size : I32,
		color : Color,
	}

	## Hosted effects - implemented by the host
	begin_frame! : () => {}
	circle! : Circle => {}
	clear! : Color => {}
	end_frame! : () => {}
	line! : Line => {}
	rectangle! : Rectangle => {}
	text! : Text => {}

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
