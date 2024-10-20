module [
    Program,
    PlatformState,
    KeyboardKey,
    Color,
    Rectangle,
    Vector2,
    Camera,
    Texture,
    Sound,
    setWindowSize,
    getScreenSize,
    exit,
    setWindowTitle,
    setTargetFPS,
    setDrawFPS,
    measureText,
    drawText,
    drawLine,
    drawRectangle,
    drawRectangleGradientV,
    drawRectangleGradientH,
    drawCircle,
    drawCircleGradient,
    rgba,
    takeScreenshot,
    createCamera,
    updateCamera,
    drawMode2D,
    log,
    loadTexture,
    drawTextureRec,
    loadSound,
    playSound,
    beginDrawing,
    endDrawing,
]

import RocRay.Keys as Keys
import RocRay.Mouse as Mouse
import Effect
import InternalKeyboard
import InternalColor
import InternalVector
import InternalRectangle

## Provide an initial state and a render function to the platform.
## ```
## {
##     init : Task state {},
##     render : state -> Task state {},
## }
## ```
Program state err : {
    init : Task state err,
    render : state, PlatformState -> Task state err,
} where err implements Inspect

PlatformState : {
    timestampMillis : U64,
    frameCount : U64,
    keys : Keys.Keys,
    mouse : {
        position : Vector2,
        buttons : Mouse.Buttons,
        wheel : F32,
    },
}

KeyboardKey : InternalKeyboard.KeyboardKey

## Represents a rectangle.
## ```
## { x : F32, y : F32, width : F32, height : F32 }
## ```
Rectangle : { x : F32, y : F32, width : F32, height : F32 }

## Represents a 2D vector.
## ```
## { x : F32, y : F32 }
## ```
Vector2 : { x : F32, y : F32 }

## Represents a color using a tag union.
## ```
## # a generic rgba color
## RGBA { r : U8, g : U8, b : U8, a : U8 }
## ```
Color : [
    RGBA U8 U8 U8 U8,
    White,
    Silver,
    Gray,
    Black,
    Red,
    Maroon,
    Yellow,
    Olive,
    Lime,
    Green,
    Aqua,
    Teal,
    Blue,
    Navy,
    Fuchsia,
    Purple,
]

Texture : Effect.Texture

Sound : Effect.Sound

rgba : Color -> InternalColor.RocColor
rgba = \color ->
    when color is
        RGBA r g b a -> InternalColor.fromRGBA { r, g, b, a }
        White -> InternalColor.fromRGBA { r: 255, g: 255, b: 255, a: 255 }
        Silver -> InternalColor.fromRGBA { r: 192, g: 192, b: 192, a: 255 }
        Gray -> InternalColor.fromRGBA { r: 128, g: 128, b: 128, a: 255 }
        Black -> InternalColor.fromRGBA { r: 0, g: 0, b: 0, a: 255 }
        Red -> InternalColor.fromRGBA { r: 255, g: 0, b: 0, a: 255 }
        Maroon -> InternalColor.fromRGBA { r: 128, g: 0, b: 0, a: 255 }
        Yellow -> InternalColor.fromRGBA { r: 255, g: 255, b: 0, a: 255 }
        Olive -> InternalColor.fromRGBA { r: 128, g: 128, b: 0, a: 255 }
        Lime -> InternalColor.fromRGBA { r: 0, g: 255, b: 0, a: 255 }
        Green -> InternalColor.fromRGBA { r: 0, g: 128, b: 0, a: 255 }
        Aqua -> InternalColor.fromRGBA { r: 0, g: 255, b: 255, a: 255 }
        Teal -> InternalColor.fromRGBA { r: 0, g: 128, b: 128, a: 255 }
        Blue -> InternalColor.fromRGBA { r: 0, g: 0, b: 255, a: 255 }
        Navy -> InternalColor.fromRGBA { r: 0, g: 0, b: 128, a: 255 }
        Fuchsia -> InternalColor.fromRGBA { r: 255, g: 0, b: 255, a: 255 }
        Purple -> InternalColor.fromRGBA { r: 128, g: 0, b: 128, a: 255 }

