interface Counter
    exposes [
        Counter,
        init,
    ]
    imports [
        ray.Action.{ Action },
        ray.GUI.{ GUI },
        ray.Task.{ Task },
        ray.Stateful.{ Stateful },
    ]

Counter := {
    opened : Bool,
    count : I64,
    x : F32, 
    y : F32, 
    width : F32, 
    height : F32,
}
    implements [Stateful { render, translate }]

init : { opened : Bool, count : I64, x : F32, y : F32, width : F32, height : F32 } -> Counter
init = @Counter

open : Counter -> Counter
open = \@Counter state -> @Counter { state & opened : Bool.true}

render : Task model [], Counter -> Task model []
render = \prevTask, @Counter state ->

    counterWindow = GUI.windowBox {
        title: "SMALL WINDOW",
        x: state.x,
        y: state.y,
        width: state.width,
        height: state.height,
        onPress: \_ -> Action.none,
    }

    closedButton = GUI.button { 
        label : "Open Counter", 
        x: state.x,
        y: state.y,
        width: 100,
        height: 50,
        onPress : \_ -> Action.none #\prevCounter -> Action.update (open prevCounter), 
    }

    if state.opened then 
        prevTask
        |> Stateful.render closedButton
    else 
        prevTask
        |> Stateful.render counterWindow

translate : Counter, (p -> c), (p, c -> p) -> Counter
translate = \counter, _, _ -> counter
