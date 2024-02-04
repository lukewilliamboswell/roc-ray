app "counter"
    packages { ray: "../platform/main.roc" }
    imports [
        ray.Task.{ Task },
        ray.Action.{ Action },
        ray.Core.{ Program, Color, Rectangle },
        ray.GUI.{ GUI },
        Counter.{ Counter },
        Counter2.{ Counter2 },
        ray.Stateful,
        ray.Shape2D,
    ]
    provides [main, Model] to ray

Model : { left : Counter2, right : Counter2, middle: Counter }

main : Program Model
main = { init, render }

init : Task Model []
init =

    {} <- Core.setWindowSize { width: 800, height: 600 } |> Task.await
    {} <- Core.setWindowTitle "Counter Demo" |> Task.await

    Task.ok { 
        left: Counter2.init 10,
        right: Counter2.init 20,
        middle: Counter.init {opened: Bool.true, count: 30, x: 400, y: 100, width: 300, height: 200 },
    }

render : Model -> Task Model []
render = \model ->

    leftButton =
        Stateful.translate
            (Counter2.render model.left { x: 10, y: 400, width: 200, height: 100 })
            .left
            \record, count -> { record & left: count }

    rightButton =
        Stateful.translate
            (Counter2.render model.right { x: 210, y: 400, width: 200, height: 100 })
            .right
            \record, count -> { record & right: count }

    elements = Shape2D.shapes [
        Shape2D.rect { posX: 10, posY: 50, width: 200, height: 50, color: white },
        Shape2D.rectGradientV { posX: 10, posY: 150, width: 200, height: 50, top: white, bottom: blue },
        Shape2D.text { text: "Hello World", posX: 10, posY: 250, size: 20, color: white },
        Shape2D.circle { centerX: 300, centerY: 100, radius: 50, color: red },
        Shape2D.circleGradient { centerX: 300, centerY: 200, radius: 35, inner: red, outer: blue },
    ]

    Task.ok model
    |> Stateful.render leftButton
    |> Stateful.render rightButton
    |> Stateful.render elements
    |> Stateful.render model.middle
    |> Stateful.render (Shape2D.text { text: "ENTER TEXT HERE", posX: 10, posY: 550, size: 20, color: blue })

white = { r: 255, g: 255, b: 255, a: 255 }
blue = { r: 0, g: 0, b: 255, a: 255 }
red = { r: 255, g: 0, b: 0, a: 255 }
    