## Keyboard state and the key constants that name it.
##
## Read keys through `Devices.Snapshot` receivers such as `key_down`,
## `key_pressed`, and `key_released`.
##
## Named keys cover the raylib keyboard enum. `from_code` validates a
## backend-specific raw key code.
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

	## Validate and wrap a raw raylib key code.
	from_code : U64 -> Try(Key, [InvalidKeyCode, ..])
	from_code = |code|
		if code < key_count {
			Ok(Raw(code))
		} else {
			Err(InvalidKeyCode)
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
	## in the next input and held in neither. Pass `host` directly.
	key_pressed : { keys : List(U8), ..state }, Key -> Bool
	key_pressed = |host, key| key_state(host.keys, key, 2)

	## Check if a key was released at least once since the previous input. Pass
	## `host` directly.
	key_released : { keys : List(U8), ..state }, Key -> Bool
	key_released = |host, key| key_state(host.keys, key, 4)

	expect key_code(KeyA) == 65
	expect key_code(KeyEscape) == 256
	expect key_code(KeyLeftShift) == 340
	expect from_code(262) == Ok(Raw(262))
	expect from_code(key_count) == Err(InvalidKeyCode)
	expect key_down({ keys: [7] }, Raw(0)) and key_pressed({ keys: [7] }, Raw(0)) and key_released({ keys: [7] }, Raw(0))

}

key_count : U64
key_count = 349

key_state : List(U8), Keys.Key, U8 -> Bool
key_state = |states, key, mask|
	match List.get(states, Keys.key_code(key)) {
		Ok(state) => U8.bitwise_and(state, mask) != 0
		Err(_) => False
	}
