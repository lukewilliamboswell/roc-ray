app [Model, init!, render!] { rr: platform "../platform/main.roc" }

import rr.RocRay exposing [Vector2, Rectangle]
import rr.Draw
import rr.Mouse

Model : {
    message : Str,
}

init! : {} => Result Model _
init! = |{}|

    RocRay.init_window!({ title: "Reload Text" })

    message = RocRay.load_file_to_str!("examples/assets/reload-text/message.txt")?

    Ok({ message })

render! : Model, RocRay.PlatformState => Result Model _
render! = |model, { mouse }|

    button_rect = {
        x: 100,
        y: 200,
        width: 100,
        height: 50,
    }

    Draw.draw!(
        White,
        |{}|
            Draw.text!(
                {
                    text: model.message,
                    size: 20,
                    color: Gray,
                    pos: { x: 100, y: 100 },
                },
            )

            Draw.rectangle!({ rect: button_rect, color: Gray })
            Draw.text!(
                {
                    text: "Reload",
                    size: 20,
                    color: White,
                    pos: { x: button_rect.x + 10, y: button_rect.y + 10 },
                },
            ),
    )

    if Mouse.pressed(mouse.buttons.left) and within(mouse.position, button_rect) then
        message = RocRay.load_file_to_str!("examples/assets/reload-text/message.txt")?
        Ok({ message })
    else
        Ok(model)

within : Vector2, Rectangle -> Bool
within = |pos, rect|
    within_x = pos.x > rect.x and pos.x < rect.x + rect.width
    within_y = pos.x > rect.x and pos.x < rect.y + rect.height
    within_x and within_y
