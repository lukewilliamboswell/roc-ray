app [main, Model] {
    rr: platform "../platform/main.roc",
}

import rr.RocRay exposing [PlatformState, Rectangle]
import rr.Keys

Model : {
    squares : List Rectangle,
    status : [Ready, AfterClick RocRay.Vector2],
    circlePos : RocRay.Vector2,
}

width = 900
height = 400

main : RocRay.Program Model []
main = { init!, render! }

init! : {} => Result Model []
init! = \{} ->

    RocRay.setWindowSize! { width, height }
    RocRay.setWindowTitle! "Squares Demo"

    Ok {
        circlePos: { x: width / 2, y: height / 2 },
        squares: [],
        status: Ready,
    }

render! : Model, PlatformState => Result Model []
render! = \model, { keys, mouse } ->

    RocRay.beginDrawing! Black

    RocRay.drawText! { pos: { x: width - 400, y: height - 25 }, text: "Click on the screen ...", size: 20, color: White }

    mousePos = mouse.position

    RocRay.drawText! {
        pos: {
            x: 10,
            y: height - 25,
        },
        text: "Mouse $(Num.toStr mousePos.x),$(Num.toStr mousePos.y)",
        size: 20,
        color: White,
    }

    RocRay.drawRectangle! { rect: { x: Num.toF32 mousePos.x - 10, y: Num.toF32 mousePos.y - 10, width: 20, height: 20 }, color: Red }

    RocRay.drawCircle! { center: model.circlePos, radius: 50, color: Aqua }

    RocRay.endDrawing! {}

    newCirclePos =
        if Keys.down keys KeyUp then
            { x: model.circlePos.x, y: model.circlePos.y - 10 }
        else if Keys.down keys KeyDown then
            { x: model.circlePos.x, y: model.circlePos.y + 10 }
        else if Keys.down keys KeyLeft then
            { x: model.circlePos.x - 10, y: model.circlePos.y }
        else if Keys.down keys KeyRight then
            { x: model.circlePos.x + 10, y: model.circlePos.y }
        else
            model.circlePos

    Ok { model & circlePos: newCirclePos }
