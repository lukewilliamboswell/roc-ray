app [main, Model] { ray: platform "../platform/main.roc" }

import ray.Raylib

width = 800f32
height = 600f32

Model : {}

main : Raylib.Program Model []
main = { init, render }

init =

    Raylib.setWindowSize! { width, height }
    Raylib.setWindowTitle! "Basic Shapes"

    Task.ok {}

render = \_, _ ->

    Raylib.drawText! { text: "Hello World", x: 300, y: 50, size: 40, color: Navy }
    Raylib.drawRectangle! { x: 100, y: 150, width: 250, height: 100, color: Aqua }
    Raylib.drawRectangleGradient! { x: 400, y: 150, width: 250, height: 100, top: Lime, bottom: Green }
    Raylib.drawCircle! { x: 200, y: 400, radius: 75, color: Fuchsia }
    Raylib.drawCircleGradient! { x: 600, y: 400, radius: 75, inner: Yellow, outer: Maroon }

    Task.ok {}
