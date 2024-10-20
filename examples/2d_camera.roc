app [main, Model] {
    ray: platform "../platform/main.roc",
    rand: "https://github.com/lukewilliamboswell/roc-random/releases/download/0.3.0/hPlOciYUhWMU7BefqNzL89g84-30fTE6l2_6Y3cxIcE.tar.br",
    time: "https://github.com/imclerran/roc-isodate/releases/download/v0.5.0/ptg0ElRLlIqsxMDZTTvQHgUSkNrUSymQaGwTfv0UEmk.tar.br",
}

import ray.RocRay exposing [Vector2, Rectangle, Color, Camera]
import rand.Random

main = { init!, render! }

screenWidth = 800f32
screenHeight = 800f32

Model : {
    buildings : List { rect: Rectangle, color : Color },
    cameraSettings : {
        target : Vector2,
        offset : Vector2,
        rotation : F32,
        zoom : F32,
    },
    cameraID : Camera,
}

init! = \{} ->

    RocRay.setDrawFPS! { fps: Visible }
    RocRay.setWindowSize! { width: screenWidth, height: screenHeight }
    RocRay.setWindowTitle! "2D Camera Example"

    cameraSettings = {
        target: { x: 20, y: 20 },
        offset: { x: screenWidth / 2, y: screenHeight / 2 },
        rotation: 0,
        zoom: 1,
    }

    cameraID = RocRay.createCamera! cameraSettings

    buildings = generateBuildings

    Ok { buildings, cameraID, cameraSettings }

render! = \model, { mouse } ->

    RocRay.drawMode2D! model.cameraID (forEach! model.buildings RocRay.drawRectangle!)

    cameraSettings = model.cameraSettings |> &target mouse.position

    RocRay.updateCamera! model.cameraID cameraSettings

    Ok { model & cameraSettings }

# not sure this is ok, but just trying to replace Task.forEach
forEach! : List a, (a => {}) => ({} => {})
forEach! = \things, do -> \{} ->
    when things is
        [] -> {}
        [first, .. as rest] ->
            do first
            (forEach! rest do) {}

generateBuildings : List { rect: Rectangle, color : Color }
generateBuildings =
    List.range { start: At 0, end: Before 100 }
    |> List.walk { seed: Random.seed 1234u32, rects: [], nextX: -6000f32 } \state, _ ->

        bldgGen = Random.step state.seed randomBuilding

        bldg = bldgGen.value

        rect = {
            x: state.nextX,
            y: screenHeight - 130f32 - bldg.rect.height,
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
            x: Random.static 0f32,
            y: Random.static 0f32,
            width: Random.boundedU16 50 200 |> Random.map Num.toF32,
            height: Random.boundedU16 100 800 |> Random.map Num.toF32,
        } |> Random.map \a -> a,
        color: { Random.chain <-
            red: Random.boundedU8 200 240,
            green: Random.boundedU8 200 240,
            blue: Random.boundedU8 200 250,
        }
        |> Random.map \{ red, green, blue } -> RGBA red green blue 255,
    }
