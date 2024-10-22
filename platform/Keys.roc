module [
    KeyboardKey,
    Keys,
    anyDown,
    anyPressed,
    anyReleased,
    anyUp,
    down,
    pressed,
    pressedRepeat,
    released,
    up,
]

import InternalKeyboard

KeyboardKey : InternalKeyboard.KeyboardKey

Keys : InternalKeyboard.Keys

down : Keys, KeyboardKey -> Bool
down = \keys, key ->
    when InternalKeyboard.readKey keys key is
        Down -> Bool.true
        PressedRepeat -> Bool.true
        _ -> Bool.false

up : Keys, KeyboardKey -> Bool
up = \keys, key ->
    when InternalKeyboard.readKey keys key is
        Up -> Bool.true
        _ -> Bool.false

pressed : Keys, KeyboardKey -> Bool
pressed = \keys, key ->
    when InternalKeyboard.readKey keys key is
        Pressed -> Bool.true
        _ -> Bool.false

released : Keys, KeyboardKey -> Bool
released = \keys, key ->
    when InternalKeyboard.readKey keys key is
        Released -> Bool.true
        _ -> Bool.false

pressedRepeat : Keys, KeyboardKey -> Bool
pressedRepeat = \keys, key ->
    when InternalKeyboard.readKey keys key is
        PressedRepeat -> Bool.true
        _ -> Bool.false

anyDown : Keys, List KeyboardKey -> Bool
anyDown = \keys, selection -> any keys selection down

anyUp : Keys, List KeyboardKey -> Bool
anyUp = \keys, selection -> any keys selection up

anyPressed : Keys, List KeyboardKey -> Bool
anyPressed = \keys, selection -> any keys selection pressed

anyReleased : Keys, List KeyboardKey -> Bool
anyReleased = \keys, selection -> any keys selection released

any : Keys, List KeyboardKey, (Keys, KeyboardKey -> Bool) -> Bool
any = \keys, selection, predicate ->
    List.any selection \k ->
        predicate keys k

expect
    bytes = List.repeat 2u8 350
    keys = InternalKeyboard.pack bytes
    down keys KeyLeft == Bool.true
