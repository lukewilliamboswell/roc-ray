app [main, Model] {
    ray: platform "../platform/main.roc",
}

import ray.Raylib
import ray.Drawable exposing [draw]
import ray.Shape2D

main = { init, render }

Model : {
    width : F32,
    height : F32,
}

init : Task Model {}
init =

    width = 800f32
    height = 600f32

    Raylib.setWindowSize! { width, height }
    Raylib.setWindowTitle! "Basic Shapes"

    Task.ok {
        width,
        height,
    }

render : Model -> Task Model {}
render = \model ->

    Task.forEach!
        [
            Shape2D.rect { posX: 10, posY: 50, width: 200, height: 50, color: white },
            Shape2D.rectGradientV { posX: 10, posY: 150, width: 200, height: 50, top: white, bottom: blue },
            Shape2D.text { text: "Hello World", posX: 10, posY: 250, size: 20, color: white },
            Shape2D.circle { centerX: 300, centerY: 100, radius: 50, color: red },
            Shape2D.circleGradient { centerX: model.width / 2, centerY: model.height / 2, radius: 35, inner: red, outer: blue },
        ]
        draw

    # return the model unchanged for next render
    Task.ok model

white = { r: 255, g: 255, b: 255, a: 255 }
blue = { r: 0, g: 0, b: 255, a: 255 }
red = { r: 255, g: 0, b: 0, a: 255 }
