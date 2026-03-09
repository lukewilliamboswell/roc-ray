## Keys module - keyboard state and key constants
##
## Key state encoding:
## - 0 = Up (not pressed)
## - 1 = Down (currently held)
##
## Keys holds the raw key state bytes (one byte per raylib key code 0-348)
Keys := { data : List(U8) }.{

    ## Keyboard key codes (simplified to WASD for now)
    ## Create a Keys value from a raw key state list (used internally by the platform)
    pack : List(U8) -> Keys
    pack = |bytes| { data: bytes }

    KeyboardKey := [
        KeyA,
        KeyD,
        KeyS,
        KeyW,
    ].{

        ## Map a KeyboardKey to its raylib key code index
        key_to_index : KeyboardKey -> U64
        key_to_index = |key| {
            match key {
                KeyA => 65
                KeyD => 68
                KeyS => 83
                KeyW => 87
            }
        }

    }

    ## Check if a specific key is currently pressed (down)
    key_down : Keys, KeyboardKey -> Bool
    key_down = |keys, key| {
        idx = key.key_to_index()
        match keys.data.get(idx) {
            Ok(state) => state == 1
            Err(_) => False
        }
    }

    ## Check if a specific key is currently not pressed (up)
    key_up : Keys, KeyboardKey -> Bool
    key_up = |keys, key| !(key_down(keys, key))


}

