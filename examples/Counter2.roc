interface Counter2
    exposes [
        Counter2, 
        init, 
        render,
    ]
    imports [
        ray.Action.{ Action }, 
        ray.GUI.{ GUI },
    ]

Counter2 := I64

init : I64 -> Counter2
init = @Counter2

render : Counter2, { x : F32, y : F32, width : F32, height : F32 } -> GUI Counter2
render = \@Counter2 count, { x, y, width, height } ->
    GUI.button {
        x,
        y,
        width,
        height,
        label: "Click Me $(Num.toStr count) times",
        onPress: \@Counter2 prev -> Action.update (@Counter2 (prev + 1)),
    }
