interface Core
    exposes [
        setWindowSize,
        button,
        exit,
        text,
    ]
    imports [InternalTask, Task.{ Task }, Effect.{ Effect }]

Rectangle : { x : F32, y : F32, width : F32, height : F32 }
Color : { r : U8, g : U8, b : U8, a : U8 }

exit : Task {} []
exit =
    Effect.exit
    |> Effect.map Ok
    |> InternalTask.fromEffect

setWindowSize : { width : U32, height : U32 } -> Task {} []
setWindowSize = \{ width, height } ->
    Effect.setWindowSize width height
    |> Effect.map Ok
    |> InternalTask.fromEffect

button : Rectangle, Str -> Task { isPressed : Bool } []
button = \{ x, y, width, height }, str ->
    Effect.drawGuiButton x y width height str
    |> Effect.map \i32 -> Ok { isPressed: (i32 != 0) }
    |> InternalTask.fromEffect

text : Str, { x : I32, y : I32, size : I32, color : Color } -> Task {} []
text = \str, { x, y, size, color } ->
    Effect.drawText x y size str color.r color.g color.b color.a
    |> Effect.map Ok
    |> InternalTask.fromEffect
