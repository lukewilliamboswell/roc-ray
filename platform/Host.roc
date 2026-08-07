## Host module - provides platform state and system effects
import Keys
import Mouse
import Gamepad
import AppConfig
import HostHost
import MouseHost

Host := {
	frame_count : U64,

	## Monotonic clock in nanoseconds, sampled at the start of this frame.
	## Counts up from window initialization and never goes backwards. Use it
	## for absolute timing (animations, scheduling, fixed-timestep loops).
	## See the `Time` module for converting nanosecond durations to seconds.
	timestamp_nanos : U64,

	## Seconds elapsed since the previous frame (0 on the first frame).
	## Multiply movement by this for frame-rate-independent motion, e.g.
	## `x + velocity * host.frame_time`.
	frame_time : F32,

	## Logical drawing dimensions sampled for this frame. These coordinates
	## match mouse input and raylib drawing units; they are not HiDPI framebuffer
	## pixel dimensions.
	screen : { width : I32, height : I32 },

	## Packed per-key state, updated in place by the host. Each byte stores held,
	## pressed-this-frame, and released-this-frame bits. Use the `Keys` helpers.
	keys : List(U8),

	## Unicode codepoints entered this frame, in input order. This is distinct
	## from physical key state and respects the active keyboard layout. The host
	## reuses capacity for empty and non-empty frames while this snapshot is
	## uniquely owned. Retaining an older snapshot triggers copy-on-write; growth
	## is needed only if the existing capacity is insufficient. At most 32
	## codepoints are delivered; excess queued input is drained.
	text_input : List(U32),

	## Gamepad input sampled once per frame. Use the `Gamepad` helpers rather
	## than indexing these persistent flat lists directly.
	gamepads : Gamepad.Snapshot,

	## Mouse buttons, position, delta, and two-axis wheel movement sampled once
	## for this frame. Receiver helpers are available on `Mouse.State`.
	mouse : Mouse.State,
}.{

	## Cursor visibility and capture policy applied with `host.set_cursor_mode!`.
	CursorMode : [Visible, Hidden, Locked]

	## Which key, if any, closes the window. Shared with the startup config, so
	## `App.default.with_exit_key(k)` and `host.set_exit_key!(k)` take the same
	## values.
	ExitKey : AppConfig.ExitKey

	## Check whether a key is currently held. Receiver form: `host.key_down(KeyW)`.
	key_down : Host, Keys.KeyboardKey -> Bool
	key_down = |host, key| Keys.key_down(host, key)

	## Check whether a key is currently up. Receiver form: `host.key_up(KeyW)`.
	key_up : Host, Keys.KeyboardKey -> Bool
	key_up = |host, key| Keys.key_up(host, key)

	## Check whether a key was pressed this frame. Receiver form:
	## `host.key_pressed(KeyW)`. Static `Keys.key_pressed(host, KeyW)` remains
	## available; combine singular queries with `or` when checking alternatives.
	key_pressed : Host, Keys.KeyboardKey -> Bool
	key_pressed = |host, key| Keys.key_pressed(host, key)

	## Check whether a key was released this frame. Receiver form:
	## `host.key_released(KeyW)`. Static `Keys.key_released(host, KeyW)` remains.
	key_released : Host, Keys.KeyboardKey -> Bool
	key_released = |host, key| Keys.key_released(host, key)

	## Resolve a gamepad slot in this frame's sampled snapshot. The returned pad
	## is snapshot-scoped; query it now rather than retaining it in the model.
	gamepad : Host, Gamepad.GamepadId -> [Connected(Gamepad.ConnectedPad), Disconnected]
	gamepad = |host, id| Gamepad.lookup(host.gamepads, id)

	## Exit the application with the given exit code.
	## The exit happens after the current frame completes to allow proper cleanup.
	exit! : Host, I32 => {}
	exit! = |_host, code| HostHost.exit!(code)

	## Read an environment variable by key.
	## Returns Ok with the value if found, or Err NotFound if not set.
	read_env! : Host, Str => Try(Str, [NotFound, ..])
	read_env! = |_host, key|
		match HostHost.read_env!(key) {
			Ok(value) => Ok(value)
			Err(NotFound) => Err(NotFound)
		}

	## Read a UTF-8 text file from disk.
	## Receiver form: `host.read_file!(path)`.
	read_file! : Host, Str => Try(Str, [NotFound, ReadFailed, ..])
	read_file! = |_host, path| {
		result = HostHost.read_file!(path)
		if result.ok {
			Ok(result.contents)
		} else if result.err == 1 {
			Err(NotFound)
		} else {
			Err(ReadFailed)
		}
	}

	## Get a random integer in the range [min, max] (both endpoints included).
	## The generator is seeded once at startup, so sequences differ between runs.
	## Derive other ranges/floats from this, e.g. a random direction with
	## `if host.random_i32!(0, 1) == 0 -1 else 1`.
	random_i32! : Host, I32, I32 => I32
	random_i32! = |_host, min, max| HostHost.random_i32!(min, max)

	## Set the window/screen size to positive integer dimensions.
	## Returns Err NotSupported on platforms that don't support window resizing (e.g., web).
	## Receiver form: `host.set_screen_size!(size)`.
	set_screen_size! : Host, { width : I32, height : I32 } => Try({}, [InvalidSize, NotSupported, ..])
	set_screen_size! = |_host, size|
		if size.width <= 0 or size.height <= 0 {
			Err(InvalidSize)
		} else {
			match HostHost.set_screen_size!(size) {
				Ok({}) => Ok({})
				Err(NotSupported) => Err(NotSupported)
			}
		}

	## Set the smallest window size the user can drag the window down to. Each
	## negative dimension is clamped to `0`, which leaves that axis
	## unconstrained. The minimum only applies to a resizable window, so pair it
	## with `App.default.with_resizable(Bool.True)`.
	## Receiver form: `host.set_window_min_size!(size)`.
	set_window_min_size! : Host, { width : I32, height : I32 } => {}
	set_window_min_size! = |_host, size|
		HostHost.set_window_min_size!({
			width: if size.width > 0 size.width else 0,
			height: if size.height > 0 size.height else 0,
		})

	## Set raylib's CPU-side frame-rate cap. Values at or below zero render
	## uncapped. This neither selects a software renderer nor controls VSync.
	## Note: On web/WASM, this has no effect as the browser controls frame timing.
	## Receiver form: `host.set_target_fps!(fps)`.
	set_target_fps! : Host, I32 => {}
	set_target_fps! = |_host, fps| HostHost.set_target_fps!(fps)

	## Set which key closes the window, or `NoExitKey` to stop any key from
	## closing it. raylib defaults to `ExitKey(KeyEscape)`. The window close
	## button is unaffected either way, so an app that disables the exit key
	## should still handle shutdown through `host.exit!`.
	## Receiver form: `host.set_exit_key!(NoExitKey)`.
	set_exit_key! : Host, ExitKey => {}
	set_exit_key! = |_host, key| HostHost.set_exit_key!(AppConfig.host_exit_key_code(key))

	## Read UTF-8 text from the system clipboard.
	## Returns `Err(Unavailable)` when the clipboard is empty, holds non-text
	## content, or the windowing backend refuses the request -- the underlying
	## platform does not distinguish these cases.
	## Receiver form: `host.get_clipboard_text!()`.
	get_clipboard_text! : Host => Try(Str, [Unavailable, ..])
	get_clipboard_text! = |_host|
		match HostHost.get_clipboard_text!() {
			Ok(text) => Ok(text)
			Err(Unavailable) => Err(Unavailable)
		}

	## Replace the system clipboard contents with UTF-8 text.
	## Receiver form: `host.set_clipboard_text!(text)`.
	set_clipboard_text! : Host, Str => {}
	set_clipboard_text! = |_host, text| HostHost.set_clipboard_text!(text)

	## Apply cursor visibility/capture atomically through one tagged operation.
	set_cursor_mode! : Host, CursorMode => {}
	set_cursor_mode! = |_host, mode| MouseHost.set_cursor_mode!(cursor_mode_code(mode))

	## Set the native operating-system cursor shape.
	set_cursor! : Host, Mouse.Cursor => {}
	set_cursor! = |_host, cursor| MouseHost.set_cursor!(cursor_code(cursor))
}

cursor_code : Mouse.Cursor -> U8
cursor_code = |cursor|
	match cursor {
		Default => 0
		Arrow => 1
		IBeam => 2
		Crosshair => 3
		PointingHand => 4
		ResizeEastWest => 5
		ResizeNorthSouth => 6
		ResizeNorthwestSoutheast => 7
		ResizeNortheastSouthwest => 8
		ResizeAll => 9
		NotAllowed => 10
	}

cursor_mode_code : Host.CursorMode -> U8
cursor_mode_code = |mode|
	match mode {
		Visible => 0
		Hidden => 1
		Locked => 2
	}

compose_public_validations : U64, U64 -> Try({}, [InvalidGamepadIndex, InvalidKeyCode, ..])
compose_public_validations = |gamepad_index, key_code| {
	_ = Gamepad.from_index(gamepad_index)?
	_ = Keys.from_code(key_code)?
	Ok({})
}

expect compose_public_validations(0, 0) == Ok({})
expect match compose_public_validations(4, 0) {
	Err(InvalidGamepadIndex) => Bool.True
	_ => Bool.False
}
expect match compose_public_validations(0, 999) {
	Err(InvalidKeyCode) => Bool.True
	_ => Bool.False
}
