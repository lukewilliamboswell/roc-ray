app [main, Model] {
    rr: platform "../platform/main.roc",
    rand: "https://github.com/lukewilliamboswell/roc-random/releases/download/0.3.0/hPlOciYUhWMU7BefqNzL89g84-30fTE6l2_6Y3cxIcE.tar.br",
    time: "https://github.com/imclerran/roc-isodate/releases/download/v0.5.0/ptg0ElRLlIqsxMDZTTvQHgUSkNrUSymQaGwTfv0UEmk.tar.br",
}

import rr.RocRay exposing [PlatformState, Vector2, Rectangle, Color, Camera]
import rr.Keys
import rand.Random

main : RocRay.Program Model []
main = { init!, render! }

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
    RocRay.setDrawFPS! { fps: Visible }
    RocRay.setWindowSize! { width: screenWidth, height: screenHeight }
    RocRay.setWindowTitle! "2D Camera Example"

    player = { x: 400, y: 280 }

    cameraSettings = {
        target: player,
        offset: { x: screenWidth / 2, y: screenHeight / 2 },
        rotation: 0,
        zoom: 1,
    }

    camera = RocRay.createCamera! cameraSettings

    buildings = generateBuildings

    Ok {
        player,
        buildings,
        camera,
        cameraSettings,
    }

render! : Model, PlatformState => Result Model []
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

    RocRay.updateCamera! model.camera cameraSettings

    # UPDATE PLAYER
    player =
        if Keys.down keys KeyLeft then
            { x: model.player.x - 10, y: model.player.y }
        else if Keys.down keys KeyRight then
            { x: model.player.x + 10, y: model.player.y }
        else
            model.player

    # RENDER FRAMEBUFFER
    RocRay.beginDrawing! White

    # RENDER WORLD
    RocRay.beginMode2D! model.camera
    (drawWorld model) {}
    RocRay.endMode2D! model.camera

    # RENDER SCREEN UI
    drawScreenUI! {}

    RocRay.endDrawing! {}

    Ok { model & cameraSettings, player }

drawWorld : Model -> ({} => {})
drawWorld = \model -> \{} ->

    # BACKGROUND
    RocRay.drawRectangle! { rect: { x: -6000, y: 320, width: 13000, height: 8000 }, color: Gray }

    # BUILDINGS
    (forEach! model.buildings RocRay.drawRectangle!) {}

    # PLAYER
    playerWidth = 40
    playerHeight = 80

    RocRay.drawRectangle! {
        rect: {
            x: model.player.x - (playerWidth / 2),
            y: model.player.y - (playerHeight / 2),
            width: playerWidth,
            height: playerHeight,
        },
        color: Red,
    }

    # PLAYER CROSSHAIR
    RocRay.drawLine! { start: { x: model.player.x, y: -screenHeight * 10 }, end: { x: model.player.x, y: screenHeight * 10 }, color: Yellow }
    RocRay.drawLine! { start: { x: -screenWidth * 10, y: model.player.y }, end: { x: screenWidth * 10, y: model.player.y }, color: Yellow }

drawScreenUI! : {} => {}
drawScreenUI! = \{} ->

    RocRay.drawText! { pos: { x: 640, y: 10 }, text: "SCREEN AREA", size: 20, color: Red }

    RocRay.drawRectangle! { rect: { x: 0, y: 0, width: screenWidth, height: 5 }, color: Red }
    RocRay.drawRectangle! { rect: { x: 0, y: 5, width: 5, height: screenHeight - 10 }, color: Red }
    RocRay.drawRectangle! { rect: { x: screenWidth - 5, y: 5, width: 5, height: screenHeight - 10 }, color: Red }
    RocRay.drawRectangle! { rect: { x: 0, y: screenHeight - 5, width: screenWidth, height: 5 }, color: Red }

    RocRay.drawRectangle! { rect: { x: 10, y: 20, width: 250, height: 113 }, color: RGBA 116 255 255 128 }

    RocRay.drawText! { pos: { x: 20, y: 30 }, text: "Free 2d camera controls:", size: 10, color: Black }
    RocRay.drawText! { pos: { x: 40, y: 50 }, text: "- Right/Left to move Offset", size: 10, color: Black }
    RocRay.drawText! { pos: { x: 40, y: 70 }, text: "- Mouse Wheel to Zoom in-out", size: 10, color: Black }
    RocRay.drawText! { pos: { x: 40, y: 90 }, text: "- A / S to Rotate", size: 10, color: Black }
    RocRay.drawText! { pos: { x: 40, y: 110 }, text: "- R to reset Zoom and Rotation", size: 10, color: Black }

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

# not sure this is ok, but just trying to replace Task.forEach
forEach! : List a, (a => {}) => ({} => {})
forEach! = \things, do -> \{} ->
    when things is
        [] -> {}
        [first, .. as rest] ->
            do first
            (forEach! rest do) {}
