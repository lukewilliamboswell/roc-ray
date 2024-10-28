## A special texture that can be used as a render target. Allows drawing operations to be
## performed to it (like a canvas), making it useful for effects, buffering, or off-screen
## rendering. The result can then be used like a regular texture.
module [create!]

import Effect
import InternalVector
import RocRay exposing [RenderTexture]

## Create a render texture.
## ```
## RenderTexture.create! { width: 100, height: 100 }
## ```
create! : { width : F32, height : F32 } => RenderTexture
create! = \{ width, height } ->
    Effect.createRenderTexture! (InternalVector.fromXY width height)
