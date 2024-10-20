module [
    Program,
    PlatformState,
    KeyboardKey,
    Color,
    Rectangle,
    Vector2,
    Camera,
    Texture,
    setWindowSize!,
    getScreenSize!,
    setBackgroundColor!,
    exit!,
    setWindowTitle!,
    setTargetFPS!,
    setDrawFPS!,
    measureText!,
    drawText!,
    drawLine!,
    drawRectangle!,
    drawRectangleGradientV!,
    drawRectangleGradientH!,
    drawCircle!,
    drawCircleGradient!,
    takeScreenshot!,
    createCamera!,
    updateCamera!,
    drawMode2D!,
    log!,
    loadTexture!,
    drawTextureRec!,
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
##     init : {} => state,
##     render : state => state,
## }
## ```
Program state err : {
    init! : {} => Result state err,
    render! : state, PlatformState => Result state err,
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

Texture : Effect.Texture

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
exit! : {} => {}
exit! = Effect.exit! {}

## Show a Raylib log! trace message.
##
## ```
## Raylib.log! "Not yet implemented" LogError
## ```
log! : Str, [LogAll, LogTrace, LogDebug, LogInfo, LogWarning, LogError, LogFatal, LogNone] => {}
log! = \message, level ->
    Effect.log! message (Effect.toLogLevel level)

## Set the window title.
setWindowTitle! : Str => {}
setWindowTitle! = \title -> Effect.setWindowTitle! title

## Set the window size.
setWindowSize! : { width : F32, height : F32 } => {}
setWindowSize! = \{ width, height } -> Effect.setWindowSize! (Num.round width) (Num.round height)

## Get the window size.
getScreenSize! : {} => { height : F32, width : F32 }
getScreenSize! = \{} ->
    Effect.getScreenSize! {}
    |> \{ width, height } -> { width: Num.toFrac width, height: Num.toFrac height }

## Set the target frames per second. The default value is 60.
setTargetFPS! : I32 => {}
setTargetFPS! = \fps -> Effect.setTargetFPS! fps

## Display the frames per second, and set the location.
## The default values are Hidden, 10, 10.
## ```
## Raylib.setDrawFPS! { fps: Visible, posX: 10, posY: 10 }
## ```
setDrawFPS! : { fps : [Visible, Hidden], posX ? I32, posY ? I32 } => {}
setDrawFPS! = \{ fps, posX ? 10, posY ? 10 } ->

    showFps =
        when fps is
            Visible -> Bool.true
            Hidden -> Bool.false

    Effect.setDrawFPS! showFps posX posY

## Set the background color to clear the window between each frame.
setBackgroundColor! : Color => {}
setBackgroundColor! = \color -> Effect.setBackgroundColor! (rgba color)

## Measure the width of a text string using the default font.
measureText! : { text : Str, size : I32 } => I64
measureText! = \{ text, size } -> Effect.measureText! text size

## Draw text on the screen using the default font.
drawText! : { pos : { x : F32, y : F32 }, text : Str, size : I32, color : Color } => {}
drawText! = \{ text, pos, size, color } -> Effect.drawText! (InternalVector.fromVector2 pos) size text (rgba color)

## Draw a line on the screen.
drawLine! : { start : Vector2, end : Vector2, color : Color } => {}
drawLine! = \{ start, end, color } ->
    Effect.drawLine! (InternalVector.fromVector2 start) (InternalVector.fromVector2 end) (rgba color)

## Draw a rectangle on the screen.
drawRectangle! : { rect : Rectangle, color : Color } => {}
drawRectangle! = \{ rect, color } ->
    Effect.drawRectangle! (InternalRectangle.fromRect rect) (rgba color)

## Draw a rectangle with a vertical-gradient fill on the screen.
drawRectangleGradientV! : { rect : Rectangle, top : Color, bottom : Color } => {}
drawRectangleGradientV! = \{ rect, top, bottom } ->

    tc = rgba top
    bc = rgba bottom

    Effect.drawRectangleGradientV! (InternalRectangle.fromRect rect) tc bc

## Draw a rectangle with a horizontal-gradient fill on the screen.
drawRectangleGradientH! : { rect : Rectangle, top : Color, bottom : Color } => {}
drawRectangleGradientH! = \{ rect, top, bottom } ->

    tc = rgba top
    bc = rgba bottom

    Effect.drawRectangleGradientH! (InternalRectangle.fromRect rect) tc bc

## Draw a circle on the screen.
drawCircle! : { center : Vector2, radius : F32, color : Color } => {}
drawCircle! = \{ center, radius, color } ->
    Effect.drawCircle! (InternalVector.fromVector2 center) radius (rgba color)

## Draw a circle with a gradient on the screen.
drawCircleGradient! : { center : Vector2, radius : F32, inner : Color, outer : Color } => {}
drawCircleGradient! = \{ center, radius, inner, outer } ->

    ic = rgba inner
    oc = rgba outer

    Effect.drawCircleGradient! (InternalVector.fromVector2 center) radius ic oc

## Takes a screenshot of current screen (filename extension defines format)
## ```
## Raylib.takeScreenshot! "screenshot.png"
## ```
takeScreenshot! : Str => {}
takeScreenshot! = \filename ->
    Effect.takeScreenshot! filename

Camera := U64

createCamera! : { target : Vector2, offset : Vector2, rotation : F32, zoom : F32 } => Camera
createCamera! = \{ target, offset, rotation, zoom } ->
    Effect.createCamera! target.x target.y offset.x offset.y rotation zoom
    |> \camera -> @Camera camera

updateCamera! : Camera, { target : Vector2, offset : Vector2, rotation : F32, zoom : F32 } => {}
updateCamera! = \@Camera camera, { target, offset, rotation, zoom } ->
    Effect.updateCamera! camera target.x target.y offset.x offset.y rotation zoom

drawMode2D! : Camera, ({} => {}) => {}
drawMode2D! = \@Camera camera, drawTask! ->

    Effect.beginMode2D! camera

    drawTask!

    Effect.endMode2D! camera

## Load a texture from a file.
## ```
## texture = Raylib.loadTexture! "sprites.png"
## ```
loadTexture! : Str => Result Texture [TextureLoadErr Str]_
loadTexture! = \filename ->
    Effect.loadTexture! filename |> Result.mapErr \msg -> TextureLoadErr msg

## Draw part of a texture.
## ```
## Raylib.drawTextureRec! texture { x: 0, y: 0, width: 32, height: 32 } { x: 10, y: 10 } White
## ```
drawTextureRec! : { texture : Texture, source : Rectangle, pos : Vector2, tint : Color } => {}
drawTextureRec! = \{ texture, source, pos, tint } ->
    Effect.drawTextureRec! texture (InternalRectangle.fromRect source) (InternalVector.fromVector2 pos) (rgba tint)
