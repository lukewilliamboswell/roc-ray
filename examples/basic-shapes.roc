app [main, Model] {
    ray: platform "../platform/main.roc",
}

import ray.Core
import ray.Drawable exposing [draw]
import ray.Shape2D

main = { init, render }

Model : {}

width = 800
height = 600

init : Task Model {}
init =
    _ = Core.setWindowSize! { width, height }
    _ = Core.setWindowTitle! "Basic Shapes"

    Task.ok {}

render : Model -> Task Model {}
render = \_ ->

    shapes = [
        Shape2D.rect { posX: 10, posY: 50, width: 200, height: 50, color: white },
        Shape2D.rectGradientV { posX: 10, posY: 150, width: 200, height: 50, top: white, bottom: blue },
        Shape2D.text { text: "Hello World", posX: 10, posY: 250, size: 20, color: white },
        Shape2D.circle { centerX: 300, centerY: 100, radius: 50, color: red },
        Shape2D.circleGradient { centerX: 300, centerY: 200, radius: 35, inner: red, outer: blue },
    ]

    _ = shapes |> Task.forEach! draw

    Task.ok {}

white = { r: 255, g: 255, b: 255, a: 255 }
blue = { r: 0, g: 0, b: 255, a: 255 }
red = { r: 255, g: 0, b: 0, a: 255 }
