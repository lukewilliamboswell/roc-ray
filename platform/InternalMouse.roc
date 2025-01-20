module [MouseButton, mouse_button_from_u64, mouse_button_state_from_u8, ButtonState]

MouseButton : [
    MouseButtonLeft,
    MouseButtonRight,
    MouseButtonMiddle,
    MouseButtonSide,
    MouseButtonExtra,
    MouseButtonForward,
    MouseButtonBack,
]

mouse_button_from_u64 : U64 -> MouseButton
mouse_button_from_u64 = |mouse|
    when mouse is
        0 -> MouseButtonLeft
        1 -> MouseButtonRight
        2 -> MouseButtonMiddle
        3 -> MouseButtonSide
        4 -> MouseButtonExtra
        5 -> MouseButtonForward
        6 -> MouseButtonBack
        _ -> crash("unreachable mouse button from host")

ButtonState : [Up, Down, Pressed, Released]

mouse_button_state_from_u8 : U8 -> ButtonState
mouse_button_state_from_u8 = |n|
    when n is
        0 -> Pressed
        1 -> Released
        2 -> Down
        3 -> Up
        _ -> crash("unreachable mouse button state from host")
