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
    ]
    imports [InternalTask, Task.{ Task }, Effect.{ Effect }, Action.{Action}]

Rectangle : { x : F32, y : F32, width : F32, height : F32 }
Color : { r : U8, g : U8, b : U8, a : U8 }

Elem state : [
    Text { label : Str, color : Color },
    Button { label : Str, onPress : state -> Action state },
    Col (List (Elem state)),
    None,
]

# map : Action a, (a -> b) -> Action b
# map = \action, transform ->
#     when action is
#         None -> None
#         Update state -> Update (transform state)

translate : Elem child, (parent -> child), (child -> parent) -> Elem parent
translate = \elem, parentToChild, childToParent ->
    when elem is 
        Text config -> Text config

        Button {label, onPress} ->
            Button {
                label, 
                onPress: \parent -> onPress (parentToChild parent) |> Action.map childToParent,
            }

        Col children -> Col (List.map children \c -> translate c parentToChild childToParent) 
            
        None -> None


exit : Task {} []
exit =
    Effect.exit
    |> Effect.map Ok
    |> InternalTask.fromEffect

setWindowSize : { width : F32, height : F32 } -> Task {} []
setWindowSize = \{ width, height } ->
    width32 = width |> Num.round |> Num.toU32
    height32 = height |> Num.round |> Num.toU32
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
