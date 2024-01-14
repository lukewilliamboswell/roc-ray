interface Core 
    exposes [
        setWindowSize,
        drawGuiButton,
        exit,
    ]
    imports [InternalTask, Task.{ Task }, Effect.{ Effect }]

Rectangle : {x: F32,y: F32,width: F32,height: F32}

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

drawGuiButton : Rectangle, Str -> Task {isPressed : Bool} []
drawGuiButton = \{x,y,width,height}, text ->
    Effect.drawGuiButton x y width height text
    |> Effect.map \i32 -> Ok {isPressed: (i32 != 0)}
    |> InternalTask.fromEffect