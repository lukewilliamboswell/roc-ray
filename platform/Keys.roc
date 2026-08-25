## Keyboard state and the key constants that name it.
##
## Read a key through the snapshot `App.Input` carries --
## `input.devices.key_pressed(KeySpace)` -- rather than through the packed
## bytes. `set_source!` and `set_text!` are the other half: they let a run
## drive its own keyboard, which is what a scripted demo or a headless test
## needs.
##
## The types and pure helpers live in the companion `roc-ray-types` package so
## reusable packages can depend on them without depending on this platform.
## This module re-exports them, so `Key` here and in the package are the
## same nominal type and values pass between them freely.
import rrt.Keys as RrtKeys
import HostHost
import CaptureHost

Keys := [].{

	## Named raylib keyboard keys plus a validated backend-specific escape hatch.
	##
	## Declared in the `roc-ray-types` package's `Keys` and re-exported here,
	## which is also where its receivers are documented.
	Key : RrtKeys.Key

	## Which key, if any, closes the window. `NoExitKey` disables the behaviour.
	ExitKey : RrtKeys.ExitKey

	## Flatten an exit key to the raylib key code the host passes to `SetExitKey`.
	exit_key_code : ExitKey -> I32
	exit_key_code = RrtKeys.exit_key_code

	## Validate and wrap a raw raylib key code.
	from_code : U64 -> Try(Key, [InvalidKeyCode, ..])
	from_code = RrtKeys.from_code

	## raylib key code for a key (index into the sampled key-state lists).
	key_code : Key -> U64
	key_code = RrtKeys.key_code

	## Check if a specific key is held down at this cycle's boundary. A state
	## sample. Pass `input.devices` directly.
	key_down : { keys : List(U8), ..state }, Key -> Bool
	key_down = RrtKeys.key_down

	## Check if a specific key is up at this cycle's boundary. Pass
	## `input.devices` directly.
	key_up : { keys : List(U8), ..state }, Key -> Bool
	key_up = RrtKeys.key_up

	## Check if a key was pressed at least once since the previous input.
	##
	## An interval event recorded from the window system, so a key that went
	## down and up between two cycles is still pressed (and released) in the
	## next input, never lost to frame timing. Presses of one key inside one
	## interval coalesce into one answer. Pass `input.devices` directly.
	key_pressed : { keys : List(U8), ..state }, Key -> Bool
	key_pressed = RrtKeys.key_pressed

	## Check if a key was released at least once since the previous input, with
	## the same guarantee as `key_pressed`. Pass `input.devices` directly.
	key_released : { keys : List(U8), ..state }, Key -> Bool
	key_released = RrtKeys.key_released

	## Set which key closes the window.
	##
	## `NoExitKey` stops any key from closing it; raylib defaults to
	## `ExitKey(KeyEscape)`. The window close button is unaffected either way,
	## so an app that disables the exit key should still handle shutdown itself
	## by returning `Err(Exit(code))` from `update!`.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	set_exit_key! : ExitKey => {}
	set_exit_key! = |key| HostHost.set_exit_key!(exit_key_code(key))

	## Where keyboard state comes from: the hardware, or a script.
	##
	## `Virtual` names the keys held down on the next frame, and only those.
	## The host runs the same derivation over a scripted source that it runs
	## over hardware, so a key that appears in one frame's list and not the
	## previous one is pressed, and one that disappears is released. Hardware
	## edges are shut out entirely while a script is the source.
	Source : [Hardware, Virtual(List(Key))]

	## A scripted source holding exactly these keys down.
	##
	## `Keys.holding([])` is a scripted keyboard with nothing held, which is not
	## the same as `Hardware`: it keeps the real keyboard shut out.
	holding : List(Key) -> Source
	holding = |keys| Virtual(keys)

	expect Keys.holding([KeySpace]) == Virtual([KeySpace])
	expect Keys.holding([]) != Hardware

	## Hand keyboard state to a scripted source, or back to the hardware keyboard.
	##
	## What the app reads is unchanged: `input.devices` still carries packed key
	## state and `Keys.key_pressed` still reports edges, so widget code cannot
	## tell a scripted key from a struck one. That is the point -- a recorded
	## demo or a headless test exercises the real input path rather than a
	## parallel fake one.
	##
	## The source installed on one cycle is what the host samples for the next,
	## the same way `Mouse.set_source!` places the pointer.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	##
	## ```roc
	## Keys.set_source!(Keys.holding([KeyRight]))
	## ```
	set_source! : Source => {}
	set_source! = |source|
		match source {
			Hardware => CaptureHost.set_virtual_keys!({ active: Bool.False, keys: [] })
			Virtual(keys) => CaptureHost.set_virtual_keys!({ active: Bool.True, keys: List.map(keys, key_code) })
		}

	## Codepoints for a string, ready for `Keys.set_text!`.
	##
	## `Keys.typing("hi")` is the two codepoints a keyboard would have queued
	## had those two characters been typed, so the layout-dependent text channel
	## is scripted with text rather than with key codes.
	typing : Str -> List(U32)
	typing = |text| codepoints(Str.to_utf8(text), 0, [])

	expect Keys.typing("") == []
	expect Keys.typing("hi") == [104, 105]

	## Two-, three- and four-byte sequences: cent sign, euro sign, and an emoji.
	expect Keys.typing("¢") == [0xa2]
	expect Keys.typing("€") == [0x20ac]
	expect Keys.typing("🎮") == [0x1f3ae]
	expect Keys.typing("a€b") == [97, 0x20ac, 98]

	## Enter text as though it had been typed on the next frame.
	##
	## Text is a separate channel from key state: it follows the active keyboard
	## layout, so a scripted key code cannot produce it and this cannot produce
	## key state. An app that reads both wants `Keys.set_source!` as well.
	##
	## The codepoints arrive on the next cycle's `input.devices.text_input` and
	## are gone the cycle after, the way a real keyboard's characters arrive on
	## one frame and not the next. At most 32 codepoints are delivered per
	## input; a longer script has the excess discarded and
	## `text_input_overflow` set, exactly as for hardware input.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	##
	## ```roc
	## Keys.set_text!(Keys.typing("hello"))
	## ```
	set_text! : List(U32) => {}
	set_text! = |text| CaptureHost.set_virtual_text!(text)
}

