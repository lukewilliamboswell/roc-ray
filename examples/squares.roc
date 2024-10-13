app [main, Model] {
    ray: platform "../platform/main.roc",
}

import ray.Raylib exposing [Rectangle]

Program : {
    init : Task Model {},
    render : Model -> Task Model {},
}

Model : {
    width : F32,
    height : F32,
    squares : List Rectangle,
    status : [Ready, AfterClick Raylib.Vector2],
    circlePos : Raylib.Vector2,
}

main : Program
main = { init, render }

init : Task Model {}
init =

    width = 900f32
    height = 400f32

    Raylib.setWindowSize! { width, height }
    Raylib.setWindowTitle! "Squares Demo"

    Task.ok {
        width,
        height,
        circlePos: { x: width / 2, y: height / 2 },
        squares: [],
        status: Ready,
    }

render : Model -> Task Model {}
render = \model ->

    Raylib.drawText! { text: "Click on the screen ...", x: model.width - 400, y: model.height - 25, size: 20, color: White }

    { x: mouseX, y: mouseY } = Raylib.getMousePosition!

    { left, right } = Raylib.mouseButtons!

    leftStr = if left then ", LEFT" else ""
    rightSTr = if right then ", RIGHT" else ""

    keys = Raylib.getKeysPressed!

    Raylib.drawText! {
        text: "Mouse $(Num.toStr (Num.round mouseX)),$(Num.toStr (Num.round mouseY))$(leftStr)$(rightSTr), $(Inspect.toStr keys)",
        x: 10,
        y: model.height - 25,
        size: 20,
        color: White,
    }

    Raylib.drawRectangle! { x: mouseX - 10, y: mouseY - 10, width: 20, height: 20, color: Red }

    Raylib.drawRectangle! { x: model.circlePos.x, y: model.circlePos.y, width: 50, height: 50, color: Aqua }

    newCirclePos =
        if Set.contains keys KeyUp then
            { x: model.circlePos.x, y: model.circlePos.y - 10 }
        else if Set.contains keys KeyDown then
            { x: model.circlePos.x, y: model.circlePos.y + 10 }
        else if Set.contains keys KeyLeft then
            { x: model.circlePos.x - 10, y: model.circlePos.y }
        else if Set.contains keys KeyRight then
            { x: model.circlePos.x + 10, y: model.circlePos.y }
        else
            model.circlePos

    Task.ok { model & circlePos: newCirclePos }
