## Sampled window state and window-management effects.
##
## The size here is the logical drawing size: it matches mouse coordinates and
## raylib drawing units, and on a HiDPI display it is smaller than the actual
## framebuffer in pixels. `scale!` is the factor between the two, and it is what
## makes the resolution of a `Capture` explainable: a capture is taken from the
## framebuffer, so a `960 x 640` window on a display with a scale of `2` records
## `1920 x 1280` pixels.
##
## `suggest_*` effects request geometry that the window manager may alter or
## decline; a later `Snapshot` is authoritative. `set_*` effects change state
## controlled by the host.
import Host
import Resource

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
			match Host.window_suggest_size!(size) {
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
		Host.window_suggest_min_size!({
			width: if size.width > 0 size.width else 0,
			height: if size.height > 0 size.height else 0,
		})

	## Why the clipboard held no text for `read_clipboard!`.
	##
	## `Unavailable` is an empty clipboard, non-text content, or a backend that
	## refused. `TooLarge` is content past what the host will copy into a `Str`,
	## and `Busy` is another process holding the clipboard.
	ClipboardReadError : [PermissionDenied, Unavailable, TooLarge, Busy]

	## Set raylib's CPU-side frame-rate cap.
	##
	## Values at or below zero render uncapped. This neither selects a software
	## renderer nor controls VSync.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	set_target_fps! : I32 => {}
	set_target_fps! = |fps| Host.window_set_target_fps!(fps)

	## How many framebuffer pixels one logical unit is, per axis.
	##
	## Legal in any callback, `render!` included. Reading a factor the backend
	## already holds costs nothing and allocates nothing.
	##
	## `1` on an ordinary display and `2` on a doubled HiDPI one; the two axes can
	## differ. Multiply a `Snapshot` size or a `Draw.FrameSize` by this to get the
	## pixel resolution a `Capture` records at.
	scale! : () => { x : F32, y : F32 }
	scale! = || Host.window_scale_dpi!()

	## One display the windowing backend can currently see.
	##
	## `index` is the argument `suggest_monitor!` takes. `size` and
	## `refresh_hz` describe the video mode the monitor is running now, not what
	## it is capable of, and `position` is its top-left corner in the same
	## virtual-desktop coordinates `suggest_position!` uses -- so
	## `suggest_position!(monitor.position)` puts the window in the corner of
	## that monitor.
	Monitor : {
		index : I32,
		name : Str,
		size : { width : I32, height : I32 },
		position : { x : I32, y : I32 },
		refresh_hz : I32,
	}

	## Every display the windowing backend can currently see.
	##
	## The list is as long as the operating system's monitor count, and that
	## count is the bound: the host asks for it, builds exactly that many
	## entries, and never retains any of them. Monitors come and go while an
	## app runs, so an answer describes the moment it was taken; ask again
	## rather than caching one for the life of the process.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	monitors! : () => List(Monitor)
	monitors! = || List.map(Host.window_monitors!(), monitor_from_host)

	## Suggest where the window's top-left corner should sit, in
	## virtual-desktop coordinates.
	##
	## The window manager controls the resulting geometry, and a position
	## outside every monitor may be adjusted or ignored. Pair it with
	## `monitors!` to place a window on a chosen display.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	suggest_position! : { x : I32, y : I32 } => {}
	suggest_position! = |position| Host.window_suggest_position!(position)

	## Suggest which monitor the window should move to, by `Monitor.index`.
	##
	## An index outside the connected set is ignored: which monitors exist can
	## change between reading `monitors!` and acting on one, so a stale index is
	## an ordinary race rather than a fault to report.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	suggest_monitor! : I32 => {}
	suggest_monitor! = |index| Host.window_suggest_monitor!(index)

	## Opaque clipboard authority supplied by App.Io. Effects return PermissionDenied when external access is disabled.
	Clipboard :: Resource.Authority.{

		## Private platform construction; no application can manufacture the argument.
		for_host : Resource.Authority -> Clipboard
		for_host = |authority| Clipboard.(authority)

		## Read the system clipboard as text.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`. The windowing
		## backend only answers on the thread that owns the window, and the read is a
		## pointer copy rather than I/O, so this does not wait.
		##
		## Content that is not text, or is larger than the host will copy into a
		## `Str`, is refused rather than truncated.
		read_text! : Clipboard => Try(Str, ClipboardReadError)
		read_text! = |Clipboard.(authority)| perform_read_clipboard!(authority)

		## Replace the system clipboard contents.
		##
		## Read it back with `Window.Clipboard.read_text!`.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		set_text! : Clipboard, Str => Try({}, [PermissionDenied, ..])
		set_text! = |Clipboard.(authority), text| perform_set_clipboard_text!(authority, text)

	}

}

## Group the host's flat monitor record into the shape applications read.
monitor_from_host : Host.WindowMonitorInfo -> Window.Monitor
monitor_from_host = |info| {
	index: info.index,
	name: info.name,
	size: { width: info.width, height: info.height },
	position: { x: info.x, y: info.y },
	refresh_hz: info.refresh_hz,
}

expect {
	monitor = monitor_from_host({ index: 1, name: "HDMI-1", width: 2560, height: 1440, x: 1920, y: 0, refresh_hz: 144 })
	monitor.size == { width: 2560, height: 1440 } and monitor.position == { x: 1920, y: 0 }
}

## Private authority-taking implementations.
perform_read_clipboard! : Resource.Authority => Try(Str, Window.ClipboardReadError)
perform_read_clipboard! = |authority|
	match Host.window_read_clipboard!(authority) {
		# closed error union to open error union
		Ok(contents) => Ok(contents)
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(Busy) => Err(Busy)
		Err(TooLarge) => Err(TooLarge)
		Err(Unavailable) => Err(Unavailable)
	}

perform_set_clipboard_text! : Resource.Authority, Str => Try({}, [PermissionDenied, ..])
perform_set_clipboard_text! = |authority, text| match Host.window_set_clipboard_text!(authority, text) {
	Ok({}) => Ok({})
	Err(PermissionDenied) => Err(PermissionDenied)
}
