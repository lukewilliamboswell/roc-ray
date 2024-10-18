module [Keys, KeyboardKey, down, up, pressed, released, pressedRepeat]

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
