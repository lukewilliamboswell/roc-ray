app [main, Model] { ray: platform "../platform/main.roc" }

import ray.RocRay exposing [PlatformState]

width = 800
height = 600

Model : {
    #dude : Texture,
}

main : RocRay.Program Model []
main = { init, render }

init =

    RocRay.setTargetFPS! 2
    RocRay.setWindowSize! { width, height }
    RocRay.setWindowTitle! "Basic Shapes"
    RocRay.setBackgroundColor! White

    #dude = RocRay.loadTexture! "examples/assets/sprite-dude/sheet.png"

    #Task.ok { dude }
    Task.ok {}

render : Model, PlatformState -> Task Model []
render = \model, _ ->

    RocRay.drawText! { text: "Rocci the Cool Dude", x: 10, y: 10, size: 40, color: Navy }

    #source = {
    #    x: 10,
    #    y: 50,
    #    width: 65,
    #    height: 65,
    #}

    #postion = {
    #    x: 100,
    #    y: 100,
    #}

    #RocRay.drawTextureRec! model.dude source postion Blue

    Task.ok model
