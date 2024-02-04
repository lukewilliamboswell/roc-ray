interface Counter
    exposes [
        Counter, 
        init, 
        render,
    ]
    imports [
        ray.Action.{ Action }, 
        ray.GUI.{ GUI },
    ]

Counter := {count : I64, x : F32, y : F32, width : F32, height : F32} implements [Inspect]

init = @Counter

render = \@Counter state ->
    GUI.button {
        x: state.x,
        y: state.y,
        width: state.width,
        height: state.height,
        label: "Clicked $(Num.toStr state.count) times",
        onPress: \@Counter prev -> Action.update (@Counter {prev & count: prev.count + 1}),
    }
