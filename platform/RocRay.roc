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
    beginMode2D,
    endMode2D,
    log,
    loadTexture,
    drawTextureRec,
    loadSound,
    playSound,
    beginDrawing,
    endDrawing,
]

import Keys
import Mouse
import Effect
import InternalKeyboard
import InternalColor
import InternalVector
import InternalRectangle

## Provide an initial state and a render function to the platform.
## ```
## {
##     init : Task state []err,
##     render : state -> Task state []err,
## }
## ```
Program state err : {
    init : Task state []err,
    render : state, PlatformState -> Task state []err,
} where err implements Inspect

## A state record provided by platform on each frame.
## ```
## {
##     timestampMillis : U64,
##     frameCount : U64,
##     keys : Keys.Keys,
##     mouse : {
##         position : Vector2,
##         buttons : Mouse.Buttons,
##         wheel : F32,
##     },
## }
## ```
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

## Represents a keyboard key, like `KeyA` or `KeyEnter`.
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
##
## # predefined colors
## White
## Black
## Red
## Green
## Blue
## ... etc
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

## A loaded texture resource, used to draw images.
Texture : Effect.Texture

## A loaded sound resource, used to play audio.
Sound : Effect.Sound

## A camera used to render a 2D perspective of the world.
Camera : Effect.Camera

# internal use only
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
## ```
## RocRay.exit!
## ```
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

## Begin drawing to the framebuffer. Takes a color to clear the screen with.
## ```
## RocRay.beginDrawing! White
## ```
beginDrawing : Color -> Task {} *
beginDrawing = \color ->
    Effect.beginDrawing (rgba color)
    |> Task.mapErr \{} -> crash "unreachable beginDrawing"

## End drawing to the framebuffer.
## ```
## RocRay.endDrawing!
## ```
endDrawing : Task {} *
endDrawing = Effect.endDrawing |> Task.mapErr \{} -> crash "unreachable endDrawing"

## Set the window title.
##
## ```
## RocRay.setWindowTitle! "My Roc Game"
## ```
setWindowTitle : Str -> Task {} *
setWindowTitle = \title ->
    Effect.setWindowTitle title
    |> Task.mapErr \{} -> crash "unreachable setWindowTitle"

## Set the window size.
## ```
## RocRay.setWindowSize! { width: 800, height: 600 }
## ```
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
## ```
## RocRay.drawText! { pos: { x: 50, y: 120 }, text: "Click to start", size: 20, color: White }
## ```
drawText : { pos : { x : F32, y : F32 }, text : Str, size : I32, color : Color } -> Task {} *
drawText = \{ text, pos, size, color } ->
    Effect.drawText (InternalVector.fromVector2 pos) size text (rgba color)
    |> Task.mapErr \{} -> crash "unreachable drawText"

## Draw a line on the screen.
## ```
## RocRay.drawLine! { start: { x: 100, y: 500 }, end: { x: 500, y: 500 }, color: Red }
## ```
drawLine : { start : Vector2, end : Vector2, color : Color } -> Task {} *
drawLine = \{ start, end, color } ->
    Effect.drawLine (InternalVector.fromVector2 start) (InternalVector.fromVector2 end) (rgba color)
    |> Task.mapErr \{} -> crash "unreachable drawLine"

## Draw a rectangle on the screen.
## ```
## RocRay.drawRectangle! { rect: { x: 100, y: 150, width: 250, height: 100 }, color: Aqua }
## ```
drawRectangle : { rect : Rectangle, color : Color } -> Task {} *
drawRectangle = \{ rect, color } ->
    Effect.drawRectangle (InternalRectangle.fromRect rect) (rgba color)
    |> Task.mapErr \{} -> crash "unreachable drawRectangle"

## Draw a rectangle with a vertical-gradient fill on the screen.
## ```
### RocRay.drawRectangleGradientV! { rect: { x: 300, y: 250, width: 250, height: 100 }, top: Maroon, bottom: Green }
## ```
drawRectangleGradientV : { rect : Rectangle, top : Color, bottom : Color } -> Task {} *
drawRectangleGradientV = \{ rect, top, bottom } ->

    tc = rgba top
    bc = rgba bottom

    Effect.drawRectangleGradientV (InternalRectangle.fromRect rect) tc bc
    |> Task.mapErr \{} -> crash "unreachable drawRectangleGradientV"

