hosted Effect
    exposes [
        Texture,
        Sound,
        setWindowSize,
        getScreenSize,
        exit,
        drawText,
        measureText,
        setWindowTitle,
        drawLine,
        drawRectangle,
        drawRectangleGradientV,
        drawRectangleGradientH,
        drawCircle,
        drawCircleGradient,
        setTargetFPS,
        setDrawFPS,
        takeScreenshot,
        createCamera,
        updateCamera,
        beginDrawing,
        endDrawing,
        beginMode2D,
        endMode2D,
        log,
        toLogLevel,
        loadTexture,
        drawTextureRec,
        loadSound,
        playSound,
    ]
    imports []

import InternalColor exposing [RocColor]
import InternalVector exposing [RocVector2]
import InternalRectangle exposing [RocRectangle]

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

drawText : RocVector2, I32, Str, RocColor -> Task {} {}
measureText : Str, I32 -> Task I64 {}

setWindowTitle : Str -> Task {} {}

drawLine : RocVector2, RocVector2, RocColor -> Task {} {}

drawRectangle : RocRectangle, RocColor -> Task {} {}
drawRectangleGradientV : RocRectangle, RocColor, RocColor -> Task {} {}
drawRectangleGradientH : RocRectangle, RocColor, RocColor -> Task {} {}
drawCircle : RocVector2, F32, RocColor -> Task {} {}
drawCircleGradient : RocVector2, F32, RocColor, RocColor -> Task {} {}

setTargetFPS : I32 -> Task {} {}
setDrawFPS : Bool, I32, I32 -> Task {} {}

takeScreenshot : Str -> Task {} {}

createCamera : RocVector2, RocVector2, F32, F32 -> Task U64 {}
updateCamera : U64, RocVector2, RocVector2, F32, F32 -> Task {} {}

beginDrawing : RocColor -> Task {} {}
endDrawing : Task {} {}
beginMode2D : U64 -> Task {} {}
endMode2D : U64 -> Task {} {}

Texture := Box {}
loadTexture : Str -> Task Texture Str
drawTextureRec : Texture, RocRectangle, RocVector2, RocColor -> Task {} {}

Sound := Box {}
loadSound : Str -> Task Sound Str
playSound : Sound -> Task {} {}
