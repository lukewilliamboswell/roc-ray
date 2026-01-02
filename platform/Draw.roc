module [
    draw!,
    text!,
    line!,
    line_ex!,
    with_mode_2d!,
    with_texture!,
    rectangle!,
    rectangle_pro!,
    rectangle_gradient_v!,
    rectangle_gradient_h!,
    triangle_fan!,
    circle!,
    circle_gradient!,
    circle_lines!,
    ellipse!,
    ellipse_lines!,
    texture_rec!,
    texture_pro!,
    render_texture_rec!,
    render_texture_pro!,
    with_mode_shader!,
    with_blend_mode!,
    ring!,
    poly!
]

import Effect
import InternalRectangle
import InternalVector
import Font exposing [Font]
import RocRay exposing [Texture, Camera, Color, Vector2, Rectangle, RenderTexture, Shader, rgba]

## Draw to the framebuffer. Takes a color to clear the screen with.
## ```
## Draw.draw! White \{} ->
##     Draw.text! { pos: { x: 300, y: 50 }, text: "Hello World", size: 40, color: Navy }
##     Draw.rectangle! { rect: { x: 100, y: 150, width: 250, height: 100 }, color: Aqua }
## ```
draw! : Color, ({} => {}) => {}
draw! = |color, cmd!|
    Effect.begin_drawing!(rgba(color))

    cmd!({})

    Effect.end_drawing!({})

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
with_mode_2d! : Camera, ({} => {}) => {}
with_mode_2d! = |camera, cmd!|
    Effect.begin_mode_2d!(camera)

    cmd!({})

    Effect.end_mode_2d!(camera)

with_mode_shader! : Shader, ({} => {}) => {}
with_mode_shader! = |shader, cmd!|
    Effect.begin_shader_mode!(shader)
    cmd!({})
    Effect.end_shader_mode!({})

## Draw to a render texture. Takes a color to clear the texture with.
with_texture! : RenderTexture, Color, ({} => {}) => {}
with_texture! = |texture, color, cmd!|
    Effect.begin_texture!(texture, rgba(color))

    cmd!({})

    Effect.end_texture!(texture)

with_blend_mode! : RocRay.BlendMode, ({} => {}) => {}
with_blend_mode! = |mode, cmd!|
    blend_mode = when mode is
        Alpha -> 0
        Additive -> 1
        Multiplied -> 2
        AddColors -> 3
        SubtractColors -> 4
        AlphaPremultiply -> 5
    Effect.begin_blend_mode! blend_mode
    cmd!({})
    Effect.end_blend_mode! {}

## Draw text on the screen using the default font.
text! : { font ?? Font, pos : { x : F32, y : F32 }, text : Str, size ?? F32, spacing ?? F32, color ?? Color } => {}
text! = |{ font ?? Default, text: t, pos, size ?? 20, spacing ?? 1, color ?? RGBA(0, 0, 0, 255) }|
    when font is
        Default -> Effect.draw_text!(t, InternalVector.from_vector2(pos), size, spacing, rgba(color))
        Loaded(boxed) -> Effect.draw_text_font!(boxed, t, InternalVector.from_vector2(pos), size, spacing, rgba(color))

## Draw a line on the screen.
## ```
## Draw.line! { start: { x: 100, y: 500 }, end: { x: 500, y: 500 }, color: Red }
## ```
line! : { start : Vector2, end : Vector2, color : Color } => {}
line! = |{ start, end, color }|
    Effect.draw_line!(InternalVector.from_vector2(start), InternalVector.from_vector2(end), rgba(color))

## Draw a line on the screen with thickness
## ```
## Draw.line! { start: { x: 100, y: 500 }, end: { x: 500, y: 500 }, color: Red }
## ```
line_ex! : { start : Vector2, end : Vector2, thickness: F32, color : Color } => {}
line_ex! = |{ start, end, thickness, color }|
    Effect.draw_line_ex!(InternalVector.from_vector2(start), InternalVector.from_vector2(end), thickness, rgba(color))

## Draw a rectangle on the screen.
## ```
## Draw.rectangle! { rect: { x: 100, y: 150, width: 250, height: 100 }, color: Aqua }
## ```
rectangle! : { rect : Rectangle, color : Color } => {}
rectangle! = |{ rect, color }|
    Effect.draw_rectangle!(InternalRectangle.from_rect(rect), rgba(color))

## Draw a professional rectangle on the screen.
## ```
## Draw.rectangle! { rect: { x: 100, y: 150, width: 250, height: 100 }, color: Aqua }
## ```
rectangle_pro! : { rect : Rectangle, origin: Vector2, rotation: F32, color : Color } => {}
rectangle_pro! = |{ rect, origin, rotation, color }|
    Effect.draw_rectangle_pro!(InternalRectangle.from_rect(rect),
        InternalVector.from_xy(origin.x, origin.y),
        rotation,
        rgba(color))
## Draw a rectangle with a vertical-gradient fill on the screen.
## ```
## Draw.rectangleGradientV! { rect: { x: 300, y: 250, width: 250, height: 100 }, top: Maroon, bottom: Green }
## ```
rectangle_gradient_v! : { rect : Rectangle, top : Color, bottom : Color } => {}
rectangle_gradient_v! = |{ rect, top, bottom }|

    tc = rgba(top)
    bc = rgba(bottom)

    Effect.draw_rectangle_gradient_v!(InternalRectangle.from_rect(rect), tc, bc)

