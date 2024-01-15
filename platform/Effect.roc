hosted Effect
    exposes [
        Effect,
        after,
        map,
        always,
        forever,
        loop,
        setWindowSize,
        drawGuiButton,
        exit,
        drawText,
        setWindowTitle,
        drawRectangle,
    ]
    imports []
    generates Effect with [after, map, always, forever, loop]

setWindowSize : U32, U32 -> Effect {}
drawGuiButton : F32, F32, F32, F32, Str -> Effect I32
exit : Effect {}
drawText : I32, I32, I32, Str, U8, U8, U8, U8 -> Effect {}
setWindowTitle : Str -> Effect {}
drawRectangle : I32, I32, I32, I32, U8, U8, U8, U8 -> Effect {}
