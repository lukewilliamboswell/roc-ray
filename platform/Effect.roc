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
        isMouseButtonPressed,
    ]
    imports []

setWindowSize : I32, I32 -> Task {} {}
getScreenSize : Task { height : I32, width : I32 } {}
drawGuiButton : F32, F32, F32, F32, Str -> Task I32 {}
exit : Task {} {}

drawText : I32, I32, I32, Str, U8, U8, U8, U8 -> Task {} {}
measureText : Str, I32 -> Task I32 {}

setWindowTitle : Str -> Task {} {}

drawRectangle : I32, I32, I32, I32, U8, U8, U8, U8 -> Task {} {}
drawRectangleGradientV : I32, I32, I32, I32, U8, U8, U8, U8, U8, U8, U8, U8 -> Task {} {}
drawCircle : I32, I32, F32, U8, U8, U8, U8 -> Task {} {}
drawCircleGradient : I32, I32, F32, U8, U8, U8, U8, U8, U8, U8, U8 -> Task {} {}

guiWindowBox : F32, F32, F32, F32, Str -> Task I32 {}
getMousePosition : Task { x : F32, y : F32 } {}
isMouseButtonPressed : I32 -> Task Bool {}
