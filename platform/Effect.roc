hosted Effect
    exposes [
        Texture,
        setWindowSize!,
        getScreenSize!,
        exit!,
        drawText!,
        measureText!,
        setWindowTitle!,
        setBackgroundColor!,
        drawLine!,
        drawRectangle!,
        drawRectangleGradientV!,
        drawRectangleGradientH!,
        drawCircle!,
        drawCircleGradient!,
        setTargetFPS!,
        setDrawFPS!,
        takeScreenshot!,
        createCamera!,
        updateCamera!,
        beginMode2D!,
        endMode2D!,
        log!,
        toLogLevel,
        loadTexture!,
        drawTextureRec!,
    ]
    imports []

import InternalColor exposing [RocColor]
import InternalVector exposing [RocVector2]
import InternalRectangle exposing [RocRectangle]

setWindowSize! : I32, I32 -> {}
getScreenSize! : {} -> { height : I32, width : I32, z : I64 }

exit! : {} -> {}

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

log! : Str, I32 -> {}

drawText! : RocVector2, I32, Str, RocColor -> {}
measureText! : Str, I32 -> I64

setWindowTitle! : Str -> {}
setBackgroundColor! : RocColor -> {}

drawLine! : RocVector2, RocVector2, RocColor -> {}

drawRectangle! : RocRectangle, RocColor -> {}
drawRectangleGradientV! : RocRectangle, RocColor, RocColor -> {}
drawRectangleGradientH! : RocRectangle, RocColor, RocColor -> {}
drawCircle! : RocVector2, F32, RocColor -> {}
drawCircleGradient! : RocVector2, F32, RocColor, RocColor -> {}

setTargetFPS! : I32 -> {}
setDrawFPS! : Bool, I32, I32 -> {}

takeScreenshot! : Str -> {}

createCamera! : F32, F32, F32, F32, F32, F32 -> U64
updateCamera! : U64, F32, F32, F32, F32, F32, F32 -> {}

beginMode2D! : U64 -> {}
endMode2D! : U64 -> {}

Texture := Box {}

loadTexture! : Str -> Result Texture Str
drawTextureRec! : Texture, RocRectangle, RocVector2, RocColor -> {}
