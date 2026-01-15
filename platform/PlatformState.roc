## Platform state passed to render! on each frame
PlatformState := {
	frame_count : U64,
	mouse : {
		left : Bool,
		middle : Bool,
		right : Bool,
		wheel : F32,
		x : F32,
		y : F32,
	},
}.{}
