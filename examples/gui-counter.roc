app "counter"
    packages { ray: "../platform/main.roc" }
    imports [
        ray.Task.{ Task },
        ray.Action.{ Action },
        ray.Core.{ Program, Color, Rectangle },
        ray.GUI.{ GUI },
        Counter.{ Counter },
        SmallWindow.{ SmallWindow },
        ray.Shape2D.{ Shape2D},
    ]
    provides [main, Model] to ray

Model : { left : Counter, right : SmallWindow }

main : Program Model
main = { init, render }

init : Task Model []
init =

    {} <- Core.setWindowSize { width: 800, height: 600 } |> Task.await
    {} <- Core.setWindowTitle "Counter Demo" |> Task.await

    Task.ok { 
        left: Counter.init {count: 10, x: 10, y: 300, width: 100, height: 50},
        right: SmallWindow.init {window : Closed, x: 300, y: 300, width: 200, height: 100},
    }

render : Model -> Task Model []
render = \model ->
    Task.ok model
    |> Shape2D.renderAll [
        Shape2D.rect { posX: 10, posY: 50, width: 200, height: 50, color: white },
        Shape2D.rectGradientV { posX: 10, posY: 150, width: 200, height: 50, top: white, bottom: blue },
        Shape2D.text { text: Inspect.toStr model, posX: 10, posY: 250, size: 10, color: white },
        Shape2D.circle { centerX: 300, centerY: 100, radius: 50, color: red },
        Shape2D.circleGradient { centerX: 300, centerY: 200, radius: 35, inner: red, outer: blue },
    ]
    |> Shape2D.render (Shape2D.text { text: "ENTER TEXT HERE", posX: 10, posY: 550, size: 20, color: blue })
    |> GUI.render (leftButton model)
    |> GUI.render (rightButton model)

white = { r: 255, g: 255, b: 255, a: 255 }
blue = { r: 0, g: 0, b: 255, a: 255 }
red = { r: 255, g: 0, b: 0, a: 255 }
    
leftButton : Model -> GUI Model
leftButton = \model ->
    GUI.translate
        (Counter.render model.left)
        \parent -> parent.left
        \parent, child -> { parent & left: child }

rightButton : Model -> GUI Model
rightButton = \model ->
    GUI.translate
        (SmallWindow.render model.right)
        \parent -> parent.right
        \parent, child -> { parent & right: child }
