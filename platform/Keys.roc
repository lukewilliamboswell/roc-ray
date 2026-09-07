## Keyboard state and the key constants that name it.
##
## Read a key through the snapshot `App.Input` carries --
## `input.devices.key_pressed(KeySpace)` -- rather than through the packed
## bytes. `set_source!` and `set_text!` are the other half: they let a run
## drive its own keyboard, which is what a scripted demo or a headless test
## needs.
##
import Host

Keys := [].{

	## Named raylib keyboard keys plus a validated backend-specific escape hatch.
	Key := [
		KeyAndroidBack,
		KeyAndroidMenu,
		KeyVolumeUp,
		KeyVolumeDown,
		KeyApostrophe,
		KeyComma,
		KeyMinus,
		KeyPeriod,
		KeySlash,
		Key0,
		Key1,
		Key2,
		Key3,
		Key4,
		Key5,
		Key6,
		Key7,
		Key8,
		Key9,
		KeySemicolon,
		KeyEqual,
		KeyA,
		KeyB,
		KeyC,
		KeyD,
		KeyE,
		KeyF,
		KeyG,
		KeyH,
		KeyI,
		KeyJ,
		KeyK,
		KeyL,
		KeyM,
		KeyN,
		KeyO,
		KeyP,
		KeyQ,
		KeyR,
		KeyS,
		KeyT,
		KeyU,
		KeyV,
		KeyW,
		KeyX,
		KeyY,
		KeyZ,
		KeyLeftBracket,
		KeyBackslash,
		KeyRightBracket,
		KeyGrave,
		KeySpace,
		KeyEscape,
		KeyEnter,
		KeyTab,
		KeyBackspace,
		KeyInsert,
		KeyDelete,
		KeyRight,
		KeyLeft,
		KeyDown,
		KeyUp,
		KeyPageUp,
		KeyPageDown,
		KeyHome,
		KeyEnd,
		KeyCapsLock,
		KeyScrollLock,
		KeyNumLock,
		KeyPrintScreen,
		KeyPause,
		KeyF1,
		KeyF2,
		KeyF3,
		KeyF4,
		KeyF5,
		KeyF6,
		KeyF7,
		KeyF8,
		KeyF9,
		KeyF10,
		KeyF11,
		KeyF12,
		KeyLeftShift,
		KeyLeftControl,
		KeyLeftAlt,
		KeyLeftSuper,
		KeyRightShift,
		KeyRightControl,
		KeyRightAlt,
		KeyRightSuper,
		KeyKbMenu,
		KeyKp0,
		KeyKp1,
		KeyKp2,
		KeyKp3,
		KeyKp4,
		KeyKp5,
		KeyKp6,
		KeyKp7,
		KeyKp8,
		KeyKp9,
		KeyKpDecimal,
		KeyKpDivide,
		KeyKpMultiply,
		KeyKpSubtract,
		KeyKpAdd,
		KeyKpEnter,
		KeyKpEqual,
		Raw(U64),
	].{

		## Compare two of these values.
		is_eq : _
	}

	## Which key, if any, closes the window. `NoExitKey` disables the behaviour.
	ExitKey := [NoExitKey, ExitKey(Key)].{

		## Compare two of these values.
		is_eq : _
	}

	## Flatten an exit key to the raylib key code the host passes to
	## `SetExitKey`. `0` is raylib's `KEY_NULL`, which disables the behaviour.
	## Shared by startup configuration and the runtime `SetExitKey` command so the
	## two encodings cannot drift.
	exit_key_code : ExitKey -> I32
	exit_key_code = |value|
		match value {
			NoExitKey => 0
			ExitKey(key) => U64.to_i32_wrap(Keys.key_code(key))
		}

	## Validate a raw raylib key code and name it.
	##
	## A code with a named key decodes to that key, so a value that came from
	## the host -- a `Devices.Event` -- pattern-matches on `KeyA` exactly as
	## one written in the app does. A code in range with no name is `Raw`.
	from_code : U64 -> Try(Key, [InvalidKeyCode, ..])
	from_code = |code|
		match code {
			4 => Ok(KeyAndroidBack)
			5 => Ok(KeyAndroidMenu)
			24 => Ok(KeyVolumeUp)
			25 => Ok(KeyVolumeDown)
			32 => Ok(KeySpace)
			39 => Ok(KeyApostrophe)
			44 => Ok(KeyComma)
			45 => Ok(KeyMinus)
			46 => Ok(KeyPeriod)
			47 => Ok(KeySlash)
			48 => Ok(Key0)
			49 => Ok(Key1)
			50 => Ok(Key2)
			51 => Ok(Key3)
			52 => Ok(Key4)
			53 => Ok(Key5)
			54 => Ok(Key6)
			55 => Ok(Key7)
			56 => Ok(Key8)
			57 => Ok(Key9)
			59 => Ok(KeySemicolon)
			61 => Ok(KeyEqual)
			65 => Ok(KeyA)
			66 => Ok(KeyB)
			67 => Ok(KeyC)
			68 => Ok(KeyD)
			69 => Ok(KeyE)
			70 => Ok(KeyF)
			71 => Ok(KeyG)
			72 => Ok(KeyH)
			73 => Ok(KeyI)
			74 => Ok(KeyJ)
			75 => Ok(KeyK)
			76 => Ok(KeyL)
			77 => Ok(KeyM)
			78 => Ok(KeyN)
			79 => Ok(KeyO)
			80 => Ok(KeyP)
			81 => Ok(KeyQ)
			82 => Ok(KeyR)
			83 => Ok(KeyS)
			84 => Ok(KeyT)
			85 => Ok(KeyU)
			86 => Ok(KeyV)
			87 => Ok(KeyW)
			88 => Ok(KeyX)
			89 => Ok(KeyY)
			90 => Ok(KeyZ)
			91 => Ok(KeyLeftBracket)
			92 => Ok(KeyBackslash)
			93 => Ok(KeyRightBracket)
			96 => Ok(KeyGrave)
			256 => Ok(KeyEscape)
			257 => Ok(KeyEnter)
			258 => Ok(KeyTab)
			259 => Ok(KeyBackspace)
			260 => Ok(KeyInsert)
			261 => Ok(KeyDelete)
			262 => Ok(KeyRight)
			263 => Ok(KeyLeft)
			264 => Ok(KeyDown)
			265 => Ok(KeyUp)
			266 => Ok(KeyPageUp)
			267 => Ok(KeyPageDown)
			268 => Ok(KeyHome)
			269 => Ok(KeyEnd)
			280 => Ok(KeyCapsLock)
			281 => Ok(KeyScrollLock)
			282 => Ok(KeyNumLock)
			283 => Ok(KeyPrintScreen)
			284 => Ok(KeyPause)
			290 => Ok(KeyF1)
			291 => Ok(KeyF2)
			292 => Ok(KeyF3)
			293 => Ok(KeyF4)
			294 => Ok(KeyF5)
			295 => Ok(KeyF6)
			296 => Ok(KeyF7)
			297 => Ok(KeyF8)
			298 => Ok(KeyF9)
			299 => Ok(KeyF10)
			300 => Ok(KeyF11)
			301 => Ok(KeyF12)
			320 => Ok(KeyKp0)
			321 => Ok(KeyKp1)
			322 => Ok(KeyKp2)
			323 => Ok(KeyKp3)
			324 => Ok(KeyKp4)
			325 => Ok(KeyKp5)
			326 => Ok(KeyKp6)
			327 => Ok(KeyKp7)
			328 => Ok(KeyKp8)
			329 => Ok(KeyKp9)
			330 => Ok(KeyKpDecimal)
			331 => Ok(KeyKpDivide)
			332 => Ok(KeyKpMultiply)
			333 => Ok(KeyKpSubtract)
			334 => Ok(KeyKpAdd)
			335 => Ok(KeyKpEnter)
			336 => Ok(KeyKpEqual)
			340 => Ok(KeyLeftShift)
			341 => Ok(KeyLeftControl)
			342 => Ok(KeyLeftAlt)
			343 => Ok(KeyLeftSuper)
			344 => Ok(KeyRightShift)
			345 => Ok(KeyRightControl)
			346 => Ok(KeyRightAlt)
			347 => Ok(KeyRightSuper)
			348 => Ok(KeyKbMenu)
			_ => if code < key_count Ok(Raw(code)) else Err(InvalidKeyCode)
		}

	## raylib key code for a key (index into the snapshot key-state list).
	key_code : Key -> U64
	key_code = |key|
		match key {
			KeyAndroidBack => 4
			KeyAndroidMenu => 5
			KeyVolumeUp => 24
			KeyVolumeDown => 25
			KeyApostrophe => 39
			KeyComma => 44
			KeyMinus => 45
			KeyPeriod => 46
			KeySlash => 47
			Key0 => 48
			Key1 => 49
			Key2 => 50
			Key3 => 51
			Key4 => 52
			Key5 => 53
			Key6 => 54
			Key7 => 55
			Key8 => 56
			Key9 => 57
			KeySemicolon => 59
			KeyEqual => 61
			KeyA => 65
			KeyB => 66
			KeyC => 67
			KeyD => 68
			KeyE => 69
			KeyF => 70
			KeyG => 71
			KeyH => 72
			KeyI => 73
			KeyJ => 74
			KeyK => 75
			KeyL => 76
			KeyM => 77
			KeyN => 78
			KeyO => 79
			KeyP => 80
			KeyQ => 81
			KeyR => 82
			KeyS => 83
			KeyT => 84
			KeyU => 85
			KeyV => 86
			KeyW => 87
			KeyX => 88
			KeyY => 89
			KeyZ => 90
			KeyLeftBracket => 91
			KeyBackslash => 92
			KeyRightBracket => 93
			KeyGrave => 96
			KeySpace => 32
			KeyEscape => 256
			KeyEnter => 257
			KeyTab => 258
			KeyBackspace => 259
			KeyInsert => 260
			KeyDelete => 261
			KeyRight => 262
			KeyLeft => 263
			KeyDown => 264
			KeyUp => 265
			KeyPageUp => 266
			KeyPageDown => 267
			KeyHome => 268
			KeyEnd => 269
			KeyCapsLock => 280
			KeyScrollLock => 281
			KeyNumLock => 282
			KeyPrintScreen => 283
			KeyPause => 284
			KeyF1 => 290
			KeyF2 => 291
			KeyF3 => 292
			KeyF4 => 293
			KeyF5 => 294
			KeyF6 => 295
			KeyF7 => 296
			KeyF8 => 297
			KeyF9 => 298
			KeyF10 => 299
			KeyF11 => 300
			KeyF12 => 301
			KeyKp0 => 320
			KeyKp1 => 321
			KeyKp2 => 322
			KeyKp3 => 323
			KeyKp4 => 324
			KeyKp5 => 325
			KeyKp6 => 326
			KeyKp7 => 327
			KeyKp8 => 328
			KeyKp9 => 329
			KeyKpDecimal => 330
			KeyKpDivide => 331
			KeyKpMultiply => 332
			KeyKpSubtract => 333
			KeyKpAdd => 334
			KeyKpEnter => 335
			KeyKpEqual => 336
			KeyLeftShift => 340
			KeyLeftControl => 341
			KeyLeftAlt => 342
			KeyLeftSuper => 343
			KeyRightShift => 344
			KeyRightControl => 345
			KeyRightAlt => 346
			KeyRightSuper => 347
			KeyKbMenu => 348
			Raw(code) => code
		}

	## Check if a specific key is held down at the cycle boundary. A state
	## sample. Pass `host` directly.
	key_down : { keys : List(U8), ..state }, Key -> Bool
	key_down = |host, key| key_state(host.keys, key, 1)

	## Check if a specific key is up at the cycle boundary. Pass `host` directly.
	key_up : { keys : List(U8), ..state }, Key -> Bool
	key_up = |host, key| !(key_down(host, key))

	## Check if a key was pressed at least once since the previous input. An
	## interval event: a key tapped between two cycles is pressed and released
	## in the next input and held in neither. Coalesced per key; the ordered
	## record with every press is `Devices.Snapshot.events`. Pass `host`
	## directly.
	key_pressed : { keys : List(U8), ..state }, Key -> Bool
	key_pressed = |host, key| key_state(host.keys, key, 2)

	## Check if a key was released at least once since the previous input. Pass
	## `host` directly.
	key_released : { keys : List(U8), ..state }, Key -> Bool
	key_released = |host, key| key_state(host.keys, key, 4)

	expect key_code(KeyA) == 65
	expect key_code(KeyEscape) == 256
	expect key_code(KeyLeftShift) == 340
	expect from_code(262) == Ok(KeyRight)
	expect from_code(65) == Ok(KeyA)
	expect from_code(0) == Ok(Raw(0))
	expect from_code(key_code(KeyKbMenu)) == Ok(KeyKbMenu)
	expect from_code(key_code(Raw(7))) == Ok(Raw(7))
	expect from_code(key_count) == Err(InvalidKeyCode)
	expect key_down({ keys: [7] }, Raw(0)) and key_pressed({ keys: [7] }, Raw(0)) and key_released({ keys: [7] }, Raw(0))

	## Set which key closes the window.
	##
	## `NoExitKey` stops any key from closing it; raylib defaults to
	## `ExitKey(KeyEscape)`. The window close button is unaffected either way,
	## so an app that disables the exit key should still handle shutdown itself
	## by returning `Err(Exit(code))` from `update!`.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	set_exit_key! : ExitKey => {}
	set_exit_key! = |key| Host.keys_set_exit_key!(exit_key_code(key))

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
			Hardware => Host.capture_set_virtual_keys!({ active: Bool.False, keys: [] })
			Virtual(keys) => Host.capture_set_virtual_keys!({ active: Bool.True, keys: List.map(keys, key_code) })
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
	set_text! = |text| Host.capture_set_virtual_text!(text)
}

key_count : U64
key_count = 349

key_state : List(U8), Keys.Key, U8 -> Bool
key_state = |states, key, mask|
	match List.get(states, Keys.key_code(key)) {
		Ok(state) => U8.bitwise_and(state, mask) != 0
		Err(_) => False
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
