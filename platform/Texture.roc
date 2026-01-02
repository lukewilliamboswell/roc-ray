## A static image loaded into GPU memory, typically from a file. Once loaded, it can be used
## multiple times for efficient rendering. Cannot be modified after creation - for dynamic
## textures that can be drawn to, see [RenderTexture] instead.
module [load!, update_from_image!, from_image!, get_format!, PixelFormat]

import Effect
import RocRay exposing [Texture]

## Load a texture from a file.
## ```
## texture = Texture.load! "sprites.png"
## ```
load! : Str => Result Texture [LoadErr Str]_
load! = |filename|
    Effect.load_texture!(filename)
    |> Result.map_err(LoadErr)


from_image! : Effect.Image => Result Texture [LoadErr Str]
from_image! = |image|
    Effect.load_texture_from_image! image
    |> Result.map_err(LoadErr)

update_from_image! : Effect.Texture, Effect.Image => {}
update_from_image! = |texture, image|
    Effect.update_texture_from_image! texture image

PixelFormat : [ GrayScale, GrayAlpha, R5G6B5, R8G8B8, R8G8B8A8, UnknownFormat ]

get_format! : Texture => PixelFormat
get_format! = |texture|
    Effect.texture_format! texture
    |> |format|
        when format is
            1 -> GrayScale
            2 -> GrayAlpha
            3 ->  R5G6B5
            4 -> R8G8B8
            5 -> R8G8B8A8
            _ -> UnknownFormat
