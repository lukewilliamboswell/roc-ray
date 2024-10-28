app [Model, init!, render!] {
    rr: platform "../platform/main.roc",
    rand: "https://github.com/lukewilliamboswell/roc-random/releases/download/0.3.0/hPlOciYUhWMU7BefqNzL89g84-30fTE6l2_6Y3cxIcE.tar.br",
    time: "https://github.com/imclerran/roc-isodate/releases/download/v0.5.0/ptg0ElRLlIqsxMDZTTvQHgUSkNrUSymQaGwTfv0UEmk.tar.br",
}

import rr.RocRay exposing [Vector2, Rectangle, Color, Camera]
import rr.Keys
import rr.Draw
import rr.Camera
import rand.Random

screenWidth = 800
screenHeight = 450

Model : {
    player : { x : F32, y : F32 },
    buildings : List { rect : Rectangle, color : Color },
    cameraSettings : {
        target : Vector2,
        offset : Vector2,
        rotation : F32,
        zoom : F32,
    },
    camera : Camera,
}

init! : {} => Result Model []
init! = \{} ->

    RocRay.setTargetFPS! 60
    RocRay.displayFPS! { fps: Visible, pos: { x: 10, y: 10 } }

    RocRay.initWindow! { title: "2D Camera Example", width: screenWidth, height: screenHeight }

    player = { x: 400, y: 280 }

    cameraSettings = {
        target: player,
        offset: { x: screenWidth / 2, y: screenHeight / 2 },
        rotation: 0,
        zoom: 1,
    }

    camera = Camera.create! cameraSettings

    buildings = generateBuildings

    Ok {
        player,
        buildings,
        camera,
        cameraSettings,
    }

render! : Model, RocRay.PlatformState => Result Model []
render! = \model, { mouse, keys } ->

    # UPDATE CAMERA
    rotation =
        (
            if Keys.down keys KeyA then
                model.cameraSettings.rotation - 1
            else if Keys.down keys KeyS then
                model.cameraSettings.rotation + 1
            else
                model.cameraSettings.rotation
        )
        |> limit { upper: 40, lower: -40 }
        |> \r -> if Keys.pressed keys KeyR then 0 else r

    zoom =
        (model.cameraSettings.zoom + (mouse.wheel * 0.05))
        |> limit { upper: 3, lower: 0.1 }
        |> \z -> if Keys.pressed keys KeyR then 1 else z

    cameraSettings =
        model.cameraSettings
        |> &target model.player
        |> &rotation rotation
        |> &zoom zoom

    Camera.update! model.camera cameraSettings

    # UPDATE PLAYER
    player =
        if Keys.down keys KeyLeft then
            { x: model.player.x - 10, y: model.player.y }
        else if Keys.down keys KeyRight then
            { x: model.player.x + 10, y: model.player.y }
        else
            model.player

    # RENDER FRAMEBUFFER
    Draw.draw! White \{} ->

        # RENDER WORLD
        Draw.withMode2D! model.camera \{} ->
            drawWorld! model

        # RENDER SCREEN UI
        drawScreenUI! {}

    Ok { model & cameraSettings, player }

drawWorld! : Model => {}
drawWorld! = \model ->

    # BACKGROUND
    Draw.rectangle! { rect: { x: -6000, y: 320, width: 13000, height: 8000 }, color: Gray }

    # BUILDINGS
    forEach! model.buildings Draw.rectangle!

    # PLAYER
    playerWidth = 40
    playerHeight = 80

    Draw.rectangle! {
        rect: {
            x: model.player.x - (playerWidth / 2),
            y: model.player.y - (playerHeight / 2),
            width: playerWidth,
            height: playerHeight,
        },
        color: Red,
    }

    # PLAYER CROSSHAIR
    Draw.line! { start: { x: model.player.x, y: -screenHeight * 10 }, end: { x: model.player.x, y: screenHeight * 10 }, color: Yellow }
    Draw.line! { start: { x: -screenWidth * 10, y: model.player.y }, end: { x: screenWidth * 10, y: model.player.y }, color: Yellow }

drawScreenUI! : {} => {}
drawScreenUI! = \{} ->

    Draw.text! { pos: { x: 640, y: 10 }, text: "SCREEN AREA", size: 20, color: Red }

    Draw.rectangle! { rect: { x: 0, y: 0, width: screenWidth, height: 5 }, color: Red }
    Draw.rectangle! { rect: { x: 0, y: 5, width: 5, height: screenHeight - 10 }, color: Red }
    Draw.rectangle! { rect: { x: screenWidth - 5, y: 5, width: 5, height: screenHeight - 10 }, color: Red }
    Draw.rectangle! { rect: { x: 0, y: screenHeight - 5, width: screenWidth, height: 5 }, color: Red }

    Draw.rectangle! { rect: { x: 10, y: 20, width: 250, height: 113 }, color: RGBA 116 255 255 128 }

    Draw.text! { pos: { x: 20, y: 30 }, text: "Free 2d camera controls:", size: 10, color: Black }
    Draw.text! { pos: { x: 40, y: 50 }, text: "- Right/Left to move Offset", size: 10, color: Black }
    Draw.text! { pos: { x: 40, y: 70 }, text: "- Mouse Wheel to Zoom in-out", size: 10, color: Black }
    Draw.text! { pos: { x: 40, y: 90 }, text: "- A / S to Rotate", size: 10, color: Black }
    Draw.text! { pos: { x: 40, y: 110 }, text: "- R to reset Zoom and Rotation", size: 10, color: Black }

generateBuildings : List { rect : Rectangle, color : Color }
generateBuildings =
    List.range { start: At 0, end: Before 100 }
    |> List.walk { seed: Random.seed 1234, rects: [], nextX: -6000 } \state, _ ->

        bldgGen = Random.step state.seed randomBuilding

        bldg = bldgGen.value

        rect = {
            x: state.nextX,
            y: screenHeight - 130 - bldg.rect.height,
            width: bldg.rect.width,
            height: bldg.rect.height,
        }

        rects = List.append state.rects { bldg & rect }

        { seed: bldgGen.state, rects, nextX: state.nextX + bldg.rect.width }
    |> .rects

randomBuilding : Random.Generator { rect : Rectangle, color : Color }
randomBuilding =
    { Random.chain <-
        rect: { Random.chain <-
            x: Random.static 0,
            y: Random.static 0,
            width: Random.boundedU16 50 200 |> Random.map Num.toF32,
            height: Random.boundedU16 100 800 |> Random.map Num.toF32,
        }
        |> Random.map \a -> a,
        color: { Random.chain <-
            red: Random.boundedU8 200 240,
            green: Random.boundedU8 200 240,
            blue: Random.boundedU8 200 250,
        }
        |> Random.map \{ red, green, blue } -> RGBA red green blue 255,
    }

limit : F32, { upper : F32, lower : F32 } -> F32
limit = \value, { upper, lower } ->
    if value > upper then
        upper
    else if value < lower then
        lower
    else
        value

# TODO REPLACE WITH BUILTIN
forEach! : List a, (a => {}) => {}
forEach! = \l, f! ->
    when l is
        [] -> {}
        [x, .. as xs] ->
            f! x
            forEach! xs f!
