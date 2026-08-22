## What the window looked like this cycle, and how to change it.
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
	## a later `Snapshot`.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
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
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	suggest_min_size! : { width : I32, height : I32 } => {}
	suggest_min_size! = |size|
		HostHost.suggest_window_min_size!({
			width: if size.width > 0 size.width else 0,
			height: if size.height > 0 size.height else 0,
		})

	## Why the clipboard held no text for `read_clipboard!`.
	##
	## `Unavailable` is an empty clipboard, non-text content, or a backend that
	## refused. `TooLarge` is content past what the host will copy into a `Str`,
	## and `Busy` is another process holding the clipboard.
	ClipboardReadError : [Unavailable, TooLarge, Busy]

	## Read the system clipboard as text.
	##
	## Content that is not text, or is larger than the host will copy into a
	## `Str`, is refused rather than truncated.
	##
	## The windowing backend only answers on the thread that owns the window,
	## and the read is a pointer copy rather than I/O, so this does not wait:
	## it is legal in `init!`, `update!`, and tasks, and refused in `render!`.
	read_clipboard! : () => Try(Str, ClipboardReadError)
	read_clipboard! = || {
		result = HostHost.read_clipboard!()
		if result.err == 0 {
			Ok(result.contents)
		} else {
			Err(clipboard_error(result.err))
		}
	}

	## Set raylib's CPU-side frame-rate cap.
	##
	## Values at or below zero render uncapped. This neither selects a software
	## renderer nor controls VSync.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	set_target_fps! : I32 => {}
	set_target_fps! = |fps| HostHost.set_target_fps!(fps)

	## Replace the system clipboard contents.
	##
	## Read it back with `Window.read_clipboard!`.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	set_clipboard_text! : Str => {}
	set_clipboard_text! = |text| HostHost.set_clipboard_text!(text)
}

## Decode the host's clipboard-error code. Mirrored in `src/host_native.zig`.
clipboard_error : U8 -> Window.ClipboardReadError
clipboard_error = |code|
	if code == 5 {
		TooLarge
	} else if code == 3 {
		Busy
	} else {
		Unavailable
	}

expect clipboard_error(5) == TooLarge
expect clipboard_error(3) == Busy
expect clipboard_error(4) == Unavailable
expect clipboard_error(0) == Unavailable
