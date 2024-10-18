hosted Effect
    exposes [
        Rectangle,
        Vector2,
        HostColor,
        setWindowSize,
        getScreenSize,
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
        setTargetFPS,
        setDrawFPS,
        takeScreenshot,
        createCamera,
        updateCamera,
        beginMode2D,
        endMode2D,
        log,
        toLogLevel,
        loadTexture,
        drawTextureRec,
    ]
    imports []

Rectangle : {
    x : F32,
    y : F32,
    width : F32,
    height : F32,
}

Vector2 : {
    x : F32,
    y : F32,
}

HostColor : {
    # this is a hack to work around https://github.com/roc-lang/roc/issues/7142
    unused : I64,
    unused2 : I64,
    r : U8,
    g : U8,
    b : U8,
    a : U8,
}

setWindowSize : I32, I32 -> Task {} {}
getScreenSize : Task { height : I32, width : I32, z : I64 } {}

exit : Task {} {}

toLogLevel : _ -> I32
toLogLevel = \level ->
    when level is
        LogAll -> 0
        LogTrace -> 1
        LogDebug -> 2
        LogInfo -> 3
        LogWarning -> 4
        LogError -> 5
        LogFatal -> 6
        LogNone -> 7

log : Str, I32 -> Task {} {}

drawText : F32, F32, I32, Str, U8, U8, U8, U8 -> Task {} {}
measureText : Str, I32 -> Task I64 {}

setWindowTitle : Str -> Task {} {}
setBackgroundColor : HostColor -> Task {} {}

drawLine : F32, F32, F32, F32, U8, U8, U8, U8 -> Task {} {}
drawRectangle : F32, F32, F32, F32, U8, U8, U8, U8 -> Task {} {}
drawRectangleGradient : F32, F32, F32, F32, U8, U8, U8, U8, U8, U8, U8, U8 -> Task {} {}
drawCircle : F32, F32, F32, U8, U8, U8, U8 -> Task {} {}
drawCircleGradient : F32, F32, F32, U8, U8, U8, U8, U8, U8, U8, U8 -> Task {} {}

setTargetFPS : I32 -> Task {} {}
setDrawFPS : Bool, I32, I32 -> Task {} {}

takeScreenshot : Str -> Task {} {}

createCamera : F32, F32, F32, F32, F32, F32 -> Task U64 {}
updateCamera : U64, F32, F32, F32, F32, F32, F32 -> Task {} {}

beginMode2D : U64 -> Task {} {}
endMode2D : U64 -> Task {} {}

loadTexture : Str -> Task (Box {}) Str

drawTextureRec : Box {}, Rectangle, Vector2, HostColor -> Task {} {}
