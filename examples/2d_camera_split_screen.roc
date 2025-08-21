app [Model, init!, render!] {
    rr: platform "../platform/main.roc",
}

import rr.RocRay exposing [Rectangle]
import rr.Draw
import rr.Camera
import rr.RenderTexture
import rr.Keys

screen_width = 800
screen_height = 440
player_size = 40

Model : {
    player_one : Rectangle,
    player_two : Rectangle,
    settings_left : Camera.Settings,
    settings_right : Camera.Settings,
    camera_left : RocRay.Camera,
    camera_right : RocRay.Camera,
    screen_left : RocRay.RenderTexture,
    screen_right : RocRay.RenderTexture,
}

init! : {} => Result Model _
init! = |{}|

    RocRay.init_window!(
        {
            title: "2D camera split-screen",
            width: screen_width,
            height: screen_height,
        },
    )

    player_one = { x: 200, y: 200, width: player_size, height: player_size }
    player_two = { x: 250, y: 200, width: player_size, height: player_size }

    settings_left = {
        target: { x: player_one.x, y: player_one.y },
        offset: { x: 200, y: 200 },
        rotation: 0,
        zoom: 1,
    }

    settings_right = {
        target: { x: player_two.x, y: player_two.y },
        offset: { x: 200, y: 200 },
        rotation: 0,
        zoom: 1,
    }

    # TODO replace with something more normal once we have `try` available
    when (Camera.create!(settings_left), Camera.create!(settings_right), RenderTexture.create!({ width: screen_width / 2, height: screen_height }), RenderTexture.create!({ width: screen_width / 2, height: screen_height })) is
        (Ok(camera_left), Ok(camera_right), Ok(screen_left), Ok(screen_right)) ->
            Ok(
                {
                    player_one,
                    player_two,
                    settings_left,
                    settings_right,
                    camera_left,
                    camera_right,
                    screen_left,
                    screen_right,
                },
            )

        _ -> crash("Failed to create camera or render texture.")

render! : Model, RocRay.PlatformState => Result Model []
render! = |model, { keys }|

    # RENDER THE SCENE INTO THE LEFT SCREEN TEXTURE
    Draw.with_texture!(
        model.screen_left,
        White,
        |{}|

            Draw.with_mode_2d!(
                model.camera_left,
                |{}|

                    draw_grid!({})

                    Draw.rectangle!({ rect: model.player_one, color: Red })
                    Draw.rectangle!({ rect: model.player_two, color: Blue })

                    Draw.text!({ pos: { x: 10, y: 10 }, text: "PLAYER1: W/S/A/D to move", size: 10, color: Red }),
            ),
    )

    # RENDER THE SCENE INTO THE RIGHT SCREEN TEXTURE
    Draw.with_texture!(
        model.screen_right,
        White,
        |{}|

            Draw.with_mode_2d!(
                model.camera_right,
                |{}|

                    draw_grid!({})

                    Draw.rectangle!({ rect: model.player_one, color: Red })
                    Draw.rectangle!({ rect: model.player_two, color: Blue })

                    Draw.text!({ pos: { x: 10, y: 10 }, text: "PLAYER2: UP/DOWN/LEFT/RIGHT to move", size: 10, color: Blue }),
            ),
    )

    # RENDER FRAMEBUFFER
    Draw.draw!(
        White,
        |{}|

            # DRAW THE LEFT SCREEN TEXTURE INTO THE FRAMEBUFFER
            Draw.render_texture_rec!(
                {
                    texture: model.screen_left,
                    source: { x: 0, y: 0, width: screen_width / 2, height: -screen_height },
                    pos: { x: 0, y: 0 },
                    tint: White,
                },
            )

            # DRAW THE RIGHT SCREEN TEXTURE INTO THE FRAMEBUFFER
            Draw.render_texture_rec!(
                {
                    texture: model.screen_right,
                    source: { x: 0, y: 0, width: screen_width / 2, height: -screen_height },
                    pos: { x: screen_width / 2, y: 0 },
                    tint: White,
                },
            )

            # DRAW THE SPLIT LINE
            Draw.rectangle!({ rect: { x: (screen_width / 2) - 2, y: 0, width: 4, height: screen_height }, color: Black }),
    )

    player_one =
        if Keys.down(keys, KeyUp) then
            model.player_one |> &y((model.player_one.y - 10))
        else if Keys.down(keys, KeyDown) then
            model.player_one |> &y((model.player_one.y + 10))
        else if Keys.down(keys, KeyLeft) then
            model.player_one |> &x((model.player_one.x - 10))
        else if Keys.down(keys, KeyRight) then
            model.player_one |> &x((model.player_one.x + 10))
        else
            model.player_one

    player_two =
        if Keys.down(keys, KeyW) then
            model.player_two |> &y((model.player_two.y - 10))
        else if Keys.down(keys, KeyS) then
            model.player_two |> &y((model.player_two.y + 10))
        else if Keys.down(keys, KeyA) then
            model.player_two |> &x((model.player_two.x - 10))
        else if Keys.down(keys, KeyD) then
            model.player_two |> &x((model.player_two.x + 10))
        else
            model.player_two

    settings_left = model.settings_left |> &target({ x: model.player_one.x, y: model.player_one.y })

    settings_right = model.settings_left |> &target({ x: model.player_two.x, y: model.player_two.y })

    Camera.update!(model.camera_left, settings_left)
    Camera.update!(model.camera_right, settings_right)

    Ok({ model & player_one, player_two, settings_left, settings_right })

draw_grid! : {} => {}
draw_grid! = |{}|

    # VERTICAL LINES
    List.range({ start: At(0), end: At((screen_width / player_size)) })
    |> List.map(|i| { start: { x: player_size * i, y: 0 }, end: { x: player_size * i, y: screen_height }, color: light_gray })
    |> List.for_each!(Draw.line!)

    # HORIZONTAL LINES
    List.range({ start: At(0), end: At((screen_height / player_size)) })
    |> List.map(|j| { start: { x: 0, y: player_size * j }, end: { x: screen_width, y: player_size * j }, color: light_gray })
    |> List.for_each!(Draw.line!)

    # GRID COORDINATES
    List.range({ start: At(0), end: Before((screen_width / player_size)) })
    |> List.map(
        |i|
            List.range({ start: At(0), end: Before((screen_height / player_size)) })
            |> List.map(
                |j| {
                    pos: { x: 10 + (player_size * i), y: 15 + (player_size * j) },
                    text: "[${Num.to_str(Num.round(i))},${Num.to_str(Num.round(j))}]",
                    size: 10,
                    color: light_gray,
                },
            ),
    )
    |> List.join
    |> List.for_each!(Draw.text!)

light_gray = RGBA(200, 200, 200, 255)
