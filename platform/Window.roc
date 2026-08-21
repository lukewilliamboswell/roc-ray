## Window module - what the window looked like this cycle, and how to change it.
##
## The size here is the *logical* drawing size: it matches mouse coordinates and
## raylib drawing units, and on a HiDPI display it is smaller than the actual
## framebuffer in pixels.
##
## Use `focused` and `minimized` to pause input or skip expensive work while the
## window is inactive.
import rrt.Window as RrtWindow

Window := [].{

	## Window geometry and visibility sampled once for this cycle.
	Snapshot : RrtWindow.Snapshot

	## Suggest a new logical window size to the window manager.
	##
	## Non-positive dimensions are ignored. A valid suggestion is issued once in
	## command order, but the backend or window manager controls the resulting
	## geometry. Observe the latest accepted size through a later `Snapshot`;
	## this command does not promise that the following presentation has changed.
	suggest_size : { width : I32, height : I32 } -> [SuggestWindowSize({ width : I32, height : I32 }), ..]
	suggest_size = |size| SuggestWindowSize(size)

	## Suggest the smallest size the window can be dragged down to.
	##
	## Each negative dimension is clamped to `0`, leaving that axis
	## unconstrained. A minimum only binds on a resizable window, so pair it
	## with `App.default.with_resizable(Bool.True)`. The window manager may apply
	## target-specific constraints; `Snapshot` remains the authoritative sample.
	suggest_min_size : { width : I32, height : I32 } -> [SuggestWindowMinSize({ width : I32, height : I32 }), ..]
	suggest_min_size = |size| SuggestWindowMinSize(size)

	ClipboardReadError : [Unavailable, TooLarge, Busy]

	read_clipboard : (Try(Str, ClipboardReadError) -> msg) -> [ReadClipboard({ callback : Try(Str, ClipboardReadError) -> msg }), ..]
	read_clipboard = |callback| ReadClipboard({ callback: callback })

	## Set raylib's CPU-side frame-rate cap, as a command.
	##
	## Values at or below zero render uncapped. This neither selects a software
	## renderer nor controls VSync.
	set_target_fps : I32 -> [SetTargetFps(I32), ..]
	set_target_fps = |fps| SetTargetFps(fps)

	## Replace the system clipboard contents, as a command.
	##
	## Reading it back is a `Window.read_clipboard` request instead, because a read has an
	## answer to deliver.
	set_clipboard_text : Str -> [SetClipboardText(Str), ..]
	set_clipboard_text = |text| SetClipboardText(text)
}
