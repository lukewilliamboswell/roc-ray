## A static image loaded into GPU memory, typically from a file. Once loaded, it can be used
## multiple times for efficient rendering. Cannot be modified after creation - for dynamic
## textures that can be drawn to, see [RenderTexture] instead.
module [load!]

import Effect
import RocRay exposing [Texture]

## Load a texture from a file.
## ```
## texture = Texture.load! "sprites.png"
## ```
load! : Str => Result Texture [LoadErr Str]_
load! = \filename ->
    Effect.loadTexture! filename
    |> Result.mapErr LoadErr
