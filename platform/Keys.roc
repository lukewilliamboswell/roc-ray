## Keys module - keyboard state and key constants
##
## Key state encoding:
## - 0 = Up (not pressed)
## - 1 = Down (currently held)
##
## Provides functions to check keyboard state from raw key state bytes
## (one byte per raylib key code 0-348)
Keys := [].{

	## Keyboard key type - use tag literals like KeyA, KeyW, etc.
	KeyboardKey : [KeyA, KeyD, KeyS, KeyW, KeySpace, KeyEnter]

	## raylib key code for a key (index into the Host key-state lists).
	key_code : KeyboardKey -> U64
	key_code = |key|
		match key {
			KeyA => 65
			KeyD => 68
			KeyS => 83
			KeyW => 87
			KeySpace => 32
			KeyEnter => 257
		}

	## Check if a specific key is currently held down. Pass `host.keys`.
	key_down : List(U8), KeyboardKey -> Bool
	key_down = |keys, key|
		match List.get(keys, key_code(key)) {
			Ok(state) => state == 1
			Err(_) => False
		}

	## Check if a specific key is currently not pressed (up). Pass `host.keys`.
	key_up : List(U8), KeyboardKey -> Bool
	key_up = |keys, key| !(key_down(keys, key))

	## Check if a key was first pressed this frame (edge), respecting key
	## repeat. Pass `host.keys_pressed`. Use for one-shot actions like
	## restart/menu where holding the key shouldn't re-trigger every frame.
	key_pressed : List(U8), KeyboardKey -> Bool
	key_pressed = |keys_pressed, key|
		match List.get(keys_pressed, key_code(key)) {
			Ok(state) => state == 1
			Err(_) => False
		}

}
