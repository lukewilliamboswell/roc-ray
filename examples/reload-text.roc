app [Model, init, render] { rr: platform "../platform/main.roc" }

import rr.RocRay exposing [Vector2, Rectangle]
import rr.Draw
import rr.Mouse

Model : {
    message : Str,
}

init : Task Model []
init =
    message = RocRay.loadFileToStr! "examples/assets/reload-text/message.txt"

    RocRay.setWindowSize! { width: 800, height: 600 }
    RocRay.setWindowTitle! "Reload Text"

    Task.ok { message }

render : Model, RocRay.PlatformState -> Task Model []
render = \model, { mouse } ->
    dbg mouse

    buttonRect = {
        x: 100,
        y: 200,
        width: 100,
        height: 50,
    }

    Draw.draw! White \{} ->
        Draw.text! {
            text: model.message,
            size: 20,
            color: Gray,
            pos: { x: 100, y: 100 },
        }

        Draw.rectangle! { rect: buttonRect, color: Gray }
        Draw.text! {
            text: "Reload",
            size: 20,
            color: White,
            pos: { x: buttonRect.x + 10, y: buttonRect.y + 10 },
        }

    if Mouse.pressed mouse.buttons.left && within mouse.position buttonRect then
        message = RocRay.loadFileToStr! "examples/assets/reload-text/message.txt"
        Task.ok { message }
    else
        Task.ok model

within : Vector2, Rectangle -> Bool
within = \pos, rect ->
    withinX = pos.x > rect.x && pos.x < rect.x + rect.width
    withinY = pos.x > rect.x && pos.x < rect.y + rect.height
    withinX && withinY