## Draw a rectangle with a horizontal-gradient fill on the screen.
## ```
## Draw.rectangleGradientH! { rect: { x: 400, y: 150, width: 250, height: 100 }, top: Lime, bottom: Navy }
## ```
rectangle_gradient_h! : { rect : Rectangle, left : Color, right : Color } => {}
rectangle_gradient_h! = |{ rect, left, right }|

    lc = rgba(left)
    rc = rgba(right)

    Effect.draw_rectangle_gradient_h!(InternalRectangle.from_rect(rect), lc, rc)

## Draw a circle on the screen.
## ```
## Draw.circle! { center: { x: 200, y: 400 }, radius: 75, color: Fuchsia }
## ```
circle! : { center : Vector2, radius : F32, color : Color } => {}
circle! = |{ center, radius, color }|
    Effect.draw_circle!(InternalVector.from_vector2(center), radius, rgba(color))

## Draw an ellipse on the screen.
## ```
## Draw.ellipse! { center: { x: 200, y: 400 }, h: 75, v: 60, color: Fuchsia }
## ```
ellipse! : { center : Vector2, h : F32, v: F32, color : Color } => {}
ellipse! = |{ center, h, v, color }|
    Effect.draw_ellipse! InternalVector.from_vector2(center) h v rgba(color)

## Draw an ellipse's outline on the screen.
## ```
## Draw.ellipse_lines! { center: { x: 200, y: 400 }, h: 75, v: 60, color: Fuchsia }
## ```
ellipse_lines! : { center : Vector2, h : F32, v: F32, color : Color } => {}
ellipse_lines! = |{ center, h, v, color }|
    Effect.draw_ellipse_lines! InternalVector.from_vector2(center) h v rgba(color)



## Draw a circle with a gradient on the screen.
## ```
## Draw.circleGradient! { center: { x: 600, y: 400 }, radius: 75, inner: Yellow, outer: Maroon }
## ```
circle_gradient! : { center : Vector2, radius : F32, inner : Color, outer : Color } => {}
circle_gradient! = |{ center, radius, inner, outer }|

    ic = rgba(inner)
    oc = rgba(outer)

    Effect.draw_circle_gradient!(InternalVector.from_vector2(center), radius, ic, oc)

## Draw a circle outline
## ```
## Draw.cirlce_line! { center: { x: 600, y: 400 }, radius: 75, inner: Yellow, outer: Maroon }
## ```
circle_lines! : { center : Vector2, radius : F32, color : Color } => {}
circle_lines! = |{ center, radius, color}|

    oc = rgba(color)

    Effect.draw_circle_lines!(InternalVector.from_vector2(center), radius, oc)

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
texture_rec! : { texture : Texture, source : Rectangle, pos : Vector2, tint : Color } => {}
texture_rec! = |{ texture, source, pos, tint }|
    Effect.draw_texture_rec!(texture, InternalRectangle.from_rect(source), InternalVector.from_vector2(pos), rgba(tint))

texture_pro! : { texture : Texture, source : Rectangle, dest: Rectangle, origin : Vector2, rotation: F32, tint : Color } => {}
texture_pro! = |{ texture, source, dest, origin, rotation, tint }|
    Effect.draw_texture_pro!(
        texture,
        InternalRectangle.from_rect(source),
        InternalRectangle.from_rect(dest),
        InternalVector.from_vector2(origin),
        rotation,
        rgba(tint)
    )
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
render_texture_rec! : { texture : RenderTexture, source : Rectangle, pos : Vector2, tint : Color } => {}
render_texture_rec! = |{ texture, source, pos, tint }|
    Effect.draw_render_texture_rec!(texture, InternalRectangle.from_rect(source), InternalVector.from_vector2(pos), rgba(tint))

render_texture_pro! : { texture : RenderTexture, source : Rectangle, dest: Rectangle, origin : Vector2, rotation: F32, tint : Color } => {}
render_texture_pro! = |{ texture, source, dest, origin, rotation, tint }|
    Effect.draw_render_texture_pro!(
        texture,
        InternalRectangle.from_rect(source),
        InternalRectangle.from_rect(dest),
        InternalVector.from_vector2(origin),
        rotation,
        rgba(tint)
    )


## Draw rings
## ```
## Draw.ring! { center: { x: 200, y: 400 }, h: 75, v: 60, color: Fuchsia }
## ```
ring! : { center : Vector2, start : F32, end: F32, inner: F32, outer: F32, segments: I32, color : Color } => {}
ring! = |{ center, inner, outer, start, end, segments, color }|
    Effect.draw_ring!(InternalVector.from_vector2(center), inner, outer, start, end, segments, rgba(color))


poly! : { center: Vector2, sides: I32, radius: F32, rotation: F32, color: Color } => {}
poly! = |{ center, sides, radius, rotation, color }|
    Effect.draw_poly!(InternalVector.from_vector2 center, sides, radius, rotation, rgba(color))


triangle_fan! : List Vector2, Color => {}
triangle_fan! = |points, color|
    List.map points InternalVector.from_vector2
    |> Effect.draw_triangle_fan! rgba(color)
