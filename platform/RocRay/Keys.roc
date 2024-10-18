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

Keys : Dict InternalKeyboard.KeyboardKey InternalKeyboard.KeyState

down : Keys, KeyboardKey -> Bool
down = \keys, key ->
    state = Dict.get keys key
    state == Ok Down || state == Ok PressedRepeat

up : Keys, KeyboardKey -> Bool
up = \keys, key ->
    state = Dict.get keys key
    state == Ok Up

pressed : Keys, KeyboardKey -> Bool
pressed = \keys, key ->
    state = Dict.get keys key
    state == Ok Pressed

released : Keys, KeyboardKey -> Bool
released = \keys, key ->
    state = Dict.get keys key
    state == Ok Down

pressedRepeat : Keys, KeyboardKey -> Bool
pressedRepeat = \keys, key ->
    state = Dict.get keys key
    state == Ok PressedRepeat

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
