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

    Raylib.drawText! { text: "Click on the screen to draw a square", posX: model.width - 400, posY: model.height - 25, fontSize: 20, color: white }

    { x, y } = Raylib.getMousePosition!

    { left, right } = Raylib.mouseButtons!

    leftStr = if left then ", LEFT" else ""
    rightSTr = if right then ", RIGHT" else ""

    Raylib.drawText! {
        text: "Mouse $(Num.toStr (Num.round x)),$(Num.toStr (Num.round y))$(leftStr)$(rightSTr)",
        posX: 10,
        posY: model.height - 25,
        fontSize: 20,
        color: white,
    }

    Task.ok model

# TODO restore this code

## Draw the squares
# _ =
#    model.squares
#    |> List.map \square ->
#        Shape2D.rect {
#            posX: Num.round square.x,
#            posY: Num.round square.y,
#            width: Num.round square.width,
#            height: Num.round square.height,
#            color: white,
#        }
#    |> Task.forEach! draw

# when model.status is
#    Ready ->
#        if isMousePressed then
#            Task.ok { model & status: AfterClick { x, y } }
#        else
#            Task.ok model

#    AfterClick start ->
#        new = {
#            x: if start.x < x then start.x else x,
#            y: if start.y < y then start.y else y,
#            width: Num.absDiff start.x x,
#            height: Num.absDiff start.y y,
#        }

#        if isMousePressed then
#            Task.ok { model & status: Ready, squares: List.append model.squares new }
#        else
#            # Draw the in-progress sqaure, but don't update the model
#            _ =  Raylib.drawRectangle! {
#                    x: new.x,
#                    y: new.y,
#                    width: new.width,
#                    height: new.height,
#                    color: green,
#                }

#            Task.ok model

# green = { r: 0, g: 255, b: 0, a: 255 }
white = { r: 255, g: 255, b: 255, a: 255 }