## Exit the program.
exit : Task {} *
exit = Effect.exit |> Task.mapErr \{} -> crash "unreachable exit"

## Show a Raylib log trace message.
##
## ```
## Raylib.log! "Not yet implemented" LogError
## ```
log : Str, [LogAll, LogTrace, LogDebug, LogInfo, LogWarning, LogError, LogFatal, LogNone] -> Task {} *
log = \message, level ->
    Effect.log message (Effect.toLogLevel level)
    |> Task.mapErr \{} -> crash "unreachable log"

beginDrawing : Color -> Task {} *
beginDrawing = \color ->
    Effect.beginDrawing (rgba color)
    |> Task.mapErr \{} -> crash "unreachable beginDrawing"

endDrawing : Task {} *
endDrawing = Effect.endDrawing |> Task.mapErr \{} -> crash "unreachable endDrawing"

## Set the window title.
setWindowTitle : Str -> Task {} *
setWindowTitle = \title ->
    Effect.setWindowTitle title
    |> Task.mapErr \{} -> crash "unreachable setWindowTitle"

## Set the window size.
setWindowSize : { width : F32, height : F32 } -> Task {} *
setWindowSize = \{ width, height } ->
    Effect.setWindowSize (Num.round width) (Num.round height)
    |> Task.mapErr \{} -> crash "unreachable setWindowSize"

## Get the window size.
getScreenSize : Task { height : F32, width : F32 } *
getScreenSize =
    Effect.getScreenSize
    |> Task.map \{ width, height } -> { width: Num.toFrac width, height: Num.toFrac height }
    |> Task.mapErr \{} -> crash "unreachable getScreenSize"

## Set the target frames per second. The default value is 60.
setTargetFPS : I32 -> Task {} *
setTargetFPS = \fps -> Effect.setTargetFPS fps |> Task.mapErr \{} -> crash "unreachable setTargetFPS"

## Display the frames per second, and set the location.
## The default values are Hidden, 10, 10.
## ```
## Raylib.setDrawFPS! { fps: Visible, posX: 10, posY: 10 }
## ```
setDrawFPS : { fps : [Visible, Hidden], posX ? I32, posY ? I32 } -> Task {} *
setDrawFPS = \{ fps, posX ? 10, posY ? 10 } ->

    showFps =
        when fps is
            Visible -> Bool.true
            Hidden -> Bool.false

    Effect.setDrawFPS showFps posX posY
    |> Task.mapErr \{} -> crash "unreachable setDrawFPS"

## Measure the width of a text string using the default font.
measureText : { text : Str, size : I32 } -> Task I64 *
measureText = \{ text, size } ->
    Effect.measureText text size
    |> Task.mapErr \{} -> crash "unreachable measureText"

## Draw text on the screen using the default font.
drawText : { pos : { x : F32, y : F32 }, text : Str, size : I32, color : Color } -> Task {} *
drawText = \{ text, pos, size, color } ->
    Effect.drawText (InternalVector.fromVector2 pos) size text (rgba color)
    |> Task.mapErr \{} -> crash "unreachable drawText"

## Draw a line on the screen.
drawLine : { start : Vector2, end : Vector2, color : Color } -> Task {} *
drawLine = \{ start, end, color } ->
    Effect.drawLine (InternalVector.fromVector2 start) (InternalVector.fromVector2 end) (rgba color)
    |> Task.mapErr \{} -> crash "unreachable drawLine"

## Draw a rectangle on the screen.
drawRectangle : { rect : Rectangle, color : Color } -> Task {} *
drawRectangle = \{ rect, color } ->
    Effect.drawRectangle (InternalRectangle.fromRect rect) (rgba color)
    |> Task.mapErr \{} -> crash "unreachable drawRectangle"

## Draw a rectangle with a vertical-gradient fill on the screen.
drawRectangleGradientV : { rect : Rectangle, top : Color, bottom : Color } -> Task {} *
drawRectangleGradientV = \{ rect, top, bottom } ->

    tc = rgba top
    bc = rgba bottom

    Effect.drawRectangleGradientV (InternalRectangle.fromRect rect) tc bc
    |> Task.mapErr \{} -> crash "unreachable drawRectangleGradientV"

