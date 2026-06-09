## Keys module - keyboard state and key constants.
##
## Key state encoding:
## - 0 = Up (not pressed)
## - 1 = Down (currently held, pressed this frame, or released this frame,
##   depending on which Host key-state list is passed)
##
## The host stores fixed-size state lists with one byte per raylib key code
## 0-348. Named keys cover the full raylib KeyboardKey enum. Use Raw(code)
## through `from_code` when you need a backend-specific escape hatch.
Keys := [].{

	key_count : U64
	key_count = 349

	KeyboardKey := [
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
	]

	## Validate and wrap a raw raylib key code.
	from_code : U64 -> Try(KeyboardKey, [InvalidKeyCode])
	from_code = |code|
		if code < key_count {
			Ok(Raw(code))
		} else {
			Err(InvalidKeyCode)
		}

	## raylib key code for a key (index into the Host key-state lists).
	key_code : KeyboardKey -> U64
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

	key_state : List(U8), KeyboardKey -> Bool
	key_state = |states, key|
		match List.get(states, key_code(key)) {
			Ok(state) => state == 1
			Err(_) => False
		}

	## Check if a specific key is currently held down. Pass `host.keys`.
	key_down : List(U8), KeyboardKey -> Bool
	key_down = |keys, key| key_state(keys, key)

	## Check if a specific key is currently not pressed (up). Pass `host.keys`.
	key_up : List(U8), KeyboardKey -> Bool
	key_up = |keys, key| !(key_down(keys, key))

	## Check if a key was first pressed this frame. Pass `host.keys_pressed`.
	key_pressed : List(U8), KeyboardKey -> Bool
	key_pressed = |keys_pressed, key| key_state(keys_pressed, key)

	## Check if a key was released this frame. Pass `host.keys_released`.
	key_released : List(U8), KeyboardKey -> Bool
	key_released = |keys_released, key| key_state(keys_released, key)

	expect key_code(KeyA) == 65
	expect key_code(KeyEscape) == 256
	expect key_code(KeyLeftShift) == 340
	expect from_code(262) == Ok(Raw(262))
	expect from_code(key_count) == Err(InvalidKeyCode)

}
