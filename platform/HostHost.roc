## Internal operating-system and window transport.
##
## This module is intentionally not exposed by the platform package.
HostHost := [].{

	## Zero-sized startup capability constructed only by the platform adapter.
	Startup :: {}.{
		for_host : Startup
		for_host = Startup.({})
	}

	## A finished startup file read. `contents` is the file when `ok` is true;
	## `err` is `1` for a missing file and anything else for a failed read.
	ReadFileResult : {
		ok : Bool,
		err : U8,
		contents : Str,
	}

	## Ask the host to stop after `init!` returns.
	exit! : I32 => {}

	## The launcher's argv, with the host's own `--host-*` switches removed.
	args! : () => List(Str)

	## The clipboard as text, without distinguishing why it was not available.
	## `read_clipboard!` is the form that names the refusals.
	get_clipboard_text! : () => Try(Str, [Unavailable])

	## A clipboard read with the refusal codes `Window.ClipboardReadError`
	## names. `contents` is the clipboard when `err` is `0`.
	ClipboardResult : {
		err : U8,
		contents : Str,
	}

	read_clipboard! : () => ClipboardResult

	## An environment variable, or `NotFound` when it is not set.
	read_env! : Str => Try(Str, [NotFound])

	## Read a whole UTF-8 file, blocking the caller.
	read_file! : Str => ReadFileResult

	## One draw from the operating system's entropy source.
	##
	## Never fails: the implementation falls back to a less secure mechanism
	## rather than reporting that entropy is unavailable, because what this
	## seeds is a game's generator rather than a key.
	entropy! : () => U64

	## A number in the inclusive range `[min, max]`, from the backend's own
	## generator rather than from the operating system.
	random_i32! : I32, I32 => I32

	## Replace the clipboard with UTF-8 text.
	set_clipboard_text! : Str => {}

	## Set the raylib exit-key code; `0` disables the behaviour.
	set_exit_key! : I32 => {}

	## Ask the window manager for a logical window size. `NotSupported` is a
	## target whose windows cannot be resized, not a refused request.
	suggest_window_size! : { width : I32, height : I32 } => Try({}, [NotSupported])

	## Set raylib's CPU-side frame-rate cap; at or below zero is uncapped.
	set_target_fps! : I32 => {}

	## Set the smallest window size the user can drag down to. `0` in an axis
	## leaves it unconstrained.
	suggest_window_min_size! : { width : I32, height : I32 } => {}

	## The window's framebuffer-to-logical scale, one factor per axis.
	##
	## Non-positive or non-finite factors are replaced by `1` before they
	## cross, so the caller never has to defend against dividing by them.
	window_scale_dpi! : () => { x : F32, y : F32 }

	## One connected display, flattened for the wire. `Window.Monitor` is the
	## grouped shape an application sees; the nesting is done in Roc.
	MonitorInfo : {
		index : I32,
		name : Str,
		width : I32,
		height : I32,
		x : I32,
		y : I32,
		refresh_hz : I32,
	}

	## Every display the windowing backend can currently see, in its own order.
	monitors! : () => List(MonitorInfo)

	## Ask the window manager to move the window's top-left corner to a
	## position in virtual-desktop coordinates.
	suggest_window_position! : { x : I32, y : I32 } => {}

	## Ask the window manager to move the window to a monitor index. An index
	## outside the connected set is ignored.
	suggest_window_monitor! : I32 => {}
}
