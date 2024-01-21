interface Core
    exposes [
        Program,
        Color,
        Rectangle,
        Vector2,
        setWindowSize,
        getScreenSize,
        exit,
        drawText,
        setWindowTitle,
        drawRectangle,
        getMousePosition,
        isMouseButtonPressed,
    ]
    imports [InternalTask, Task.{ Task }, Effect.{ Effect }]

## 
Program state : {
    init : Task state [],
    render : state -> Task state [],
}

Rectangle : { x : F32, y : F32, width : F32, height : F32 }
Vector2 : { x : F32, y : F32 }
Color : { r : U8, g : U8, b : U8, a : U8 }

MouseButton : [
    LEFT,
    RIGHT,
    MIDDLE,
    SIDE,
    EXTRA,
    FORWARD,
    BACK,
]

exit : Task {} []
exit =
    Effect.exit
    |> Effect.map Ok
    |> InternalTask.fromEffect

setWindowSize : { width : F32, height : F32 } -> Task {} []
setWindowSize = \{ width, height } ->
    Effect.setWindowSize (Num.round width) (Num.round height)
    |> Effect.map Ok
    |> InternalTask.fromEffect

getScreenSize : Task { height : F32, width : F32 } []
getScreenSize =
    Effect.getScreenSize
    |> Effect.map \{ width, height } -> Ok { width: Num.toFrac width, height: Num.toFrac height }
    |> InternalTask.fromEffect

drawText : { text : Str, posX : F32, posY : F32, fontSize : I32, color : Color } -> Task {} []
drawText = \{ text, posX, posY, fontSize, color } ->
    Effect.drawText (Num.round posX) (Num.round posY) fontSize text color.r color.g color.b color.a
    |> Effect.map Ok
    |> InternalTask.fromEffect

setWindowTitle : Str -> Task {} []
setWindowTitle = \title ->
    Effect.setWindowTitle title
    |> Effect.map Ok
    |> InternalTask.fromEffect

drawRectangle : { x : F32, y : F32, width : F32, height : F32, color : Color } -> Task {} []
drawRectangle = \{ x, y, width, height, color } ->
    Effect.drawRectangle (Num.round x) (Num.round y) (Num.round width) (Num.round height) color.r color.g color.b color.a
    |> Effect.map Ok
    |> InternalTask.fromEffect

getMousePosition : Task Vector2 []
getMousePosition =
    Effect.getMousePosition
    |> Effect.map Ok
    |> InternalTask.fromEffect

isMouseButtonPressed : MouseButton -> Task Bool []
isMouseButtonPressed = \button ->

    selection =
        when button is
            LEFT -> 0i32
            RIGHT -> 1i32
            MIDDLE -> 2i32
            SIDE -> 3i32
            EXTRA -> 4i32
            FORWARD -> 5i32
            BACK -> 6i32

    Effect.isMouseButtonPressed selection
    |> Effect.map Ok
    |> InternalTask.fromEffect
