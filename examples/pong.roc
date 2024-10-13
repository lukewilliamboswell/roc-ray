app [main, Model] {
    ray: platform "../platform/main.roc",
}

import ray.Raylib exposing [Program, PlatformState, Vector2]

main : Program Model
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

    Raylib.setBackgroundColor! Navy
    Raylib.setDrawFPS! { fps: Visible }
    Raylib.setWindowSize! { width, height }
    Raylib.setWindowTitle! "Pong"

    Task.ok {
        ball: newBall,
        pos: height / 2 - paddle / 2,
        score: 0,
        playing: Bool.false,
        maxScore: 0,
    }

moveBall : Ball -> Ball
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

render : Model, PlatformState -> Task Model {}
render = \model, { frameCount, mouseButtons, mousePos } ->
    if !model.playing then
        Raylib.drawText! { text: "Click to start", x: 50, y: 120, size: 20, color: White }

        maxScore = model.maxScore |> Num.toStr

        Raylib.drawText! { text: "Max Score: $(maxScore)", x: 50, y: 50, size: 20, color: White }

        score = model.score |> Num.toStr

        Raylib.drawText! { text: "Last Score: $(score)", x: 50, y: 80, size: 20, color: White }

        if Set.contains mouseButtons MouseButtonLeft then
            Task.ok { model & playing: Bool.true, score: 0 }
        else
            Task.ok model
    else
        # Increase the speed of the ball, starts getting crazy after a minute... just for a bit of fun
        Raylib.setTargetFPS! (60 + ((Num.toFrac frameCount) / 60 |> Num.floor |> Num.toI32))

        score = model.score |> Num.toStr

        Raylib.drawText! { text: "Score: $(score)", x: 50, y: 50, size: 20, color: White }

        pos = model.pos + (mousePos.y - model.pos) / 5

        Raylib.drawRectangle! { x: 0, y: pos, width: pw, height: paddle, color: Aqua }
        Raylib.drawRectangle! { x: model.ball.pos.x, y: model.ball.pos.y, width: ballSize, height: ballSize, color: Green }

        drawCrossHair! mousePos

        ball = bounce (moveBall model.ball) model.pos

        if ball.pos.x <= 0 then
            Task.ok { model & pos: pos, ball: newBall, maxScore: Num.max model.score model.maxScore, playing: Bool.false }
        else
            Task.ok { model & pos: pos, ball: ball, score: model.score + 1 }

drawCrossHair : Vector2 -> Task {} {}
drawCrossHair = \mousePos ->

    Raylib.drawLine! {
        start: { x: mousePos.x, y: 0 },
        end: { x: mousePos.x, y: height },
        color: Yellow,
    }

    Raylib.drawLine! {
        start: { x: 0, y: mousePos.y },
        end: { x: width, y: mousePos.y },
        color: Yellow,
    }
