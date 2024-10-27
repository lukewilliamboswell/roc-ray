module [
    PlatformState,
    KeyboardKey,
    Color,
    Rectangle,
    Vector2,
    Camera,
    Texture,
    RenderTexture,
    Sound,
    UUID,
    rgba,
    initWindow!,
    exit!,
    setTargetFPS!,
    displayFPS!,
    measureText!,
    takeScreenshot!,
    log!,
    loadFileToStr!,
    sendToPeer!,
    getScreenSize!,
]

import Mouse
import Effect
import Network
import InternalKeyboard
import InternalColor
import InternalVector

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
    keys : InternalKeyboard.Keys,
    mouse : {
        position : Vector2,
        buttons : Mouse.Buttons,
        wheel : F32,
    },
    network : {
        peers : {
            connected : List Network.UUID,
            disconnected : List Network.UUID,
        },
        messages : List {
            id : Network.UUID,
            bytes : List U8,
        },
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

## A static image loaded into GPU memory, typically from a file. Once loaded, it can be used
## multiple times for efficient rendering. Cannot be modified after creation - for dynamic
## textures that can be drawn to, see [RenderTexture] instead.
Texture : Effect.Texture

## A special texture that can be used as a render target. Allows drawing operations to be
## performed to it (like a canvas), making it useful for effects, buffering, or off-screen
## rendering. The result can then be used like a regular texture.
RenderTexture : Effect.RenderTexture

## A loaded sound resource, used to play audio.
Sound : Effect.Sound

## A camera used to render a 2D perspective of the world.
Camera : Effect.Camera

UUID : Network.UUID

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
exit! : {} => {}
exit! = \{} -> Effect.exit! {}

## Show a RocRay log trace message.
##
## ```
## RocRay.log! "Not yet implemented" LogError
## ```
log! : Str, [LogAll, LogTrace, LogDebug, LogInfo, LogWarning, LogError, LogFatal, LogNone] => {}
log! = \message, level ->
    Effect.log! message (Effect.toLogLevel level)

initWindow! : { title ? Str, width ? F32, height ? F32 } => {}
initWindow! = \{ title ? "RocRay", width ? 800, height ? 600 } ->
    Effect.initWindow! title width height

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
## RocRay.displayFPS! { fps: Visible, pos: { x: 10, y: 10 }}
## ```
displayFPS! : { fps : [Visible, Hidden], pos : Vector2 } => {}
displayFPS! = \{ fps, pos } ->

    showFps =
        when fps is
            Visible -> Bool.true
            Hidden -> Bool.false

    Effect.setDrawFPS! showFps (InternalVector.fromVector2 pos)

## Measure the width of a text string using the default font.
measureText! : { text : Str, size : I32 } => I64
measureText! = \{ text, size } -> Effect.measureText! text size

## Takes a screenshot of current screen (filename extension defines format)
## ```
## RocRay.takeScreenshot! "screenshot.png"
## ```
takeScreenshot! : Str => {}
takeScreenshot! = \filename ->
    Effect.takeScreenshot! filename

## Loads a file from disk
## ```
## RocRay.loadFileToStr! "resources/example.txt"
## ```
loadFileToStr! : Str => Str
loadFileToStr! = \path ->
    Effect.loadFileToStr! path

## Send a message to a connected peer.
sendToPeer! : List U8, UUID => {}
sendToPeer! = \message, peerId ->
    Effect.sendToPeer! message (Network.toU64Pair peerId)
