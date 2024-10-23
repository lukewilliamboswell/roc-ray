app [Model, init, render] {
    rr: platform "../platform/main.roc",
}

import rr.RocRay exposing [Rectangle]
import rr.Draw
import rr.Camera
import rr.RenderTexture

screenWidth = 800
screenHeight = 440
playerSize = 40

Model : {
    playerOne : Rectangle,
    playerTwo : Rectangle,
    settingsLeft : Camera.Settings,
    settingsRight : Camera.Settings,
    cameraLeft : RocRay.Camera,
    cameraRight : RocRay.Camera,
    screenLeft : RocRay.RenderTexture,
    screenRight : RocRay.RenderTexture,
}

init : Task Model []
init =

    RocRay.setTargetFPS! 60
    RocRay.setDrawFPS! { fps: Visible }
    RocRay.setWindowSize! { width: screenWidth, height: screenHeight }
    RocRay.setWindowTitle! "2D camera split-screen"

    playerOne = { x : 200, y : 200, width : playerSize, height : playerSize }
    playerTwo = { x : 250, y : 200, width : playerSize, height : playerSize }

    settingsLeft = {
        target: {x:playerOne.x, y:playerOne.y},
        offset: { x: 200, y: 200 },
        rotation: 0,
        zoom: 1,
    }

    settingsRight = {
        target: {x:playerTwo.x, y:playerTwo.y},
        offset: { x: 200, y: 200 },
        rotation: 0,
        zoom: 1,
    }

    cameraLeft = Camera.create! settingsLeft
    cameraRight = Camera.create! settingsRight

    screenLeft = RenderTexture.create! { width: screenWidth / 2, height: screenHeight / 2}
    screenRight = RenderTexture.create! { width: screenWidth / 2, height: screenHeight / 2}

    Task.ok {
        playerOne,
        playerTwo,
        settingsLeft,
        settingsRight,
        cameraLeft,
        cameraRight,
        screenLeft,
        screenRight,
    }

render : Model, RocRay.PlatformState -> Task Model []
render = \model, {  } ->

    # RENDER THE SCENE INTO THE LEFT SCREEN TEXTURE
    Draw.withTexture! model.screenLeft Aqua \{} ->

        Draw.withMode2D! model.cameraLeft \{} ->

            Draw.rectangle! { rect: model.playerOne, color: Red }
            Draw.rectangle! { rect: { x : -1000, y : -1000, width : screenWidth*100, height: screenHeight*100 }, color: Blue}

            drawScene!

    # RENDER FRAMEBUFFER
    Draw.draw! White \{} ->

        # DRAW THE LEFT SCREEN TEXTURE INTO THE FRAMEBUFFER
        Draw.renderTextureRec! {
            texture : model.screenLeft,
            source : { x : 50, y : 50, width : screenWidth / 2, height: screenHeight / 2 },
            pos : { x: 100, y: 100},
            tint : White,
        }

    Task.ok model

drawScene : Task {} []
drawScene =

    List.range { start: At 0, end: Before ((screenWidth/playerSize) + 1)}
    |> List.map \i -> { start: { x: playerSize*i, y: 0 }, end: { x: playerSize*i, y: screenHeight }, color: lightGray }
    |> Task.forEach! Draw.line

lightGray = RGBA 200 200 200 255
