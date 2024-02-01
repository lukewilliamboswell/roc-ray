app "pong"
    packages { ray: "../platform/main.roc" }
    imports [ray.Task.{ Task }, ray.Core.{ Color, Rectangle, Vector2 }, Draw.{ renderDrawables }]
    provides [main, Model] to ray

main = { init, render }

Model : {
    ball : { pos : Vector2, vel : Vector2 },
    pos : F32,
}

width = 800
height = 600

paddle = 50
pw = paddle / 4
ballSize = 20

init : Task Model []
init =
    {} <- Core.setWindowSize { width, height } |> Task.await
    {} <- Core.setWindowTitle "Pong" |> Task.await

    Task.ok { ball: { pos: { x: width / 2, y: height / 2 }, vel: { x: 5, y: 2 } }, pos: height / 2 - paddle / 2 }

moveBall = \ball ->
    { ball & pos: { x: ball.pos.x + ball.vel.x, y: ball.pos.y + ball.vel.y } }

wrap = \num, max ->
    if num < 0 then
        max
    else if num > max then
        0
    else
        num

wrapScreen = \ball -> { ball & pos: { x: wrap ball.pos.x width, y: wrap ball.pos.y height } }

render : Model -> Task Model []
render = \model ->
    { y } <- Core.getMousePosition |> Task.await
    pos = model.pos + (y - model.pos) / 5
    {} <- renderDrawables [
            Fill (Rect { x: 0, y: pos, width: pw, height: paddle }, white),
            Fill (Rect { x: model.ball.pos.x, y: model.ball.pos.y, width: ballSize, height: ballSize }, white),
        ]
        |> Task.await

    Task.ok { model & pos: pos, ball: wrapScreen (moveBall model.ball) }

white = { r: 255, g: 255, b: 255, a: 255 }
