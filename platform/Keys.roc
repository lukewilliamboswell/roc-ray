module [
    KeyboardKey,
    Keys,
    any_down,
    any_pressed,
    any_released,
    any_up,
    down,
    pressed,
    pressed_repeat,
    released,
    up,
]

import InternalKeyboard

KeyboardKey : InternalKeyboard.KeyboardKey

Keys : InternalKeyboard.Keys

down : Keys, KeyboardKey -> Bool
down = |keys, key|
    when InternalKeyboard.read_key(keys, key) is
        Down -> Bool.true
        PressedRepeat -> Bool.true
        _ -> Bool.false

up : Keys, KeyboardKey -> Bool
up = |keys, key|
    when InternalKeyboard.read_key(keys, key) is
        Up -> Bool.true
        _ -> Bool.false

pressed : Keys, KeyboardKey -> Bool
pressed = |keys, key|
    when InternalKeyboard.read_key(keys, key) is
        Pressed -> Bool.true
        _ -> Bool.false

released : Keys, KeyboardKey -> Bool
released = |keys, key|
    when InternalKeyboard.read_key(keys, key) is
        Released -> Bool.true
        _ -> Bool.false

pressed_repeat : Keys, KeyboardKey -> Bool
pressed_repeat = |keys, key|
    when InternalKeyboard.read_key(keys, key) is
        PressedRepeat -> Bool.true
        _ -> Bool.false

any_down : Keys, List KeyboardKey -> Bool
any_down = |keys, selection| any(keys, selection, down)

any_up : Keys, List KeyboardKey -> Bool
any_up = |keys, selection| any(keys, selection, up)

any_pressed : Keys, List KeyboardKey -> Bool
any_pressed = |keys, selection| any(keys, selection, pressed)

any_released : Keys, List KeyboardKey -> Bool
any_released = |keys, selection| any(keys, selection, released)

any : Keys, List KeyboardKey, (Keys, KeyboardKey -> Bool) -> Bool
any = |keys, selection, predicate|
    List.any(
        selection,
        |k|
            predicate(keys, k),
    )

expect
    bytes = List.repeat(2u8, 350)
    keys = InternalKeyboard.pack(bytes)
    down(keys, KeyLeft) == Bool.true
