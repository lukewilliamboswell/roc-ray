interface Core 
    exposes [
        setWindowSize,
    ]
    imports [InternalTask, Task.{ Task }, Effect.{ Effect }]

setWindowSize : { width : U32, height : U32 } -> Task {} []
setWindowSize = \{ width, height } ->
    Effect.setWindowSize width height
    |> Effect.map Ok
    |> InternalTask.fromEffect