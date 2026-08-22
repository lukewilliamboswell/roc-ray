## What the window looked like this cycle, and how to change it.
##
## The size here is the logical drawing size: it matches mouse coordinates and
## raylib drawing units, and on a HiDPI display it is smaller than the actual
## framebuffer in pixels. `scale!` is the factor between the two, and it is what
## makes the resolution of a `Capture` explainable: a capture is taken from the
## framebuffer, so a `960 x 640` window on a display with a scale of `2` records
## `1920 x 1280` pixels.
##
## Use `focused` and `minimized` to pause input or skip expensive work while the
## window is inactive.
##
## The two verbs mean different things. A `suggest_*` call asks the window
## manager for something it may decline, reshape, or apply later --
## `suggest_size!`, `suggest_min_size!`, `suggest_position!`,
## `suggest_monitor!` -- so nothing here reports what happened and the next
## `Snapshot` is the authoritative answer. A `set_*` call changes something the
## host itself owns -- `set_target_fps!`, `set_clipboard_text!` -- and takes
## effect as asked.
import rrt.Window as RrtWindow
import HostHost

Window := [].{

	## Window geometry and visibility sampled once for this cycle.
	##
	## `size` is the logical drawing size, `focused` says whether the window has
	## keyboard focus, and `minimized` says whether it is minimized. A minimized
	## window still runs the frame loop.
	##
	## Declared in the `roc-ray-types` package's `Window` and re-exported here;
	## `App.Input` carries one as `input.window`.
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
	## Legal in `init!`, `update!`, and tasks; refused in `render!`. The windowing
	## backend only answers on the thread that owns the window, and the read is a
	## pointer copy rather than I/O, so this does not wait.
	##
	## Content that is not text, or is larger than the host will copy into a
	## `Str`, is refused rather than truncated.
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

	## How many framebuffer pixels one logical unit is, per axis.
	##
	## Legal in any callback, `render!` included. Reading a factor the backend
	## already holds costs nothing and allocates nothing.
	##
	## `1` on an ordinary display and `2` on a doubled HiDPI one; the two axes can
	## differ. Multiply a `Snapshot` size or a `Draw.FrameSize` by this to get the
	## pixel resolution a `Capture` records at.
	scale! : () => { x : F32, y : F32 }
	scale! = || HostHost.window_scale_dpi!()

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
	monitors! = || List.map(HostHost.monitors!(), monitor_from_host)

	## Suggest where the window's top-left corner should sit, in
	## virtual-desktop coordinates.
	##
	## The window manager controls the resulting geometry, and a position
	## outside every monitor may be adjusted or ignored. Pair it with
	## `monitors!` to place a window on a chosen display.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	suggest_position! : { x : I32, y : I32 } => {}
	suggest_position! = |position| HostHost.suggest_window_position!(position)

	## Suggest which monitor the window should move to, by `Monitor.index`.
	##
	## An index outside the connected set is ignored: which monitors exist can
	## change between reading `monitors!` and acting on one, so a stale index is
	## an ordinary race rather than a fault to report.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	suggest_monitor! : I32 => {}
	suggest_monitor! = |index| HostHost.suggest_window_monitor!(index)
}

## Group the host's flat monitor record into the shape applications read.
monitor_from_host : HostHost.MonitorInfo -> Window.Monitor
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
