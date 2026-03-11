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
    KeyboardKey : [KeyA, KeyD, KeyS, KeyW]

    ## Check if a specific key is currently pressed (down)
    key_down : List(U8), KeyboardKey -> Bool
    key_down = |keys, key| {
        idx = match key {
            KeyA => 65
            KeyD => 68
            KeyS => 83
            KeyW => 87
        }
        match List.get(keys, idx) {
            Ok(state) => state == 1
            Err(_) => False
        }
    }

    ## Check if a specific key is currently not pressed (up)
    key_up : List(U8), KeyboardKey -> Bool
    key_up = |keys, key| !(key_down(keys, key))

}
