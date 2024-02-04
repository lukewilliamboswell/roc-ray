interface SmallWindow
    exposes [
        SmallWindow, 
        init, 
        render,
    ]
    imports [
        ray.Action.{ Action }, 
        ray.GUI.{ GUI },
    ]

SmallWindow := {window: [Opened, Closed], x : F32, y : F32, width : F32, height : F32} implements [Inspect]

init = @SmallWindow

render = \@SmallWindow state ->
    when state.window is 
        Opened ->
            GUI.windowBox {
                title: "SMALL WINDOW",
                x: state.x,
                y: state.y,
                width: state.width,
                height: state.height,
                onPress: \@SmallWindow prev -> Action.update (@SmallWindow {prev & window: Closed}),
            }

        Closed -> 
            GUI.button {
                x: state.x,
                y: state.y,
                width: 100,
                height: 50,
                label: "OPEN WINDOW",
                onPress: \@SmallWindow prev -> Action.update (@SmallWindow {prev & window: Opened}),
            }
