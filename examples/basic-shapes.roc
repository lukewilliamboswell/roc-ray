app [main, Model] {
    ray: platform "../platform/main.roc",
}

import ray.Raylib

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

    Raylib.drawText! { text: "Hello World", x: 10, y: 250, size: 20, color: white }
    Raylib.drawRectangle! { x: 10, y: 50, width: 200, height: 50, color: white }
    Raylib.drawRectangleGradientV! { x: 10, y: 150, width: 200, height: 50, top: white, bottom: blue }
    Raylib.drawCircle! { x: 300, y: 100, radius: 50, color: red }
    Raylib.drawCircleGradient! { x: model.width / 2, y: model.height / 2, radius: 35, inner: red, outer: blue }

    # return the model unchanged for next render
    Task.ok model

white = { r: 255, g: 255, b: 255, a: 255 }
blue = { r: 0, g: 0, b: 255, a: 255 }
red = { r: 255, g: 0, b: 0, a: 255 }
