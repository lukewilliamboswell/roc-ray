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

# We use a [] here for the error type as don't want our app to have an unhandled errors
main : Program Model []
main = { init, render }

init : Task Model []
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

render : Model, _ -> Task Model []
render = \model, _ ->

    GUI.col [
        GUI.text { label: "Click below to change the counters, press ESC to exit", color: Black },
        GUI.row [
            GUI.translate (Counter.render model.left Red) .left &left,
            GUI.translate (Counter.render model.middle Green) .middle &middle,
            GUI.translate (Counter.render model.right Blue) .right &right,
        ],
    ]
    |> GUI.window { title: "Window", onClose: \_ -> Action.none }
    |> GUI.draw model {
        x: model.width / 8,
        y: model.height / 8,
        width: model.width * 6 / 8,
        height: model.height * 6 / 8,
    }
