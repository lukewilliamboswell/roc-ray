## A special texture that can be used as a render target. Allows drawing operations to be
## performed to it (like a canvas), making it useful for effects, buffering, or off-screen
## rendering. The result can then be used like a regular texture.
module [create!, filter_to_int, set_render_texture_filter!, Filter]

import Effect
import InternalVector
import RocRay exposing [RenderTexture]


Filter : [
    Point,
    Bilinear,
    Trilinear,
    Anisotropic4x,
    Anisotropic8x,
    Anisotropic16x,

]

filter_to_int : Filter -> I32
filter_to_int = |filter|
    when filter is
        Point -> 0
        Bilinear -> 1
        Trilinear -> 2
        Anisotropic4x -> 3
        Anisotropic8x -> 4
        Anisotropic16x -> 5

## Create a render texture.
## ```
## RenderTexture.create! { width: 100, height: 100 }
## ```
create! : { width : F32, height : F32 } => Result RenderTexture [LoadErr Str]_
create! = |{ width, height }|
    Effect.create_render_texture!(InternalVector.from_xy(width, height))
    |> Result.map_err(|str| LoadErr(str))


set_render_texture_filter! : RenderTexture, Filter => {}
set_render_texture_filter! = |render_texture, filter|
    type = filter_to_int filter
    Effect.set_render_texture_filter! render_texture type
