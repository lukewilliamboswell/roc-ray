module [Keys, KeyboardKey, down]

import InternalKeyboard

KeyboardKey : InternalKeyboard.KeyboardKey

# TODO replace with opaque thing
Keys : Dict InternalKeyboard.KeyboardKey InternalKeyboard.KeyState

down : Keys, KeyboardKey -> Bool
down = \keys, key ->
    state = Dict.get keys key
    state == Ok Down
