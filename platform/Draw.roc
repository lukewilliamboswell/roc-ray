module [
    draw!,
    text!,
    line!,
    withMode2D!,
    withTexture!,
    rectangle!,
    rectangleGradientV!,
    rectangleGradientH!,
    circle!,
    circleGradient!,
    textureRec!,
    renderTextureRec!,
]

import Effect
import InternalRectangle
import InternalVector
import RocRay exposing [Texture, Camera, Color, Vector2, Rectangle, RenderTexture, rgba]

## Draw to the framebuffer. Takes a color to clear the screen with.
## ```
## Draw.draw! White \{} ->
##     Draw.text! { pos: { x: 300, y: 50 }, text: "Hello World", size: 40, color: Navy }
##     Draw.rectangle! { rect: { x: 100, y: 150, width: 250, height: 100 }, color: Aqua }
## ```
draw! : Color, ({} => {}) => {}
draw! = \color, cmd! ->
    Effect.beginDrawing! (rgba color)

    cmd! {}

    Effect.endDrawing! {}

## Draw a 2D scene using a camera perspective.
## ```
## # RENDER FRAMEBUFFER
## Draw.draw! White \{} ->
##
##     # RENDER WORLD
##     Draw.withMode2D! model.camera \{} ->
##         drawWorld! model
##
##     # RENDER SCREEN UI
##     drawScreenUI!
## ```
withMode2D! : Camera, ({} => {}) => {}
withMode2D! = \camera, cmd! ->
    Effect.beginMode2D! camera

    cmd! {}

    Effect.endMode2D! camera

## Draw to a render texture. Takes a color to clear the texture with.
withTexture! : RenderTexture, Color, ({} => {}) => {}
withTexture! = \texture, color, cmd! ->
    Effect.beginTexture! texture (rgba color)

    cmd! {}

    Effect.endTexture! texture

## Draw text on the screen using the default font.
## ```
## Draw.text! { pos: { x: 50, y: 120 }, text: "Click to start", size: 20, color: White }
## ```
text! : { pos : { x : F32, y : F32 }, text : Str, size : I32, color : Color } => {}
text! = \{ text: t, pos, size, color } ->
    Effect.drawText! (InternalVector.fromVector2 pos) size t (rgba color)

## Draw a line on the screen.
## ```
## Draw.line! { start: { x: 100, y: 500 }, end: { x: 500, y: 500 }, color: Red }
## ```
line! : { start : Vector2, end : Vector2, color : Color } => {}
line! = \{ start, end, color } ->
    Effect.drawLine! (InternalVector.fromVector2 start) (InternalVector.fromVector2 end) (rgba color)

## Draw a rectangle on the screen.
## ```
## Draw.rectangle! { rect: { x: 100, y: 150, width: 250, height: 100 }, color: Aqua }
## ```
rectangle! : { rect : Rectangle, color : Color } => {}
rectangle! = \{ rect, color } ->
    Effect.drawRectangle! (InternalRectangle.fromRect rect) (rgba color)

## Draw a rectangle with a vertical-gradient fill on the screen.
## ```
## Draw.rectangleGradientV! { rect: { x: 300, y: 250, width: 250, height: 100 }, top: Maroon, bottom: Green }
## ```
rectangleGradientV! : { rect : Rectangle, top : Color, bottom : Color } => {}
rectangleGradientV! = \{ rect, top, bottom } ->

    tc = rgba top
    bc = rgba bottom

    Effect.drawRectangleGradientV! (InternalRectangle.fromRect rect) tc bc

## Draw a rectangle with a horizontal-gradient fill on the screen.
## ```
## Draw.rectangleGradientH! { rect: { x: 400, y: 150, width: 250, height: 100 }, top: Lime, bottom: Navy }
## ```
rectangleGradientH! : { rect : Rectangle, top : Color, bottom : Color } => {}
rectangleGradientH! = \{ rect, top, bottom } ->

    tc = rgba top
    bc = rgba bottom

    Effect.drawRectangleGradientH! (InternalRectangle.fromRect rect) tc bc

## Draw a circle on the screen.
## ```
## Draw.circle! { center: { x: 200, y: 400 }, radius: 75, color: Fuchsia }
## ```
circle! : { center : Vector2, radius : F32, color : Color } => {}
circle! = \{ center, radius, color } ->
    Effect.drawCircle! (InternalVector.fromVector2 center) radius (rgba color)

## Draw a circle with a gradient on the screen.
## ```
## Draw.circleGradient! { center: { x: 600, y: 400 }, radius: 75, inner: Yellow, outer: Maroon }
## ```
circleGradient! : { center : Vector2, radius : F32, inner : Color, outer : Color } => {}
circleGradient! = \{ center, radius, inner, outer } ->

    ic = rgba inner
    oc = rgba outer

    Effect.drawCircleGradient! (InternalVector.fromVector2 center) radius ic oc

## Draw part of a texture.
## ```
## # Draw the sprite at the player's position.
## Draw.textureRec! {
##     texture: model.dude,
##     source: dudeSprite model.direction dudeAnimation.frame,
##     pos: model.player,
##     tint: White,
## }
## ```
textureRec! : { texture : Texture, source : Rectangle, pos : Vector2, tint : Color } => {}
textureRec! = \{ texture, source, pos, tint } ->
    Effect.drawTextureRec! texture (InternalRectangle.fromRect source) (InternalVector.fromVector2 pos) (rgba tint)

## Draw part of a texture.
## ```
## # Draw the sprite at the player's position.
## Draw.renderTextureRec! {
##     texture: model.dude,
##     source: dudeSprite model.direction dudeAnimation.frame,
##     pos: model.player,
##     tint: White,
## }
## ```
renderTextureRec! : { texture : RenderTexture, source : Rectangle, pos : Vector2, tint : Color } => {}
renderTextureRec! = \{ texture, source, pos, tint } ->
    Effect.drawRenderTextureRec! texture (InternalRectangle.fromRect source) (InternalVector.fromVector2 pos) (rgba tint)
