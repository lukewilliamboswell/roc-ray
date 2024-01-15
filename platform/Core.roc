interface Core
    exposes [
        Color,
        Elem,
        Rectangle,
        translate,
        setWindowSize,
        button,
        exit,
        text,
        setWindowTitle,
        drawRectangle,
    ]
    imports [InternalTask, Task.{ Task }, Effect.{ Effect }, Action.{ Action }]

Rectangle : { x : F32, y : F32, width : F32, height : F32 }
Color : { r : U8, g : U8, b : U8, a : U8 }

Elem state : [
    Text { label : Str, color : Color },
    Button { label : Str, onPress : state -> Action state },
    Col (List (Elem state)),
    Row (List (Elem state)),
    None,
]

translate : Elem child, (parent -> child), (parent -> (child -> parent)) -> Elem parent
translate = \elem, parentToChild, childToParent ->
    when elem is
        Text config -> Text config
        Button { label, onPress } ->
            Button {
                label,
                onPress: \prevParent -> onPress (parentToChild prevParent) |> Action.map (childToParent prevParent),
            }

        Col children -> Col (List.map children \c -> translate c parentToChild childToParent)
        Row children -> Row (List.map children \c -> translate c parentToChild childToParent)
        None -> None

exit : Task {} []
exit =
    Effect.exit
    |> Effect.map Ok
    |> InternalTask.fromEffect

setWindowSize : { width : U32, height : U32 } -> Task {} []
setWindowSize = \{ width, height } ->
    width32 = width 
    height32 = height 
    Effect.setWindowSize width32 height32
    |> Effect.map Ok
    |> InternalTask.fromEffect

button : Rectangle, Str -> Task { isPressed : Bool } []
button = \{ x, y, width, height }, str ->
    Effect.drawGuiButton x y width height str
    |> Effect.map \i32 -> Ok { isPressed: (i32 != 0) }
    |> InternalTask.fromEffect

text : Str, { x : F32, y : F32, size : F32, color : Color } -> Task {} []
text = \str, { x, y, size, color } ->
    x32 = x |> Num.round |> Num.toI32
    y32 = y |> Num.round |> Num.toI32
    size32 = size |> Num.round |> Num.toI32

    Effect.drawText x32 y32 size32 str color.r color.g color.b color.a
    |> Effect.map Ok
    |> InternalTask.fromEffect

setWindowTitle : Str -> Task {} []
setWindowTitle = \title ->
    Effect.setWindowTitle title
    |> Effect.map Ok
    |> InternalTask.fromEffect

drawRectangle : { x : F32, y : F32, width : F32, height : F32, color : Color } -> Task {} []
drawRectangle = \{x,y,width,height,color} ->
    x32 = x |> Num.round |> Num.toI32
    y32 = y |> Num.round |> Num.toI32
    width32 = width |> Num.round |> Num.toI32
    height32 = height |> Num.round |> Num.toI32

    Effect.drawRectangle x32 y32 width32 height32 color.r color.g color.b color.a
    |> Effect.map Ok
    |> InternalTask.fromEffect