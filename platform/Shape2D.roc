interface Shape2D
    exposes [
        Shape2D,
        rect,
        rectGradientV,
        text,
        circle,
        circleGradient,
    ]
    imports [
        Drawable.{ Drawable },
        Core.{ Color },
        Task.{ Task },
        InternalTask,
        Effect,
    ]

Shape2D := [
    DrawText { text : Str, posX : I32, posY : I32, size : I32, color : Color },
    DrawRectangle { posX : I32, posY : I32, width : I32, height : I32, color : Color },
    DrawRectangleGradientV { posX : I32, posY : I32, width : I32, height : I32, top : Color, bottom : Color },
    DrawCircle { centerX : I32, centerY : I32, radius : F32, color : Color },
    DrawCircleGradient { centerX : I32, centerY : I32, radius : F32, inner : Color, outer : Color },
]
    implements [Drawable { draw: drawShape }]

## Draw a color-filled rectangle
rect : { posX : I32, posY : I32, width : I32, height : I32, color : Color } -> Shape2D
rect = \config -> DrawRectangle config |> @Shape2D

## Draw a vertical-gradient-filled rectangle
rectGradientV : { posX : I32, posY : I32, width : I32, height : I32, top : Color, bottom : Color } -> Shape2D
rectGradientV = \config -> DrawRectangleGradientV config |> @Shape2D

## Draw text (using default font)
text : { text : Str, posX : I32, posY : I32, size : I32, color : Color } -> Shape2D
text = \config -> DrawText config |> @Shape2D

## Draw a color-filled circle
circle : { centerX : I32, centerY : I32, radius : F32, color : Color } -> Shape2D
circle = \config -> DrawCircle config |> @Shape2D

## Draw a gradient-filled circle
circleGradient : { centerX : I32, centerY : I32, radius : F32, inner : Color, outer : Color } -> Shape2D
circleGradient = \config -> DrawCircleGradient config |> @Shape2D

drawShape : Shape2D -> Task {} []
drawShape = \@Shape2D shape ->
    when shape is
        DrawRectangle { posX, posY, width, height, color } ->
            Effect.drawRectangle posX posY width height color.r color.g color.b color.a
            |> Effect.map Ok
            |> InternalTask.fromEffect

        DrawRectangleGradientV { posX, posY, width, height, top, bottom } ->
            Effect.drawRectangleGradientV posX posY width height top.r top.g top.b top.a bottom.r bottom.g bottom.b bottom.a
            |> Effect.map Ok
            |> InternalTask.fromEffect

        DrawText { text: str, posX, posY, size, color } ->
            Effect.drawText posX posY size str color.r color.g color.b color.a
            |> Effect.map Ok
            |> InternalTask.fromEffect

        DrawCircle { centerX, centerY, radius, color } ->
            Effect.drawCircle centerX centerY radius color.r color.g color.b color.a
            |> Effect.map Ok
            |> InternalTask.fromEffect

        DrawCircleGradient { centerX, centerY, radius, inner, outer } ->
            Effect.drawCircleGradient centerX centerY radius inner.r inner.g inner.b inner.a outer.r outer.g outer.b outer.a
            |> Effect.map Ok
            |> InternalTask.fromEffect

