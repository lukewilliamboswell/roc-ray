app [main, Model] {
    ray: platform "../platform/main.roc",
}

import ray.Raylib exposing [Vector2]
import ray.Shape2D
import ray.Drawable exposing [draw]

main = { init, render }

Ball : { pos : Vector2, vel : Vector2 }
Model : {
    playing : Bool,
    maxScore : I32,
    score : I32,
    ball : Ball,
    pos : F32,
}

width = 800
height = 600

paddle = 50
pw = paddle / 4
ballSize = 20

newBall = { pos: { x: width / 2, y: height / 2 }, vel: { x: 5, y: 2 } }

init : Task Model {}
init =
    _ = Raylib.setWindowSize! { width, height }
    _ = Raylib.setWindowTitle! "Pong"

    Task.ok { ball: newBall, pos: height / 2 - paddle / 2, score: 0, playing: Bool.false, maxScore: 0 }

moveBall = \ball -> { ball & pos: { x: ball.pos.x + ball.vel.x, y: ball.pos.y + ball.vel.y } }

bounce : Ball, F32 -> Ball
bounce = \ball, pos ->
    { x, y } = ball.pos
    { x: vx, y: vy } = ball.vel
    (x2, vx2, vy2) =
        if x > width - ballSize then
            (width - ballSize, -vx * 1.1, vy)
        else if x < pw && y + ballSize > pos && y < pos + paddle then
            (pw, -vx * 1.1, vy * 1.1)
        else
            (x, vx, vy)
    (y2, vy3) =
        if y < 0 then
            (0, -vy2 * 1.1)
        else if y > height - ballSize then
            (height - ballSize, -vy2 * 1.1)
        else
            (y, vy2)

    { pos: { x: x2, y: y2 }, vel: { x: vx2, y: vy3 } }

render : Model -> Task Model {}
render = \model ->
    if !model.playing then
        _ = Raylib.drawText! { text: "Click to start", posX: 50, posY: 120, fontSize: 20, color: white }

        maxScore = model.maxScore |> Num.toStr
        _ = Raylib.drawText! { text: "Max Score: $(maxScore)", posX: 50, posY: 50, fontSize: 20, color: white }

        score = model.score |> Num.toStr
        _ = Raylib.drawText! { text: "Last Score: $(score)", posX: 50, posY: 80, fontSize: 20, color: white }

        {left} = Raylib.mouseButtons!
        if left then
            Task.ok { model & playing: Bool.true, score: 0 }
        else
            Task.ok model
    else
        score = model.score |> Num.toStr
        _ = Raylib.drawText! { text: "Score: $(score)", posX: 50, posY: 50, fontSize: 20, color: white }

        { y } = Raylib.getMousePosition!
        pos = model.pos + (y - model.pos) / 5

        _ = [
                Shape2D.rect { posX: 0, posY: Num.round pos, width: Num.round pw, height: paddle, color: white },
                Shape2D.rect { posX: Num.round model.ball.pos.x, posY: Num.round model.ball.pos.y, width: ballSize, height: ballSize, color: white },
            ]
            |> Task.forEach! draw

        ball = bounce (moveBall model.ball) model.pos

        if ball.pos.x <= 0 then
            Task.ok { model & pos: pos, ball: newBall, maxScore: Num.max model.score model.maxScore, playing: Bool.false }
        else
            Task.ok { model & pos: pos, ball: ball, score: model.score + 1 }

white = { r: 255, g: 255, b: 255, a: 255 }
