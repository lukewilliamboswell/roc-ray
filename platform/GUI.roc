interface GUI
    exposes [
        Elem,
        translate,
        draw,
        guiButton,
        guiWindowBox,
        button,
        col,
        row,
        text,
        window,
    ]
    imports [
        InternalTask, 
        Task.{ Task }, 
        Effect.{ Effect }, 
        Action.{ Action }, 
        Core.{ Color, Rectangle },
        # Layout.{Layoutable, Constraint, Size},
    ]

Elem state := [
    Text { label : Str, size : I32, color : Color },
    Button { text : Str, onPress : state -> Action state },
    Window { title : Str, onClose : state -> Action state } (Elem state),
    Col (List (Elem state)),
    Row (List (Elem state)),
    None,
] 

Constraint : {
    minWidth : F32,
    maxWidth : F32,
    minHeight : F32,
    maxHeight : F32,
}

Size : {
    width : F32,
    height : F32,
}

layout : Elem state, Constraint -> Task Size []
layout = \@Elem elem, constraints ->

    # TODO check this is the right height? maybe it scales with font size??
    defaultTextHeight = 10f32 

    when elem is 
        Text config ->

            widthI32 <- Core.measureText {text : config.label, size : config.size} |> Task.await

            width = 
                if (Num.toFrac widthI32) > constraints.minWidth && (Num.toFrac widthI32) < constraints.maxWidth then 
                    defaultTextHeight
                else 
                    crash "TODO handle text width out of range"

            height = 
                if defaultTextHeight > constraints.minHeight && defaultTextHeight < constraints.maxHeight then 
                    defaultTextHeight
                else 
                    crash "TODO handle default text height out of range"

            Task.ok {width, height}

        Col children -> crash "TODO not supported"
        _ -> crash "TODO not supported"

button : { text : Str, onPress : state -> Action state } -> Elem state
button = \config -> Button config |> @Elem

col : List (Elem state) -> Elem state
col = \children -> Col children |> @Elem

row : List (Elem state) -> Elem state
row = \children -> Row children |> @Elem

text : { label : Str, size : I32, color : Color } -> Elem state
text = \config -> Text config |> @Elem

window : Elem state, { title : Str, onClose : state -> Action state } -> Elem state
window = \child, config -> Window config child |> @Elem

translate : Elem child, (parent -> child), (parent, child -> parent) -> Elem parent
translate = \@Elem elem, parentToChild, childToParent ->
    when elem is
        Text config -> Text config |> @Elem
        Button config ->
            Button {
                text: config.text,
                onPress: \prevParent -> config.onPress (parentToChild prevParent) |> Action.map \child -> childToParent prevParent child,
            }
            |> @Elem

        Window { title, onClose } c ->
            Window
                {
                    title,
                    onClose: \prevParent -> onClose (parentToChild prevParent) |> Action.map \child -> childToParent prevParent child,
                }
                (translate c parentToChild childToParent)
            |> @Elem

        Col children -> Col (List.map children \c -> translate c parentToChild childToParent) |> @Elem
        Row children -> Row (List.map children \c -> translate c parentToChild childToParent) |> @Elem
        None -> None |> @Elem

draw : Elem state, state, Rectangle -> Task state []
draw = \@Elem elem, model, bb ->

    defaultStepX = 120
    defaultStepY = 50

    when elem is
        Button config ->
            { isPressed } <- GUI.guiButton { text: config.text, shape: { x: bb.x, y: bb.y, width: defaultStepX, height: defaultStepY } } |> Task.await

            if isPressed then
                when config.onPress model is
                    None -> Task.ok model
                    Update newModel -> Task.ok newModel
            else
                Task.ok model

        Window { title, onClose } child ->
            { isPressed } <- GUI.guiWindowBox { title, shape: bb } |> Task.await

            if isPressed then
                when onClose model is
                    None -> Task.ok model
                    Update newModel -> Task.ok newModel
            else
                draw child model { x: bb.x + 5, y: bb.y + 30, width: bb.width - 10, height: bb.height - 30 }

        Row children ->
            when children is
                [first] -> draw first model bb
                [first, second] ->
                    firstBB = { x: bb.x + (0 * defaultStepX), y: bb.y, width: defaultStepX, height: bb.height }
                    secondBB = { x: bb.x + (1 * defaultStepX), y: bb.y, width: defaultStepX, height: bb.height }
                    model1 <- draw first model firstBB |> Task.await
                    model2 <- draw second model1 secondBB |> Task.await

                    Task.ok model2

                [first, second, third] ->
                    firstBB = { x: bb.x + (0 * defaultStepX), y: bb.y, width: defaultStepX, height: bb.height }
                    secondBB = { x: bb.x + (1 * defaultStepX), y: bb.y, width: defaultStepX, height: bb.height }
                    thirdBB = { x: bb.x + (2 * defaultStepX), y: bb.y, width: defaultStepX, height: bb.height }
                    model1 <- draw first model firstBB |> Task.await
                    model2 <- draw second model1 secondBB |> Task.await
                    model3 <- draw third model2 thirdBB |> Task.await

                    Task.ok model3

                _ -> Task.ok model

        Col children ->
            when children is
                [first] -> draw first model bb
                [first, second] ->
                    firstBB = { x: bb.x, y: bb.y + (0 * defaultStepY), width: bb.width, height: defaultStepY }
                    secondBB = { x: bb.x, y: bb.y + (1 * defaultStepY), width: bb.width, height: defaultStepY }
                    model1 <- draw first model firstBB |> Task.await
                    model2 <- draw second model1 secondBB |> Task.await

                    Task.ok model2

                [first, second, third] ->
                    firstBB = { x: bb.x, y: bb.y + (0 * defaultStepY), width: bb.width, height: defaultStepY }
                    secondBB = { x: bb.x, y: bb.y + (1.5 * defaultStepY), width: bb.width, height: defaultStepY }
                    thirdBB = { x: bb.x, y: bb.y + (2.5 * defaultStepY), width: bb.width, height: defaultStepY }
                    model1 <- draw first model firstBB |> Task.await
                    model2 <- draw second model1 secondBB |> Task.await
                    model3 <- draw third model2 thirdBB |> Task.await

                    Task.ok model3

                _ -> Task.ok model

        Text config ->

            # constraint = {
            #     minWidth : 0,
            #     maxWidth : bb.width,
            #     minHeight : 0,
            #     maxHeight : bb.height,
            # }

            # size <- layout (@Elem elem) constraint |> Task.await

            {} <-
                Core.drawText { 
                    text: config.label, 
                    posX: bb.x, 
                    posY: bb.y, 
                    fontSize: config.size, 
                    color: config.color,
                } 
                |> Task.await

            Task.ok model

        None -> Task.ok model

guiButton : { text : Str, shape : Core.Rectangle } -> Task { isPressed : Bool } []
guiButton = \{ text: str, shape: { x, y, width, height } } ->
    Effect.drawGuiButton x y width height str
    |> Effect.map \i32 -> Ok { isPressed: (i32 != 0) }
    |> InternalTask.fromEffect

guiWindowBox : { title : Str, shape : Core.Rectangle } -> Task { isPressed : Bool } []
guiWindowBox = \{ title, shape: { x, y, width, height } } ->
    Effect.guiWindowBox x y width height title
    |> Effect.map \i32 -> Ok { isPressed: (i32 != 0) }
    |> InternalTask.fromEffect
