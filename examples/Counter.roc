module [Counter, init, render]

import ray.Action
import ray.Raylib exposing [Color]
import ray.GUI exposing [Elem]

Counter := I64

init : I64 -> Counter
init = @Counter

render : Counter, Color -> Elem Counter
render = \@Counter state, color ->
    GUI.col [
        GUI.button {
            text: "+",
            onPress: \@Counter prev -> Action.update (@Counter (prev + 1)),
        },
        GUI.text {
            label: "Clicked $(Num.toStr state) times",
            color,
        },
        GUI.button {
            text: "-",
            onPress: \@Counter prev -> Action.update (@Counter (prev - 1)),
        },
    ]
