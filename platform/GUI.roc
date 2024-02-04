interface GUI
    exposes [
        GUI,
        button,
        windowBox,
        translateGUI,
    ]
    imports [
        InternalTask,
        Task.{ Task },
        Effect.{ Effect },
        Action.{ Action },
        Stateful.{ Stateful, render },
    ]

GUI state := [
    GuiButton { label : Str, x : F32, y : F32, width : F32, height : F32, onPress : state -> Action state },
    GuiWindowBox { title : Str, x : F32, y : F32, width : F32, height : F32, onPress : state -> Action state },
]
    implements [Stateful { render: renderGUI, translate: translateGUI }]

button : { label : Str, x : F32, y : F32, width : F32, height : F32, onPress : state -> Action state } -> GUI state
button = \config -> GuiButton config |> @GUI

windowBox : { title : Str, x : F32, y : F32, width : F32, height : F32, onPress : state -> Action state } -> GUI state
windowBox = \config -> GuiWindowBox config |> @GUI

renderGUI : Task state [], GUI state -> Task state []
renderGUI = \prev, @GUI thing ->

    state <- prev |> Task.await

    when thing is
        GuiButton { label, x, y, width, height, onPress } ->
            { isPressed } <-
                Effect.drawGuiButton x y width height label
                |> Effect.map \i32 -> Ok { isPressed: (i32 != 0) }
                |> InternalTask.fromEffect
                |> Task.await

            if isPressed then
                when onPress state is
                    None -> Task.ok state
                    Update newState -> Task.ok newState
            else
                Task.ok state

        GuiWindowBox { title, x, y, width, height, onPress } ->
            { isPressed } <-
                Effect.guiWindowBox x y width height title
                |> Effect.map \i32 -> Ok { isPressed: (i32 != 0) }
                |> InternalTask.fromEffect
                |> Task.await

            if isPressed then
                when onPress state is
                    None -> Task.ok state
                    Update newState -> Task.ok newState
            else
                Task.ok state

translateGUI : GUI child, (parent -> child), (parent, child -> parent) -> GUI parent
translateGUI = \@GUI item, parentToChild, childToParent ->
    when item is
        GuiButton { label, x, y, width, height, onPress } ->
            newPress = \prevParent -> onPress (parentToChild prevParent) |> Action.map \child -> childToParent prevParent child
            GuiButton { label, x, y, width, height, onPress: newPress } |> @GUI

        GuiWindowBox { title, x, y, width, height, onPress } ->
            newPress = \prevParent -> onPress (parentToChild prevParent) |> Action.map \child -> childToParent prevParent child
            GuiWindowBox { title, x, y, width, height, onPress: newPress } |> @GUI