## Draw a rectangle with a horizontal-gradient fill on the screen.
drawRectangleGradientH : { rect : Rectangle, top : Color, bottom : Color } -> Task {} *
drawRectangleGradientH = \{ rect, top, bottom } ->

    tc = rgba top
    bc = rgba bottom

    Effect.drawRectangleGradientH (InternalRectangle.fromRect rect) tc bc
    |> Task.mapErr \{} -> crash "unreachable drawRectangleGradientH"

## Draw a circle on the screen.
drawCircle : { center : Vector2, radius : F32, color : Color } -> Task {} *
drawCircle = \{ center, radius, color } ->
    Effect.drawCircle (InternalVector.fromVector2 center) radius (rgba color)
    |> Task.mapErr \{} -> crash "unreachable drawCircle"

## Draw a circle with a gradient on the screen.
drawCircleGradient : { center : Vector2, radius : F32, inner : Color, outer : Color } -> Task {} *
drawCircleGradient = \{ center, radius, inner, outer } ->

    ic = rgba inner
    oc = rgba outer

    Effect.drawCircleGradient (InternalVector.fromVector2 center) radius ic oc
    |> Task.mapErr \{} -> crash "unreachable drawCircleGradient"

## Takes a screenshot of current screen (filename extension defines format)
## ```
## Raylib.takeScreenshot! "screenshot.png"
## ```
takeScreenshot : Str -> Task {} *
takeScreenshot = \filename ->
    Effect.takeScreenshot filename
    |> Task.mapErr \{} -> crash "unreachable takeScreenshot"

Camera := U64

createCamera : { target : Vector2, offset : Vector2, rotation : F32, zoom : F32 } -> Task Camera *
createCamera = \{ target, offset, rotation, zoom } ->
    Effect.createCamera (InternalVector.fromVector2 target) (InternalVector.fromVector2 offset) rotation zoom
    |> Task.map \camera -> @Camera camera
    |> Task.mapErr \{} -> crash "unreachable createCamera"

updateCamera : Camera, { target : Vector2, offset : Vector2, rotation : F32, zoom : F32 } -> Task {} *
updateCamera = \@Camera camera, { target, offset, rotation, zoom } ->
    Effect.updateCamera camera (InternalVector.fromVector2 target) (InternalVector.fromVector2 offset) rotation zoom
    |> Task.mapErr \{} -> crash "unreachable updateCamera"

drawMode2D : Camera, Task {} err -> Task {} err
drawMode2D = \@Camera camera, drawTask ->

    Effect.beginMode2D camera
        |> Task.mapErr! \{} -> crash "unreachable beginMode2D"

    Task.attempt drawTask \result ->
        when result is
            Ok {} ->
                Effect.endMode2D camera
                    |> Task.mapErr! \{} -> crash "unreachable endMode2D"

                Task.ok {}

            Err err ->
                Effect.endMode2D camera
                    |> Task.mapErr! \{} -> crash "unreachable endMode2D"

                Task.err err

## Load a texture from a file.
## ```
## texture = Raylib.loadTexture! "sprites.png"
## ```
loadTexture : Str -> Task Texture [TextureLoadErr Str]_
loadTexture = \filename ->
    Effect.loadTexture filename
    |> Task.mapErr \msg -> TextureLoadErr msg

## Draw part of a texture.
## ```
## Raylib.drawTextureRec! texture { x: 0, y: 0, width: 32, height: 32 } { x: 10, y: 10 } White
## ```
drawTextureRec : { texture : Texture, source : Rectangle, pos : Vector2, tint : Color } -> Task {} *
drawTextureRec = \{ texture, source, pos, tint } ->
    Effect.drawTextureRec texture (InternalRectangle.fromRect source) (InternalVector.fromVector2 pos) (rgba tint)
    |> Task.mapErr \{} -> crash "unreachable drawTextureRec"

loadSound : Str -> Task Sound [LoadSoundErr Str]
loadSound = \path ->
    Effect.loadSound path
    |> Task.mapErr \err -> LoadSoundErr err

playSound : Sound -> Task {} *
playSound = \sound ->
    Effect.playSound sound
    |> Task.mapErr \{} -> crash "unreachable Sound.play"
