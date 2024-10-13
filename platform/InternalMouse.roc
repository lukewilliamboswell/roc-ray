module [MouseButton, mouseButtonFromU64]

MouseButton : [
    MouseButtonLeft,
    MouseButtonRight,
    MouseButtonMiddle,
    MouseButtonSide,
    MouseButtonExtra,
    MouseButtonForward,
    MouseButtonBack,
]

mouseButtonFromU64 : U64 -> MouseButton
mouseButtonFromU64 = \mouse ->
    if mouse == 0 then
        MouseButtonLeft
    else if mouse == 1 then
        MouseButtonRight
    else if mouse == 2 then
        MouseButtonMiddle
    else if mouse == 3 then
        MouseButtonSide
    else if mouse == 4 then
        MouseButtonExtra
    else if mouse == 5 then
        MouseButtonForward
    else if mouse == 6 then
        MouseButtonBack
    else
        crash "unreachable mouse button value from host"
