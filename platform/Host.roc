## Host module - provides platform state and system effects
Host := {
	frame_count : U64,
	mouse : {
		left : Bool,
		middle : Bool,
		right : Bool,
		wheel : F32,
		x : F32,
		y : F32,
	},
}.{
	ScreenSize : { width : I32, height : I32 }

	## Exit the application with the given exit code.
	## The exit happens after the current frame completes to allow proper cleanup.
	exit! : I64 => {}

	## Get the current screen/window dimensions.
	get_screen_size! : () => ScreenSize

	## Read an environment variable by key.
	## Returns Ok with the value if found, or Err NotFound if not set.
	read_env! : Host, Str => Try(Str, [NotFound, ..])

	## Set the window/screen size.
	## Returns Err NotSupported on platforms that don't support window resizing (e.g., web).
	## Uses F32 for width/height since most apps use floats for pixel math.
	set_screen_size! : { width : F32, height : F32 } => Try({}, [NotSupported, ..])

	## Set the target frames per second for the render loop.
	## Note: On web/WASM, this has no effect as the browser controls frame timing.
	set_target_fps! : I32 => {}
}
