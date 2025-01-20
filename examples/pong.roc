app [Model, init!, render!] { rr: platform "../platform/main.roc" }

import rr.RocRay exposing [Vector2]
import rr.Mouse
import rr.Draw

Ball : { pos : Vector2, vel : Vector2 }

Model : {
    screen : [StartMenu, Playing, GameOver],
    max_score : I32,
    score : I32,
    ball : Ball,
    pos : F32,
}

width = 800
height = 600

paddle = 50
pw = paddle / 4
ball_size = 20

new_ball = {
    pos: { x: width / 2, y: height / 2 },
    vel: { x: 5, y: 2 },
}

init! : {} => Result Model []
init! = |{}|

    RocRay.set_target_fps!(120)
    RocRay.display_fps!({ fps: Visible, pos: { x: 10, y: 10 } })
    RocRay.init_window!({ title: "Pong", width, height })

    Ok(
        {
            screen: StartMenu,
            ball: new_ball,
            pos: height / 2 - paddle / 2,
            score: 0,
            max_score: 0,
        },
    )

move_ball : Ball -> Ball
move_ball = |ball|
    x = ball.pos.x + ball.vel.x
    y = ball.pos.y + ball.vel.y
    { ball & pos: { x, y } }

bounce : Ball, F32 -> Ball
bounce = |ball, pos|
    { x, y } = ball.pos
    { x: vx, y: vy } = ball.vel

    (x2, vx2, vy2) =
        if x > width - ball_size then
            (width - ball_size, (-vx) * 1.1, vy)
        else if x < pw and y + ball_size > pos and y < pos + paddle then
            (pw, (-vx) * 1.1, vy * 1.1)
        else
            (x, vx, vy)

    (y2, vy3) =
        if y < 0 then
            (0, (-vy2) * 1.1)
        else if y > height - ball_size then
            (height - ball_size, (-vy2) * 1.1)
        else
            (y, vy2)

    { pos: { x: x2, y: y2 }, vel: { x: vx2, y: vy3 } }

render! : Model, RocRay.PlatformState => Result Model []
render! = |model, state|
    begin_game_on_click = |old_model|
        if Mouse.pressed(state.mouse.buttons.left) then
            { old_model & screen: Playing, score: 0, ball: new_ball }
        else
            old_model

    when model.screen is
        StartMenu ->
            Draw.draw!(
                Navy,
                |{}|
                    draw_game_start_menu!(model),
            )

            Ok(begin_game_on_click(model))

        GameOver ->
            Draw.draw!(
                Navy,
                |{}|
                    draw_game_playing!(model, state)
                    draw_game_start_menu!(model),
            )

            Ok(begin_game_on_click(model))

        Playing ->
            # Increase the speed of the ball, starts getting crazy after a minute... just for a bit of fun
            RocRay.set_target_fps!((60 + ((Num.to_frac(state.frame_count)) / 60 |> Num.floor |> Num.to_i32)))

            new_model = update(model, state)

            Draw.draw!(
                Navy,
                |{}|
                    draw_game_playing!(new_model, state),
            )

            Ok(new_model)

update : Model, RocRay.PlatformState -> Model
update = |model, state|
    ball = bounce(move_ball(model.ball), model.pos)
    new_y = model.pos + (Num.to_f32(state.mouse.position.y) - model.pos) / 5

    if ball.pos.x <= 0 then
        max_score = Num.max(model.score, model.max_score)
        { model & pos: new_y, max_score, screen: GameOver }
    else
        { model & pos: new_y, ball: ball, score: model.score + 1 }

draw_game_start_menu! : Model => {}
draw_game_start_menu! = |model|
    # DRAW START MENU
    max_score = model.max_score |> Num.to_str
    score = model.score |> Num.to_str

    Draw.text!({ pos: { x: 50, y: 120 }, text: "Click to start", size: 20, color: White })
    Draw.text!({ pos: { x: 50, y: 50 }, text: "Max Score: ${max_score}", size: 20, color: White })
    Draw.text!({ pos: { x: 50, y: 80 }, text: "Last Score: ${score}", size: 20, color: White })

draw_game_playing! : Model, RocRay.PlatformState => {}
draw_game_playing! = |model, { mouse }|
    score = model.score |> Num.to_str

    Draw.text!({ pos: { x: 650, y: 50 }, text: "Score: ${score}", size: 20, color: White })

    draw_paddle!(model)
    draw_ball!(model.ball)

    draw_cross_hair!(mouse.position)

draw_paddle! : Model => {}
draw_paddle! = |{ pos }|
    rect = { x: 0, y: pos, width: pw, height: paddle }
    Draw.rectangle!({ rect, color: Aqua })

draw_ball! : Ball => {}
draw_ball! = |ball|
    rect = { x: ball.pos.x, y: ball.pos.y, width: ball_size, height: ball_size }
    Draw.rectangle!({ rect, color: Green })

draw_cross_hair! : Vector2 => {}
draw_cross_hair! = |mouse_pos|
    Draw.line!(
        {
            start: { x: mouse_pos.x, y: 0 },
            end: { x: mouse_pos.x, y: height },
            color: Yellow,
        },
    )

    Draw.line!(
        {
            start: { x: 0, y: Num.to_f32(mouse_pos.y) },
            end: { x: width, y: Num.to_f32(mouse_pos.y) },
            color: Yellow,
        },
    )
