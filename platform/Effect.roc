hosted Effect
    exposes [
        setWindowSize,
        getScreenSize,
        drawGuiButton,
        exit,
        drawText,
        measureText,
        setWindowTitle,
        setBackgroundColor,
        drawLine,
        drawRectangle,
        drawRectangleGradient,
        drawCircle,
        drawCircleGradient,
        guiWindowBox,
        getMousePosition,
        MouseButtons,
        mouseButtons,
        setTargetFPS,
        setDrawFPS,
        takeScreenshot,
        createCamera,
        updateCamera,
        beginMode2D,
        endMode2D,
    ]
    imports []

setWindowSize : I32, I32 -> Task {} {}
getScreenSize : Task { height : I32, width : I32, z : I64 } {}
drawGuiButton : F32, F32, F32, F32, Str -> Task I64 {}
exit : Task {} {}

drawText : F32, F32, I32, Str, U8, U8, U8, U8 -> Task {} {}
measureText : Str, I32 -> Task I64 {}

setWindowTitle : Str -> Task {} {}
setBackgroundColor : U8, U8, U8, U8 -> Task {} {}

drawLine : F32, F32, F32, F32, U8, U8, U8, U8 -> Task {} {}
drawRectangle : F32, F32, F32, F32, U8, U8, U8, U8 -> Task {} {}
drawRectangleGradient : F32, F32, F32, F32, U8, U8, U8, U8, U8, U8, U8, U8 -> Task {} {}
drawCircle : F32, F32, F32, U8, U8, U8, U8 -> Task {} {}
drawCircleGradient : F32, F32, F32, U8, U8, U8, U8, U8, U8, U8, U8 -> Task {} {}

guiWindowBox : F32, F32, F32, F32, Str -> Task I64 {}
getMousePosition : Task { x : F32, y : F32, z : I64 } {}

MouseButtons : {
    # isn't used here it's a workaround for https://github.com/roc-lang/roc/issues/7142
    unused : I64,
    back : Bool,
    left : Bool,
    right : Bool,
    middle : Bool,
    side : Bool,
    extra : Bool,
    forward : Bool,
}

mouseButtons : Task MouseButtons {}

setTargetFPS : I32 -> Task {} {}
setDrawFPS : Bool, F32, F32 -> Task {} {}

takeScreenshot : Str -> Task {} {}

createCamera : F32, F32, F32, F32, F32, F32 -> Task U64 {}
updateCamera : U64, F32, F32, F32, F32, F32, F32 -> Task {} {}

beginMode2D : U64 -> Task {} {}
endMode2D : U64 -> Task {} {}
