module [Buttons, ButtonState, down, pressed, released, up]

import Bool exposing [true, false]

ButtonState : [Up, Down, Pressed, Released]

Buttons : {
    left : ButtonState,
    right : ButtonState,
    middle : ButtonState,
    side : ButtonState,
    extra : ButtonState,
    forward : ButtonState,
    back : ButtonState,
}

up : ButtonState -> Bool
up = \state ->
    when state is
        Up -> true
        Released -> true
        Down -> false
        Pressed -> false

down : ButtonState -> Bool
down = \state ->
    when state is
        Down -> true
        Pressed -> true
        Up -> false
        Released -> false

pressed : ButtonState -> Bool
pressed = \state ->
    when state is
        Pressed -> true
        _ -> false

released : ButtonState -> Bool
released = \state ->
    when state is
        Released -> true
        _ -> false