## Draw a rectangle with a horizontal-gradient fill on the screen.
## ```
## RocRay.drawRectangleGradientH! { rect: { x: 400, y: 150, width: 250, height: 100 }, top: Lime, bottom: Navy }
## ```
drawRectangleGradientH : { rect : Rectangle, top : Color, bottom : Color } -> Task {} *
drawRectangleGradientH = \{ rect, top, bottom } ->

    tc = rgba top
    bc = rgba bottom

    Effect.drawRectangleGradientH (InternalRectangle.fromRect rect) tc bc
    |> Task.mapErr \{} -> crash "unreachable drawRectangleGradientH"

## Draw a circle on the screen.
## ```
## RocRay.drawCircle! { center: { x: 200, y: 400 }, radius: 75, color: Fuchsia }
## ```
drawCircle : { center : Vector2, radius : F32, color : Color } -> Task {} *
drawCircle = \{ center, radius, color } ->
    Effect.drawCircle (InternalVector.fromVector2 center) radius (rgba color)
    |> Task.mapErr \{} -> crash "unreachable drawCircle"

## Draw a circle with a gradient on the screen.
## ```
## RocRay.drawCircleGradient! { center: { x: 600, y: 400 }, radius: 75, inner: Yellow, outer: Maroon }
## ```
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

## Create a new camera. The camera can be used to render a 2D and 3D perspective of the world.
## ```
## cameraSettings = {
##     target: player,
##     offset: { x: screenWidth / 2, y: screenHeight / 2 },
##     rotation: 0,
##     zoom: 1,
## }
##
## cameraID = RocRay.createCamera! cameraSettings
## ```
createCamera : { target : Vector2, offset : Vector2, rotation : F32, zoom : F32 } -> Task Camera *
createCamera = \{ target, offset, rotation, zoom } ->
    Effect.createCamera (InternalVector.fromVector2 target) (InternalVector.fromVector2 offset) rotation zoom
    |> Task.map \camera -> camera
    |> Task.mapErr \{} -> crash "unreachable createCamera"

## Update a camera's target, offset, rotation, and zoom.
## ```
## cameraSettings =
##     model.cameraSettings
##     |> &target model.player
##     |> &rotation rotation
##     |> &zoom zoom
##
## RocRay.updateCamera! model.cameraID cameraSettings
## ```
updateCamera : Camera, { target : Vector2, offset : Vector2, rotation : F32, zoom : F32 } -> Task {} *
updateCamera = \camera, { target, offset, rotation, zoom } ->
    Effect.updateCamera camera (InternalVector.fromVector2 target) (InternalVector.fromVector2 offset) rotation zoom
    |> Task.mapErr \{} -> crash "unreachable updateCamera"

## Begin to draw a 2D scene using a camera.
##
## Note you must call [endMode2D] after drawing is complete or you will get an error.
## ```
## Raylib.beginMode2D! camera
## ```
beginMode2D : Camera -> Task {} *
beginMode2D = \camera ->
    Effect.beginMode2D camera
        |> Task.mapErr! \{} -> crash "unreachable beginMode2D"

## End drawing a 2D scene using a camera.
## ```
## Raylib.endMode2D! camera
## ```
endMode2D : Camera -> Task {} *
endMode2D = \camera ->
    Effect.endMode2D camera
    |> Task.mapErr! \{} -> crash "unreachable endMode2D"

## Load a texture from a file.
## ```
## texture = Raylib.loadTexture! "sprites.png"
## ```
loadTexture : Str -> Task Texture *
loadTexture = \filename ->
    Effect.loadTexture filename
    |> Task.mapErr \{} -> crash "unreachable loadTexture"

## Draw part of a texture.
## ```
## # Draw the sprite at the player's position.
## RocRay.drawTextureRec! {
##     texture: model.dude,
##     source: dudeSprite model.direction dudeAnimation.frame,
##     pos: model.player,
##     tint: White,
## }
## ```
drawTextureRec : { texture : Texture, source : Rectangle, pos : Vector2, tint : Color } -> Task {} *
drawTextureRec = \{ texture, source, pos, tint } ->
    Effect.drawTextureRec texture (InternalRectangle.fromRect source) (InternalVector.fromVector2 pos) (rgba tint)
    |> Task.mapErr \{} -> crash "unreachable drawTextureRec"

## Load a sound from a file.
## ```
## wav = RocRay.loadSound "resources/sound.wav"
## ```
loadSound : Str -> Task Sound *
loadSound = \path ->
    Effect.loadSound path
    |> Task.mapErr \{} -> crash "unreachable Sound.load"

## Play a loaded sound.
## ```
## RocRay.playSound! wav
## ```
playSound : Sound -> Task {} *
playSound = \sound ->
    Effect.playSound sound
    |> Task.mapErr \{} -> crash "unreachable Sound.play"
