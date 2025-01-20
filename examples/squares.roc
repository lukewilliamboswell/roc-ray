app [Model, init!, render!] { rr: platform "../platform/main.roc" }

import rr.RocRay exposing [Rectangle, Vector2]
import rr.Keys
import rr.Draw

Model : {
    squares : List Rectangle,
    status : [Ready, AfterClick Vector2],
    circle_pos : Vector2,
}

width = 900
height = 400

init! : {} => Result Model []
init! = |{}|

    RocRay.init_window!({ title: "Squares Demo", width, height })

    Ok(
        {
            circle_pos: { x: width / 2, y: height / 2 },
            squares: [],
            status: Ready,
        },
    )

render! : Model, RocRay.PlatformState => Result Model []
render! = |model, { keys, mouse }|

    mouse_pos = mouse.position

    new_circle_pos =
        if Keys.down(keys, KeyUp) then
            { x: model.circle_pos.x, y: model.circle_pos.y - 10 }
        else if Keys.down(keys, KeyDown) then
            { x: model.circle_pos.x, y: model.circle_pos.y + 10 }
        else if Keys.down(keys, KeyLeft) then
            { x: model.circle_pos.x - 10, y: model.circle_pos.y }
        else if Keys.down(keys, KeyRight) then
            { x: model.circle_pos.x + 10, y: model.circle_pos.y }
        else
            model.circle_pos

    Draw.draw!(
        Black,
        |{}|

            Draw.text!({ pos: { x: width - 400, y: height - 25 }, text: "Mouse the mouse around the screen ...", size: 20, color: White })

            Draw.text!(
                {
                    pos: { x: 10, y: height - 25 },
                    text: "Mouse ${Num.to_str(mouse_pos.x)},${Num.to_str(mouse_pos.y)}",
                    size: 20,
                    color: White,
                },
            )

            Draw.rectangle!({ rect: { x: Num.to_f32(mouse_pos.x) - 10, y: Num.to_f32(mouse_pos.y) - 10, width: 20, height: 20 }, color: Red })

            Draw.circle!({ center: model.circle_pos, radius: 50, color: Aqua }),
    )

    Ok({ model & circle_pos: new_circle_pos })
