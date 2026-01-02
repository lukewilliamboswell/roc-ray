module [
    PlatformState,
    KeyboardKey,
    Color,
    Rectangle,
    Matrix4,
    Vector2,
    Camera,
    Texture,
    RenderTexture,
    Sound,
    NetworkState,
    NetworkPeers,
    NetworkMessage,
    Shader,
    UUID,
    BlendMode,
    rgba,
    init_window!,
    exit!,
    set_target_fps!,
    display_fps!,
    take_screenshot!,
    gen_image_color!,
    gen_image_perlin_noise!,
    log!,
    load_file_to_str!,
    send_to_peer!,
    get_screen_size!,
    get_screen_to_world_2d!,
    random_i32!,
    measure_text!,
    fade,
    identity
]

import Mouse
import Effect
import Network
import Time
import InternalKeyboard
import InternalColor
import InternalVector
import InternalMatrix

## A state record provided by platform on each frame.
## ```
## {
##    frameCount : U64,
##    keys : InternalKeyboard.Keys,
##    mouse : {
##        position : Vector2,
##        buttons : Mouse.Buttons,
##        wheel : F32,
##    },
##    timestamp : Time.Time,
##    network : {
##        peers : {
##            connected : List Network.UUID,
##            disconnected : List Network.UUID,
##        },
##        messages : List {
##            id : Network.UUID,
##            bytes : List U8,
##        },
##    },
## }
## ```
PlatformState : {
    frame_count : U64,
    keys : InternalKeyboard.Keys,
    mouse : {
        position : Vector2,
        buttons : Mouse.Buttons,
        wheel : F32,
    },
    timestamp : Time.Time,
    network : NetworkState,
}

NetworkState : {
    peers : NetworkPeers,
    messages : List NetworkMessage,
}

NetworkPeers : {
    connected : List Network.UUID,
    disconnected : List Network.UUID,
}

