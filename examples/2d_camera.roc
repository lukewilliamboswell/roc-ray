app [Model, init!, render!] {
    rr: platform "../platform/main.roc",
    rand: "https://github.com/lukewilliamboswell/roc-random/releases/download/0.5.0/yDUoWipuyNeJ-euaij4w_ozQCWtxCsywj68H0PlJAdE.tar.br",
    time: "https://github.com/imclerran/roc-isodate/releases/download/v0.6.0/79DATSmwkFXMsS0dF7w1RTHeQCGwFNzh9zylic4Fw9w.tar.br",
}

import rr.RocRay exposing [Vector2, Rectangle, Color, Camera]
import rr.Keys
import rr.Draw
import rr.Camera
import rand.Random

screen_width = 800
screen_height = 450

Model : {
    player : { x : F32, y : F32 },
    buildings : List { rect : Rectangle, color : Color },
    camera_settings : {
        target : Vector2,
        offset : Vector2,
        rotation : F32,
        zoom : F32,
    },
    camera : Camera,
}

init! : {} => Result Model _
init! = |{}|

    RocRay.set_target_fps!(60)
    RocRay.display_fps!({ fps: Visible, pos: { x: 10, y: 10 } })

    RocRay.init_window!({ title: "2D Camera Example", width: screen_width, height: screen_height })

    player = { x: 400, y: 280 }

    camera_settings = {
        target: player,
        offset: { x: screen_width / 2, y: screen_height / 2 },
        rotation: 0,
        zoom: 1,
    }

    camera = Camera.create!(camera_settings)?

    buildings = generate_buildings

    Ok(
        {
            player,
            buildings,
            camera,
            camera_settings,
        },
    )

render! : Model, RocRay.PlatformState => Result Model []
render! = |model, { mouse, keys }|

    # UPDATE CAMERA
    rotation =
        (
            if Keys.down(keys, KeyA) then
                model.camera_settings.rotation - 1
            else if Keys.down(keys, KeyS) then
                model.camera_settings.rotation + 1
            else
                model.camera_settings.rotation
        )
        |> limit({ upper: 40, lower: -40 })
        |> |r| if Keys.pressed(keys, KeyR) then 0 else r

    zoom =
        (model.camera_settings.zoom + (mouse.wheel * 0.05))
        |> limit({ upper: 3, lower: 0.1 })
        |> |z| if Keys.pressed(keys, KeyR) then 1 else z

    camera_settings =
        model.camera_settings
        |> &target(model.player)
        |> &rotation(rotation)
        |> &zoom(zoom)

    Camera.update!(model.camera, camera_settings)

    # UPDATE PLAYER
    player =
        if Keys.down(keys, KeyLeft) then
            { x: model.player.x - 10, y: model.player.y }
        else if Keys.down(keys, KeyRight) then
            { x: model.player.x + 10, y: model.player.y }
        else
            model.player

    # RENDER FRAMEBUFFER
    Draw.draw!(
        White,
        |{}|

            # RENDER WORLD
            Draw.with_mode_2d!(
                model.camera,
                |{}|
                    draw_world!(model),
            )

            # RENDER SCREEN UI
            draw_screen_ui!({}),
    )

    Ok({ model & camera_settings, player })

draw_world! : Model => {}
draw_world! = |model|

    # BACKGROUND
    Draw.rectangle!({ rect: { x: -6000, y: 320, width: 13000, height: 8000 }, color: Gray })

    # BUILDINGS
    List.for_each!(model.buildings, Draw.rectangle!)

    # PLAYER
    player_width = 40
    player_height = 80

    Draw.rectangle!(
        {
            rect: {
                x: model.player.x - (player_width / 2),
                y: model.player.y - (player_height / 2),
                width: player_width,
                height: player_height,
            },
            color: Red,
        },
    )

    # PLAYER CROSSHAIR
    Draw.line!({ start: { x: model.player.x, y: (-screen_height) * 10 }, end: { x: model.player.x, y: screen_height * 10 }, color: Yellow })
    Draw.line!({ start: { x: (-screen_width) * 10, y: model.player.y }, end: { x: screen_width * 10, y: model.player.y }, color: Yellow })

draw_screen_ui! : {} => {}
draw_screen_ui! = |{}|

    Draw.text!({ pos: { x: 640, y: 10 }, text: "SCREEN AREA", size: 20, color: Red })

    Draw.rectangle!({ rect: { x: 0, y: 0, width: screen_width, height: 5 }, color: Red })
    Draw.rectangle!({ rect: { x: 0, y: 5, width: 5, height: screen_height - 10 }, color: Red })
    Draw.rectangle!({ rect: { x: screen_width - 5, y: 5, width: 5, height: screen_height - 10 }, color: Red })
    Draw.rectangle!({ rect: { x: 0, y: screen_height - 5, width: screen_width, height: 5 }, color: Red })

    Draw.rectangle!({ rect: { x: 10, y: 20, width: 250, height: 113 }, color: RGBA(116, 255, 255, 128) })

    Draw.text!({ pos: { x: 20, y: 30 }, text: "Free 2d camera controls:", size: 10, color: Black })
    Draw.text!({ pos: { x: 40, y: 50 }, text: "- Right/Left to move Offset", size: 10, color: Black })
    Draw.text!({ pos: { x: 40, y: 70 }, text: "- Mouse Wheel to Zoom in-out", size: 10, color: Black })
    Draw.text!({ pos: { x: 40, y: 90 }, text: "- A / S to Rotate", size: 10, color: Black })
    Draw.text!({ pos: { x: 40, y: 110 }, text: "- R to reset Zoom and Rotation", size: 10, color: Black })

generate_buildings : List { rect : Rectangle, color : Color }
generate_buildings =
    List.range({ start: At(0), end: Before(100) })
    |> List.walk(
        { seed: Random.seed(1234), rects: [], next_x: -6000 },
        |state, _|

            bldg_gen = Random.step(state.seed, random_building)

            bldg = bldg_gen.value

            rect = {
                x: state.next_x,
                y: screen_height - 130 - bldg.rect.height,
                width: bldg.rect.width,
                height: bldg.rect.height,
            }

            rects = List.append(state.rects, { bldg & rect })

            { seed: bldg_gen.state, rects, next_x: state.next_x + bldg.rect.width },
    )
    |> .rects

random_building : Random.Generator { rect : Rectangle, color : Color }
random_building =
    { Random.chain <-
        rect: { Random.chain <-
            x: Random.static(0),
            y: Random.static(0),
            width: Random.bounded_u16(50, 200) |> Random.map(Num.to_f32),
            height: Random.bounded_u16(100, 800) |> Random.map(Num.to_f32),
        }
        |> Random.map(|a| a),
        color: { Random.chain <-
            red: Random.bounded_u8(200, 240),
            green: Random.bounded_u8(200, 240),
            blue: Random.bounded_u8(200, 250),
        }
        |> Random.map(|{ red, green, blue }| RGBA(red, green, blue, 255)),
    }

limit : F32, { upper : F32, lower : F32 } -> F32
limit = |value, { upper, lower }|
    if value > upper then
        upper
    else if value < lower then
        lower
    else
        value
