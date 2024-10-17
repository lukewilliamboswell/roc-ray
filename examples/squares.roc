app [main, Model] {
    ray: platform "../platform/main.roc",
}

import ray.RocRay exposing [Rectangle, PlatformState]

Program : {
    init : Task Model {},
    render : Model, PlatformState -> Task Model {},
}

Model : {
    width : F32,
    height : F32,
    squares : List Rectangle,
    status : [Ready, AfterClick RocRay.Vector2],
    circlePos : RocRay.Vector2,
}

main : Program
main = { init, render }

init : Task Model {}
init =

    width = 900f32
    height = 400f32

    RocRay.setWindowSize! { width, height }
    RocRay.setWindowTitle! "Squares Demo"

    Task.ok {
        width,
        height,
        circlePos: { x: width / 2, y: height / 2 },
        squares: [],
        status: Ready,
    }

render : Model, PlatformState -> Task Model {}
render = \model, { keyboardButtons, mouse } ->

    RocRay.drawText! { text: "Click on the screen ...", x: model.width - 400, y: model.height - 25, size: 20, color: White }

    mousePos = mouse.position

    RocRay.drawText! {
        text: "Mouse $(Num.toStr (Num.round mousePos.x)),$(Num.toStr (Num.round mousePos.y)), $(Inspect.toStr keyboardButtons), $(Inspect.toStr mouse.buttons)",
        x: 10,
        y: model.height - 25,
        size: 20,
        color: White,
    }

    RocRay.drawRectangle! { x: mousePos.x - 10, y: mousePos.y - 10, width: 20, height: 20, color: Red }

    RocRay.drawRectangle! { x: model.circlePos.x, y: model.circlePos.y, width: 50, height: 50, color: Aqua }

    newCirclePos =
        if Set.contains keyboardButtons KeyUp then
            { x: model.circlePos.x, y: model.circlePos.y - 10 }
        else if Set.contains keyboardButtons KeyDown then
            { x: model.circlePos.x, y: model.circlePos.y + 10 }
        else if Set.contains keyboardButtons KeyLeft then
            { x: model.circlePos.x - 10, y: model.circlePos.y }
        else if Set.contains keyboardButtons KeyRight then
            { x: model.circlePos.x + 10, y: model.circlePos.y }
        else
            model.circlePos

    Task.ok { model & circlePos: newCirclePos }
