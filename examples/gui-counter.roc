app [main, Model] {
    ray: platform "../platform/main.roc",
}

import ray.Action
import ray.Raylib exposing [Program]
import ray.GUI
import Counter exposing [Counter]

Model : {
    width : F32,
    height : F32,
    left : Counter,
    middle : Counter,
    right : Counter,
}

main : Program Model
main = { init, render }

init : Task Model {}
init =

    width = 800f32
    height = 600f32

    Raylib.setWindowSize! { width, height }
    Raylib.setWindowTitle! "GUI Counter Demo"

    Task.ok {
        width,
        height,
        left: Counter.init 10,
        middle: Counter.init 20,
        right: Counter.init 30,
    }

render : Model -> Task Model {}
render = \model ->

    GUI.col [
        GUI.text { label: "Click below to change the counters, press ESC to exit", color: black },
        GUI.row [
            GUI.translate (Counter.render model.left red) .left &left,
            GUI.translate (Counter.render model.middle green) .middle &middle,
            GUI.translate (Counter.render model.right blue) .right &right,
        ],
    ]
    |> GUI.window { title: "Window", onClose: \_ -> Action.none }
    |> GUI.draw model {
        x: model.width / 8,
        y: model.height / 8,
        width: model.width * 6 / 8,
        height: model.height * 6 / 8,
    }

black = { r: 0, g: 0, b: 0, a: 255 }
blue = { r: 29, g: 66, b: 137, a: 255 }
red = { r: 211, g: 39, b: 62, a: 255 }
green = { r: 0, g: 59, b: 73, a: 255 }
