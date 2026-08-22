## Window module - what the window looked like this cycle, and how to change it.
##
## The size here is the *logical* drawing size: it matches mouse coordinates and
## raylib drawing units, and on a HiDPI display it is smaller than the actual
## framebuffer in pixels.
##
## Use `focused` and `minimized` to pause input or skip expensive work while the
## window is inactive.
import rrt.Window as RrtWindow
import HostHost

Window := [].{

	## Window geometry and visibility sampled once for this cycle.
	Snapshot : RrtWindow.Snapshot

	## Suggest a new logical window size to the window manager.
	##
	## Non-positive dimensions are ignored. The backend or window manager
	## controls the resulting geometry: observe the latest accepted size through
	## a later `Snapshot`. Valid during `init!`, `update!`, and tasks.
	suggest_size! : { width : I32, height : I32 } => {}
	suggest_size! = |size|
		if size.width > 0 and size.height > 0 {
			match HostHost.suggest_window_size!(size) {
				Ok({}) => {}
				Err(NotSupported) => {}
			}
		} else {
			{}
		}

	## Suggest the smallest size the window can be dragged down to.
	##
	## Each negative dimension is clamped to `0`, leaving that axis
	## unconstrained. A minimum only binds on a resizable window, so pair it
	## with `App.default.with_resizable(Bool.True)`. The window manager may apply
	## target-specific constraints; `Snapshot` remains the authoritative sample.
	suggest_min_size! : { width : I32, height : I32 } => {}
	suggest_min_size! = |size|
		HostHost.suggest_window_min_size!({
			width: if size.width > 0 size.width else 0,
			height: if size.height > 0 size.height else 0,
		})

	ClipboardReadError : [Unavailable, TooLarge, Busy]

	read_clipboard : (Try(Str, ClipboardReadError) -> msg) -> [ReadClipboard({ callback : Try(Str, ClipboardReadError) -> msg }), ..]
	read_clipboard = |callback| ReadClipboard({ callback: callback })

	## Set raylib's CPU-side frame-rate cap.
	##
	## Values at or below zero render uncapped. This neither selects a software
	## renderer nor controls VSync. Valid during `init!`, `update!`, and tasks.
	set_target_fps! : I32 => {}
	set_target_fps! = |fps| HostHost.set_target_fps!(fps)

	## Replace the system clipboard contents.
	##
	## Reading it back is a `Window.read_clipboard` request instead, because a
	## read has an answer to deliver. Valid during `init!`, `update!`, and tasks.
	set_clipboard_text! : Str => {}
	set_clipboard_text! = |text| HostHost.set_clipboard_text!(text)
}
