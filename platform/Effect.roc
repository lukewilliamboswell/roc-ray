hosted Effect
    exposes [
        Effect,
        after,
        map,
        always,
        forever,
        loop,
        setWindowSize,
        getScreenSize,
        drawGuiButton,
        exit,
        drawText,
        setWindowTitle,
        drawRectangle,
        guiWindowBox,
        getMousePosition,
        isMouseButtonPressed,
    ]
    imports []
    generates Effect with [after, map, always, forever, loop]

setWindowSize : I32, I32 -> Effect {}
getScreenSize : Effect { height : I32, width : I32 }
drawGuiButton : F32, F32, F32, F32, Str -> Effect I32
exit : Effect {}
drawText : I32, I32, I32, Str, U8, U8, U8, U8 -> Effect {}
setWindowTitle : Str -> Effect {}
drawRectangle : I32, I32, I32, I32, U8, U8, U8, U8 -> Effect {}

guiWindowBox : F32, F32, F32, F32, Str -> Effect I32
getMousePosition : Effect { x : F32, y : F32 }
isMouseButtonPressed : I32 -> Effect Bool
