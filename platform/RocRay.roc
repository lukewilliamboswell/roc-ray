module [
    Program,
    PlatformState,
    KeyboardKey,
    Color,
    Rectangle,
    Vector2,
    Camera,
    Texture,
    setWindowSize,
    getScreenSize,
    setBackgroundColor,
    exit,
    setWindowTitle,
    drawRectangle,
    setTargetFPS,
    setDrawFPS,
    measureText,
    drawText,
    drawLine,
    drawRectangle,
    drawRectangleGradient,
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
]

import RocRay.Keys as Keys
import RocRay.Mouse as Mouse
import Effect
import InternalKeyboard

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

## Represents a 2D rasterised texture. These are typically sprite sheets or images loaded at runtime from a disk.
Texture := Box {}

rgba : Color -> { r : U8, g : U8, b : U8, a : U8, unused: I64, unused2: I64 }
rgba = \color ->
    when color is
        RGBA r g b a -> { r, g, b, a, unused: 0, unused2: 0 }
        White -> { r: 255, g: 255, b: 255, a: 255, unused: 0, unused2: 0 }
        Silver -> { r: 192, g: 192, b: 192, a: 255, unused: 0, unused2: 0 }
        Gray -> { r: 128, g: 128, b: 128, a: 255, unused: 0, unused2: 0 }
        Black -> { r: 0, g: 0, b: 0, a: 255, unused: 0, unused2: 0 }
        Red -> { r: 255, g: 0, b: 0, a: 255, unused: 0, unused2: 0 }
        Maroon -> { r: 128, g: 0, b: 0, a: 255, unused: 0, unused2: 0 }
        Yellow -> { r: 255, g: 255, b: 0, a: 255, unused: 0, unused2: 0 }
        Olive -> { r: 128, g: 128, b: 0, a: 255, unused: 0, unused2: 0 }
        Lime -> { r: 0, g: 255, b: 0, a: 255, unused: 0, unused2: 0 }
        Green -> { r: 0, g: 128, b: 0, a: 255, unused: 0, unused2: 0 }
        Aqua -> { r: 0, g: 255, b: 255, a: 255, unused: 0, unused2: 0 }
        Teal -> { r: 0, g: 128, b: 128, a: 255, unused: 0, unused2: 0 }
        Blue -> { r: 0, g: 0, b: 255, a: 255, unused: 0, unused2: 0 }
        Navy -> { r: 0, g: 0, b: 128, a: 255, unused: 0, unused2: 0 }
        Fuchsia -> { r: 255, g: 0, b: 255, a: 255, unused: 0, unused2: 0 }
        Purple -> { r: 128, g: 0, b: 128, a: 255, unused: 0, unused2: 0 }

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

## Set the background color to clear the window between each frame.
setBackgroundColor : Color -> Task {} *
setBackgroundColor = \_color ->
    Effect.setBackgroundColor {
        unused : 0,
        unused2 : 0,
        r : 255,
        g : 255,
        b : 255,
        a : 255,
    }
    |> Task.mapErr \{} -> crash "unreachable setBackgroundColor"

## Measure the width of a text string using the default font.
measureText : { text : Str, size : I32 } -> Task I64 *
measureText = \{ text, size } ->
    Effect.measureText text size
    |> Task.mapErr \{} -> crash "unreachable measureText"

## Draw text on the screen using the default font.
drawText : { text : Str, x : F32, y : F32, size : I32, color : Color } -> Task {} *
drawText = \{ text, x, y, size, color } ->

    { r, g, b, a } = rgba color

    Effect.drawText x y size text r g b a
    |> Task.mapErr \{} -> crash "unreachable drawText"

## Draw a line on the screen.
drawLine : { start : Vector2, end : Vector2, color : Color } -> Task {} *
drawLine = \{ start, end, color } ->

    { r, g, b, a } = rgba color

    Effect.drawLine start.x start.y end.x end.y r g b a
    |> Task.mapErr \{} -> crash "unreachable drawLine"

## Draw a rectangle on the screen.
drawRectangle : { x : F32, y : F32, width : F32, height : F32, color : Color } -> Task {} *
drawRectangle = \{ x, y, width, height, color } ->

    { r, g, b, a } = rgba color

    Effect.drawRectangle x y width height r g b a
    |> Task.mapErr \{} -> crash "unreachable drawRectangle"

## Draw a rectangle with a gradient on the screen.
drawRectangleGradient : { x : F32, y : F32, width : F32, height : F32, top : Color, bottom : Color } -> Task {} *
drawRectangleGradient = \{ x, y, width, height, top, bottom } ->

    tc = rgba top
    bc = rgba bottom

    Effect.drawRectangleGradient x y width height tc.r tc.g tc.b tc.a bc.r bc.g bc.b bc.a
    |> Task.mapErr \{} -> crash "unreachable drawRectangleGradient"

## Draw a circle on the screen.
drawCircle : { x : F32, y : F32, radius : F32, color : Color } -> Task {} *
drawCircle = \{ x, y, radius, color } ->

    { r, g, b, a } = rgba color

    Effect.drawCircle x y radius r g b a
    |> Task.mapErr \{} -> crash "unreachable drawCircle"

## Draw a circle with a gradient on the screen.
drawCircleGradient : { x : F32, y : F32, radius : F32, inner : Color, outer : Color } -> Task {} *
drawCircleGradient = \{ x, y, radius, inner, outer } ->

    ic = rgba inner
    oc = rgba outer

    Effect.drawCircleGradient x y radius ic.r ic.g ic.b ic.a oc.r oc.g oc.b oc.a
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
    Effect.createCamera target.x target.y offset.x offset.y rotation zoom
    |> Task.map \camera -> @Camera camera
    |> Task.mapErr \{} -> crash "unreachable createCamera"

updateCamera : Camera, { target : Vector2, offset : Vector2, rotation : F32, zoom : F32 } -> Task {} *
updateCamera = \@Camera camera, { target, offset, rotation, zoom } ->
    Effect.updateCamera camera target.x target.y offset.x offset.y rotation zoom
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
    |> Task.map \texture -> @Texture texture
    |> Task.mapErr \msg -> TextureLoadErr msg

## Draw part of a texture.
## ```
## Raylib.drawTextureRec! texture { x: 0, y: 0, width: 32, height: 32 } { x: 10, y: 10 } White
## ```
drawTextureRec : Texture, Rectangle, Vector2, Color -> Task {} *
drawTextureRec = \@Texture texture, source, position, color ->
    Effect.drawTextureRec texture source position (rgba color)
    |> Task.mapErr \{} -> crash "unreachable drawTextureRec"
