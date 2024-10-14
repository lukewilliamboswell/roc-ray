app [main, Model] {
    ray: platform "../platform/main.roc",
    rand: "https://github.com/lukewilliamboswell/roc-random/releases/download/0.3.0/hPlOciYUhWMU7BefqNzL89g84-30fTE6l2_6Y3cxIcE.tar.br",
    time: "https://github.com/imclerran/roc-isodate/releases/download/v0.5.0/ptg0ElRLlIqsxMDZTTvQHgUSkNrUSymQaGwTfv0UEmk.tar.br",
}

import ray.Raylib exposing [PlatformState, Vector2, Color, Camera]
import rand.Random

main = { init, render }

screenWidth = 800f32
screenHeight = 800f32

Model : {
    buildings : List { x : F32, y : F32, width : F32, height : F32, color : Color },
    cameraSettings : {
        target : Vector2,
        offset : Vector2,
        rotation : F32,
        zoom : F32,
    },
    cameraID : Camera,
}

init : Task Model []
init =

    Raylib.setDrawFPS! { fps: Visible }
    Raylib.setWindowSize! { width: screenWidth, height: screenHeight }
    Raylib.setWindowTitle! "2D Camera Example"

    cameraSettings = {
        target: { x: 20, y: 20 },
        offset: { x: screenWidth / 2, y: screenHeight / 2 },
        rotation: 0,
        zoom: 1,
    }

    cameraID = Raylib.createCamera! cameraSettings

    buildings = generateBuildings

    Task.ok { buildings, cameraID, cameraSettings }

render : Model, PlatformState -> Task Model []
render = \model, { mousePos } ->

    Raylib.drawMode2D! model.cameraID (Task.forEach model.buildings Raylib.drawRectangle)

    cameraSettings = model.cameraSettings |> &target mousePos

    Raylib.updateCamera! model.cameraID cameraSettings

    Task.ok { model & cameraSettings }

generateBuildings : List { x : F32, y : F32, width : F32, height : F32, color : Color }
generateBuildings =
    List.range { start: At 0, end: Before 100 }
    |> List.walk { seed: Random.seed 1234u32, rects: [], nextX: -6000f32 } \state, _ ->

        bldgGen = Random.step state.seed randomBuilding

        bldg = bldgGen.value

        rects = List.append state.rects { bldg & x: state.nextX }

        { seed: bldgGen.state, rects, nextX: state.nextX + bldg.width }
    |> .rects

randomBuilding : Random.Generator { x : F32, y : F32, width : F32, height : F32, color : Color }
randomBuilding =

    updateY = \values -> { values & y: screenHeight - 130f32 - values.height }

    { Random.chain <-
        x: Random.static 0f32,
        y: Random.static 0f32,
        width: Random.boundedU16 50 200 |> Random.map Num.toF32,
        height: Random.boundedU16 100 800 |> Random.map Num.toF32,
        color: { Random.chain <-
            red: Random.boundedU8 200 240,
            green: Random.boundedU8 200 240,
            blue: Random.boundedU8 200 250,
        }
        |> Random.map \{ red, green, blue } -> RGBA red green blue 255,
    }
    |> Random.map updateY
