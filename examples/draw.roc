interface Draw
    exposes [renderDrawables]
    imports [ray.Task.{ Task }, ray.Core.{ Color, Rectangle }]

Shape : [
    Rect Rectangle,
    Circle { x : F32, y : F32, radius : F32 },
    Text { text : Str, x : F32, y : F32, fontSize : I32 },
]

Drawable : [
    Fill (Shape, Color),
    # Stroke (Shape, Color, F32)
]

renderFilled : Shape, Color -> Task {} []
renderFilled = \shape, color ->
    when shape is
        Rect bounds ->
            Core.drawRectangle {
                x: bounds.x,
                y: bounds.y,
                width: bounds.width,
                height: bounds.height,
                color: color,
            }

        Circle {} ->
            Task.ok {}

        Text { text, fontSize, x, y } -> Core.drawText { text, posX: x, posY: y, fontSize, color }

renderDrawable : Drawable -> Task {} []
renderDrawable = \drawable ->
    when drawable is
        Fill (shape, color) -> renderFilled shape color

renderDrawables : List Drawable -> Task {} []
renderDrawables = \drawables ->
    List.walk drawables (Task.ok {}) \state, drawable ->
        state |> Task.await \{} -> renderDrawable drawable
