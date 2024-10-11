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
        squares: [],
        status: Ready,
    }

render : Model -> Task Model {}
render = \model ->

    Raylib.drawText! { text: "Click on the screen ...", x: model.width - 400, y: model.height - 25, size: 20, color: White }

    { x, y } = Raylib.getMousePosition!

    { left, right } = Raylib.mouseButtons!

    leftStr = if left then ", LEFT" else ""
    rightSTr = if right then ", RIGHT" else ""

    Raylib.drawText! {
        text: "Mouse $(Num.toStr (Num.round x)),$(Num.toStr (Num.round y))$(leftStr)$(rightSTr)",
        x: 10,
        y: model.height - 25,
        size: 20,
        color: White,
    }

    Task.ok model
