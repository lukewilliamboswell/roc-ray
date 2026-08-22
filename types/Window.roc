## What the host observed about the window for one cycle.
##
## `App.Input` carries a `Snapshot` as `input.window`. It is an observation
## rather than a control surface: changing the window is what the platform's
## `Window` module is for.
Window := [].{

	## The window's logical drawing size, whether it has keyboard focus, and
	## whether it is minimized.
	##
	## `size` is in the same logical units as mouse positions and every drawing
	## call, not in framebuffer pixels; multiply by `Window.scale!` for those.
	## A minimized window still runs the frame loop, so an app that should idle
	## while minimized has to check this.
	Snapshot : {
		size : { width : I32, height : I32 },
		focused : Bool,
		minimized : Bool,
	}
}
