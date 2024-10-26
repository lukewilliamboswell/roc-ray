hosted Effect
    exposes [
        Texture,
        RenderTexture,
        Sound,
        Camera,
        getScreenSize,
        exit,
        drawText,
        measureText,
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
        initWindow,
        beginDrawing,
        endDrawing,
        beginTexture,
        endTexture,
        beginMode2D,
        endMode2D,
        log,
        toLogLevel,
        loadTexture,
        drawTextureRec,
        loadSound,
        playSound,
        createRenderTexture,
        drawRenderTextureRec,
        loadFileToStr,
    ]
    imports []

import InternalColor exposing [RocColor]
import InternalVector exposing [RocVector2]
import InternalRectangle exposing [RocRectangle]

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

initWindow : Str, F32, F32 -> Task {} {}

drawText : RocVector2, I32, Str, RocColor -> Task {} {}
measureText : Str, I32 -> Task I64 {}

drawLine : RocVector2, RocVector2, RocColor -> Task {} {}

drawRectangle : RocRectangle, RocColor -> Task {} {}
drawRectangleGradientV : RocRectangle, RocColor, RocColor -> Task {} {}
drawRectangleGradientH : RocRectangle, RocColor, RocColor -> Task {} {}
drawCircle : RocVector2, F32, RocColor -> Task {} {}
drawCircleGradient : RocVector2, F32, RocColor, RocColor -> Task {} {}

setTargetFPS : I32 -> Task {} {}
setDrawFPS : Bool, I32, I32 -> Task {} {}

takeScreenshot : Str -> Task {} {}

beginDrawing : RocColor -> Task {} {}
endDrawing : Task {} {}

Camera := Box {}
createCamera : RocVector2, RocVector2, F32, F32 -> Task Camera {}
updateCamera : Camera, RocVector2, RocVector2, F32, F32 -> Task {} {}

beginMode2D : Camera -> Task {} {}
endMode2D : Camera -> Task {} {}

Texture := Box {}
loadTexture : Str -> Task Texture {}
drawTextureRec : Texture, RocRectangle, RocVector2, RocColor -> Task {} {}
drawRenderTextureRec : RenderTexture, RocRectangle, RocVector2, RocColor -> Task {} {}

Sound := Box {}
loadSound : Str -> Task Sound {}
playSound : Sound -> Task {} {}

RenderTexture := Box {}
createRenderTexture : RocVector2 -> Task RenderTexture {}
beginTexture : RenderTexture, RocColor -> Task {} {}
endTexture : RenderTexture -> Task {} {}

loadFileToStr : Str -> Task Str {}
