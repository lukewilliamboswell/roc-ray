app [main, Model] { ray: platform "../platform/main.roc" }

import ray.RocRay

width = 800
height = 600

Model : {}

main : RocRay.Program Model []
main = { init, render }

init =

    RocRay.setWindowSize! { width, height }
    RocRay.setWindowTitle! "Basic Shapes"

    Task.ok {}

render = \_, _ ->

    RocRay.drawText! { text: "Hello World", x: 300, y: 50, size: 40, color: Navy }
    RocRay.drawRectangle! { x: 100, y: 150, width: 250, height: 100, color: Aqua }
    RocRay.drawRectangleGradient! { x: 400, y: 150, width: 250, height: 100, top: Lime, bottom: Green }
    RocRay.drawCircle! { x: 200, y: 400, radius: 75, color: Fuchsia }
    RocRay.drawCircleGradient! { x: 600, y: 400, radius: 75, inner: Yellow, outer: Maroon }

    Task.ok {}
