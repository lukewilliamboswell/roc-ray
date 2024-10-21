app [main, Model] { rr: platform "../platform/main.roc" }

import rr.RocRay exposing [PlatformState]

width = 800
height = 600

Model : {}

main : RocRay.Program Model []
main = { init, render }

init : Task Model []
init =

    RocRay.setWindowSize! { width, height }
    RocRay.setWindowTitle! "Basic Shapes"

    Task.ok {}

render : Model, PlatformState -> Task Model []
render = \_, _ ->

    RocRay.beginDrawing! White

    RocRay.drawText! { pos: { x: 300, y: 50 }, text: "Hello World", size: 40, color: Navy }
    RocRay.drawRectangle! { rect: { x: 100, y: 150, width: 250, height: 100 }, color: Aqua }
    RocRay.drawRectangleGradientH! { rect: { x: 400, y: 150, width: 250, height: 100 }, top: Lime, bottom: Navy }
    RocRay.drawRectangleGradientV! { rect: { x: 300, y: 250, width: 250, height: 100 }, top: Maroon, bottom: Green }
    RocRay.drawCircle! { center: { x: 200, y: 400 }, radius: 75, color: Fuchsia }
    RocRay.drawCircleGradient! { center: { x: 600, y: 400 }, radius: 75, inner: Yellow, outer: Maroon }
    RocRay.drawLine! { start: { x: 100, y: 500 }, end: { x: 500, y: 500 }, color: Red }

    RocRay.endDrawing!

    Task.ok {}