NetworkMessage : {
    id : Network.UUID,
    bytes : List U8,
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


## Reprsents a 4x4 Matrix
## ```
## { }
Matrix4 : InternalMatrix.Matrix

identity = InternalMatrix.identity

## ```
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
    Clear,
    Blank,
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
BlendMode : [
    Alpha,
    Additive,
    Multiplied,
    AddColors,
    SubtractColors,
    AlphaPremultiply,
]
## A static image loaded into GPU memory, typically from a file. Once loaded, it can be used
## multiple times for efficient rendering. Cannot be modified after creation - for dynamic
## textures that can be drawn to, see [RenderTexture] instead.
Texture : Effect.Texture

## A special texture that can be used as a render target. Allows drawing operations to be
## performed to it (like a canvas), making it useful for effects, buffering, or off-screen
## rendering. The result can then be used like a regular texture.
RenderTexture : Effect.RenderTexture

Shader : Effect.Shader

## A loaded sound resource, used to play audio.
Sound : Effect.Sound

## A camera used to render a 2D perspective of the world.
Camera : Effect.Camera

UUID : Network.UUID

# internal use only
rgba : Color -> InternalColor.RocColor
rgba = |color|
    InternalColor.from_rgba(to_rgba(color))

to_rgba : Color -> { r: U8, g: U8, b: U8, a: U8 }
to_rgba = |color|
    when color is
        RGBA(r, g, b, a) -> ({ r, g, b, a })
        Blank -> ({r: 0, g: 0, b: 0, a: 0})
        Clear -> ({r: 255, g: 255, b: 255, a: 0})
        White -> ({ r: 255, g: 255, b: 255, a: 255 })
        Silver -> ({ r: 192, g: 192, b: 192, a: 255 })
        Gray -> ({ r: 128, g: 128, b: 128, a: 255 })
        Black -> ({ r: 0, g: 0, b: 0, a: 255 })
        Red -> ({ r: 255, g: 0, b: 0, a: 255 })
        Maroon -> ({ r: 128, g: 0, b: 0, a: 255 })
        Yellow -> ({ r: 255, g: 255, b: 0, a: 255 })
        Olive -> ({ r: 128, g: 128, b: 0, a: 255 })
        Lime -> ({ r: 0, g: 255, b: 0, a: 255 })
        Green ->({ r: 0, g: 128, b: 0, a: 255 })
        Aqua -> ({ r: 0, g: 255, b: 255, a: 255 })
        Teal -> ({ r: 0, g: 128, b: 128, a: 255 })
        Blue -> ({ r: 0, g: 0, b: 255, a: 255 })
        Navy -> ({ r: 0, g: 0, b: 128, a: 255 })
        Fuchsia -> { r: 255, g: 0, b: 255, a: 255 }
        Purple -> { r: 128, g: 0, b: 128, a: 255 }



fade : Color, F32 -> Color
fade = |color, alpha|
    alpha_ = if alpha < 0 then 0 else if alpha > 1 then 1 else alpha
    { r, g, b } = to_rgba(color)
    RGBA(r, g, b, (Num.to_f32 alpha_ |> Num.mul 255 |> Num.round))

## Exit the program.
## ```
## RocRay.exit!
## ```
exit! : {} => {}
exit! = |{}| Effect.exit!({})

## Show a RocRay log trace message.
##
## ```
## RocRay.log! "Not yet implemented" LogError
## ```
log! : Str, [LogAll, LogTrace, LogDebug, LogInfo, LogWarning, LogError, LogFatal, LogNone] => {}
log! = |message, level|
    Effect.log!(message, Effect.to_log_level(level))

init_window! : { title ?? Str, width ?? F32, height ?? F32 } => {}
init_window! = |{ title ?? "RocRay", width ?? 800, height ?? 600 }|
    Effect.init_window!(title, width, height)

## Get the window size.
get_screen_size! : {} => { height : F32, width : F32 }
get_screen_size! = |{}|
    Effect.get_screen_size!({})
    |> |{ width, height }| { width: Num.to_frac(width), height: Num.to_frac(height) }

get_screen_to_world_2d! : Vector2, Camera => Vector2
get_screen_to_world_2d! = |point, camera|
    Effect.get_screen_to_world_2d!(InternalVector.from_vector2(point), camera)
    |> InternalVector.to_vector2


## Set the target frames per second. The default value is 60.
set_target_fps! : I32 => {}
set_target_fps! = |fps| Effect.set_target_fps!(fps)

## Display the frames per second, and set the location.
## The default values are Hidden, 10, 10.
## ```
## RocRay.displayFPS! { fps: Visible, pos: { x: 10, y: 10 }}
## ```
display_fps! : { fps : [Visible, Hidden], pos : Vector2 } => {}
display_fps! = |{ fps, pos }|

    show_fps =
        when fps is
            Visible -> Bool.true
            Hidden -> Bool.false

    Effect.set_draw_fps!(show_fps, InternalVector.from_vector2(pos))

## Takes a screenshot of current screen (filename extension defines format)
## ```
## RocRay.takeScreenshot! "screenshot.png"
## ```
take_screenshot! : Str => {}
take_screenshot! = |filename|
    Effect.take_screenshot!(filename)

## Loads a file from disk
## ```
## RocRay.loadFileToStr! "resources/example.txt"
## ```
load_file_to_str! : Str => Result Str [LoadErr Str]_
load_file_to_str! = |path|
    Effect.load_file_to_str!(path)
    |> Result.map_err(LoadErr)

## Send a message to a connected peer.
send_to_peer! : List U8, UUID => {}
send_to_peer! = |message, peer_id|
    Effect.send_to_peer!(message, Network.to_u64_pair(peer_id))

random_i32! : { min : I32, max : I32 } => I32
random_i32! = |{ min, max }| Effect.random_i32!(min, max)


gen_image_color! = |width, height, color|
    Effect.gen_image_color! width height rgba(color)
    |> Result.map_err LoadErr


gen_image_perlin_noise! : Vector2, Vector2, F32 => Result Effect.Image [LoadErr Str]
gen_image_perlin_noise! = |dims, offset, scale|
    Effect.gen_image_perlin_noise!(Num.round(dims.x), Num.round(dims.y), Num.round(offset.x), Num.round(offset.y), scale)
    |> Result.map_err LoadErr

measure_text! = |{ text, size, spacing }|
    Effect.measure_text! text size spacing
    |> InternalVector.to_vector2
