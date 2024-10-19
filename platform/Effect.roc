hosted Effect
    exposes [
        Texture,
        setWindowSize,
        getScreenSize,
        exit,
        drawText,
        measureText,
        setWindowTitle,
        setBackgroundColor,
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
        beginMode2D,
        endMode2D,
        log,
        toLogLevel,
        fromRGBA,
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
setBackgroundColor : RocColor -> Task {} {}

drawLine : RocVector2, RocVector2, RocColor -> Task {} {}

drawRectangle : RocRectangle, RocColor -> Task {} {}
drawRectangleGradientV : RocRectangle, RocColor, RocColor -> Task {} {}
drawRectangleGradientH : RocRectangle, RocColor, RocColor -> Task {} {}
drawCircle : RocVector2, F32, RocColor -> Task {} {}
drawCircleGradient : RocVector2, F32, RocColor, RocColor -> Task {} {}

setTargetFPS : I32 -> Task {} {}
setDrawFPS : Bool, I32, I32 -> Task {} {}

takeScreenshot : Str -> Task {} {}

createCamera : F32, F32, F32, F32, F32, F32 -> Task U64 {}
updateCamera : U64, F32, F32, F32, F32, F32, F32 -> Task {} {}

beginMode2D : U64 -> Task {} {}
endMode2D : U64 -> Task {} {}

loadSound : Str -> Task U32 {}
playSound : U32 -> Task {} {}

Texture := Box {}
loadTexture : Str -> Task Texture Str
drawTextureRec : Texture, RocRectangle, RocVector2, RocColor -> Task {} {}

# HELPERS ---------------------------------------------------------------------

fromRGBA : { r : U8, g : U8, b : U8, a : U8 } -> Color
fromRGBA = \{ r, g, b, a } ->
    (Num.intCast a |> Num.shiftLeftBy 24)
    |> Num.bitwiseOr (Num.intCast b |> Num.shiftLeftBy 16)
    |> Num.bitwiseOr (Num.intCast g |> Num.shiftLeftBy 8)
    |> Num.bitwiseOr (Num.intCast r)
    |> @Color

expect
    a = fromRGBA { r: 255, g: 255, b: 255, a: 255 }
    a == @Color 0x00000000_FFFFFFFF

expect
    b = fromRGBA { r: 0, g: 0, b: 0, a: 0 }
    b == @Color 0x00000000_00000000

expect
    c = fromRGBA { r: 255, g: 0, b: 0, a: 0 }
    c == @Color 0x00000000_000000FF

expect
    d = fromRGBA { r: 0, g: 255, b: 0, a: 0 }
    d == @Color 0x00000000_0000FF00

expect
    d = fromRGBA { r: 0, g: 0, b: 255, a: 0 }
    d == @Color 0x00000000_00FF0000

expect
    d = fromRGBA { r: 0, g: 0, b: 0, a: 255 }
    d == @Color 0x00000000_FF000000
