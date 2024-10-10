hosted Effect
    exposes [
        setWindowSize,
        getScreenSize,
        drawGuiButton,
        exit,
        drawText,
        measureText,
        setWindowTitle,
        drawRectangle,
        drawRectangleGradientV,
        drawCircle,
        drawCircleGradient,
        guiWindowBox,
        getMousePosition,

        MouseButtons,
        mouseButtons,
    ]
    imports []

setWindowSize : I32, I32 -> Task {} {}
getScreenSize : Task { height : I32, width : I32, z : I64 } {}
drawGuiButton : F32, F32, F32, F32, Str -> Task I64 {}
exit : Task {} {}

drawText : I32, I32, I32, Str, U8, U8, U8, U8 -> Task {} {}
measureText : Str, I32 -> Task I64 {}

setWindowTitle : Str -> Task {} {}

drawRectangle : I32, I32, I32, I32, U8, U8, U8, U8 -> Task {} {}
drawRectangleGradientV : I32, I32, I32, I32, U8, U8, U8, U8, U8, U8, U8, U8 -> Task {} {}
drawCircle : I32, I32, F32, U8, U8, U8, U8 -> Task {} {}
drawCircleGradient : I32, I32, F32, U8, U8, U8, U8, U8, U8, U8, U8 -> Task {} {}

guiWindowBox : F32, F32, F32, F32, Str -> Task I64 {}
getMousePosition : Task { x : F32, y : F32, z: I64 } {}

MouseButtons : {
    # isn't used here it's a workaround for https://github.com/roc-lang/roc/issues/7142
    unused: I64,
    back: Bool,
    left: Bool,
    right: Bool,
    middle: Bool,
    side: Bool,
    extra: Bool,
    forward: Bool,
}

mouseButtons : Task MouseButtons {}
