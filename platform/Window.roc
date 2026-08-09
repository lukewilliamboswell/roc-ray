## Window module - what the window looked like this cycle, and how to change it.
##
## The size here is the *logical* drawing size: it matches mouse coordinates and
## raylib drawing units, and on a HiDPI display it is smaller than the actual
## framebuffer in pixels.
##
## Use `focused` and `minimized` to pause input or skip expensive work while the
## window is inactive.
Window := [].{

	## Window geometry and visibility sampled once for this cycle.
	Snapshot : {

		## Logical drawing dimensions for this frame, in the same coordinate
		## space as mouse input.
		size : { width : I32, height : I32 },

		## Whether the window currently has input focus.
		focused : Bool,

		## Whether the window is currently minimized.
		minimized : Bool,
	}

	## Set the smallest size the window can be dragged down to, as an action.
	##
	## Each negative dimension is clamped to `0`, leaving that axis
	## unconstrained. A minimum only binds on a resizable window, so pair it
	## with `App.default.with_resizable(Bool.True)`.
	set_window_min_size : { width : I32, height : I32 } -> [SetWindowMinSize({ width : I32, height : I32 }), ..]
	set_window_min_size = |size| SetWindowMinSize(size)

	## Replace the system clipboard contents, as an action.
	##
	## Reading it back is a `Program.read_clipboard` task instead, because a read has an
	## answer to deliver.
	set_clipboard_text : Str -> [SetClipboardText(Str), ..]
	set_clipboard_text = |text| SetClipboardText(text)
}
