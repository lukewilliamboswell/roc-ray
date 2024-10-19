app [main, Model] { ray: platform "../platform/main.roc" }

import ray.RocRay exposing [PlatformState, Texture]

width = 800
height = 600

Model : {
    dude : Texture,
}

main : RocRay.Program Model _
main = { init, render }

init =

    RocRay.setTargetFPS! 2
    RocRay.setWindowSize! { width, height }
    RocRay.setWindowTitle! "Basic Shapes"
    RocRay.setBackgroundColor! White

    dude = RocRay.loadTexture! "examples/assets/sprite-dude/sheet.png"

    Task.ok { dude }

render : Model, PlatformState -> Task Model _
render = \model, _ ->

    RocRay.drawText! { pos: {x: 10, y: 10}, text: "Rocci the Cool Dude", size: 40, color: Navy }

    RocRay.drawTextureRec! {
        texture: model.dude,
        source: {
            x: 10,
            y: 50,
            width: 65,
            height: 65,
        },
        pos: {
            x: 100,
            y: 100,
        },
        tint: Blue,
    }

    Task.ok model
