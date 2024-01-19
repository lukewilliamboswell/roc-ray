app "counter"
    packages { ray: "https://github.com/lukewilliamboswell/roc-ray/releases/download/test/5JjXlOa8wScAnwM6Dl2LaHAygvRbZ_bXgaonv1z8xes.tar.br" }
    imports [
        ray.Task.{ Task },
        ray.Action.{ Action },
        ray.Core.{ Color, Rectangle },
        ray.GUI.{ Elem },
        Counter.{ Counter },
    ]
    provides [main, Model] to ray

Model : {
    left : Counter,
    middle : Counter,
    right : Counter,
}

width = 800
height = 600

Program : {
    init : Task Model [],
    render : Model -> Task Model [],
}

main : Program
main = { init, render }

init : Task Model []
init =

    {} <- Core.setWindowSize { width, height } |> Task.await
    {} <- Core.setWindowTitle "GUI Counter Demo" |> Task.await

    Task.ok {
        left: Counter.init 10,
        middle: Counter.init 20,
        right: Counter.init 30,
    }

render : Model -> Task Model []
render = \model ->

    # this is temporary workaround for a bug `Error in alias analysis: error in module...`
    # sometimes we need an extra Task in the chain to prevent this error
    _ <- Core.getMousePosition |> Task.await
    
    GUI.col [
        GUI.text { label: "Click below to change the counters, press ESC to exit", color: black },
        GUI.row [
            GUI.translate (Counter.render model.left red) .left \record, count -> { record & left: count },
            GUI.translate (Counter.render model.middle green) .middle \record, count -> { record & middle: count },
            GUI.translate (Counter.render model.right blue) .right \record, count -> { record & right: count },
        ],
    ]
    |> GUI.window { title: "Window", onClose: \_ -> Action.none }
    |> GUI.draw model {
        x: width / 8,
        y: height / 8,
        width: width * 6 / 8,
        height: height * 6 / 8,
    }

black = { r: 0, g: 0, b: 0, a: 255 }
blue = { r: 29, g: 66, b: 137, a: 255 }
red = { r: 211, g: 39, b: 62, a: 255 }
green = { r: 0, g: 59, b: 73, a: 255 }
