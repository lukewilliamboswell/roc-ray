app [Model, init!, render!] { rr: platform "../platform/main.roc" }

import rr.RocRay
import rr.Draw

width = 800
height = 600

Model : {}

init! : {} => Result Model []
init! = |{}|

    RocRay.init_window!({ title: "Basic Shapes", width, height })

    Ok({})

render! : Model, RocRay.PlatformState => Result Model []
render! = |_, {}|

    Draw.draw!(
        White,
        |{}|
            Draw.text!({ pos: { x: 10, y: 10 }, text: "Hello World!", size: 40, color: Navy })
            Draw.rectangle!({ rect: { x: 100, y: 150, width: 250, height: 100 }, color: Aqua })
            Draw.rectangle_gradient_h!({ rect: { x: 400, y: 150, width: 250, height: 100 }, left: Lime, right: Navy })
            Draw.rectangle_gradient_v!({ rect: { x: 300, y: 250, width: 250, height: 100 }, top: Maroon, bottom: Green })
            Draw.circle!({ center: { x: 200, y: 400 }, radius: 75, color: Fuchsia })
            Draw.circle_gradient!({ center: { x: 600, y: 400 }, radius: 75, inner: Yellow, outer: Maroon })
            Draw.line!({ start: { x: 100, y: 500 }, end: { x: 500, y: 500 }, color: Red }),
    )

    Ok({})