## Decode UTF-8 bytes to the codepoints they encode.
##
## `Str.to_utf8` answers well-formed UTF-8, so every continuation byte a lead
## byte announces is really there. A byte that cannot start a sequence is
## carried through as itself rather than rejected: no `Str` produces one, and a
## scripted keystroke is not worth a `Try` for a case that cannot arise.
codepoints : List(U8), U64, List(U32) -> List(U32)
codepoints = |bytes, index, acc|
	match List.get(bytes, index) {
		Err(_) => acc
		Ok(lead) => {
			width = sequence_width(lead)
			scalar = decode_sequence(bytes, index, lead, width)
			codepoints(bytes, index + width, List.append(acc, scalar))
		}
	}

## How many bytes the sequence starting with this byte occupies.
sequence_width : U8 -> U64
sequence_width = |lead|
	if lead < 0xc0 {
		1
	} else if lead < 0xe0 {
		2
	} else if lead < 0xf0 {
		3
	} else {
		4
	}

expect sequence_width(0x41) == 1
expect sequence_width(0xc2) == 2
expect sequence_width(0xe2) == 3
expect sequence_width(0xf0) == 4

## Combine a lead byte with its continuation bytes.
##
## Each continuation byte carries six bits, so the value is a base-64 number
## whose most significant digit is what the lead byte has left after its
## length marker.
decode_sequence : List(U8), U64, U8, U64 -> U32
decode_sequence = |bytes, index, lead, width|
	if width == 1 {
		U8.to_u32(lead)
	} else if width == 2 {
		U8.to_u32(lead - 0xc0) * 64 + continuation(bytes, index + 1)
	} else if width == 3 {
		U8.to_u32(lead - 0xe0) * 4096 + continuation(bytes, index + 1) * 64 + continuation(bytes, index + 2)
	} else {
		U8.to_u32(lead - 0xf0) * 262144
			+ continuation(bytes, index + 1) * 4096
			+ continuation(bytes, index + 2) * 64
			+ continuation(bytes, index + 3)
	}

## The six payload bits of a continuation byte, or zero where there is none.
continuation : List(U8), U64 -> U32
continuation = |bytes, index|
	match List.get(bytes, index) {
		Ok(byte) => U8.to_u32(byte % 64)
		Err(_) => 0
	}

expect continuation([0xa2], 0) == 0x22
expect continuation([], 0) == 0
