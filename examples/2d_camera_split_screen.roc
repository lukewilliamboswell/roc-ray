app [Model, init, render] {
    rr: platform "../platform/main.roc",
    rand: "https://github.com/lukewilliamboswell/roc-random/releases/download/0.3.0/hPlOciYUhWMU7BefqNzL89g84-30fTE6l2_6Y3cxIcE.tar.br",
    time: "https://github.com/imclerran/roc-isodate/releases/download/v0.5.0/ptg0ElRLlIqsxMDZTTvQHgUSkNrUSymQaGwTfv0UEmk.tar.br",
}

import rr.RocRay exposing [Rectangle]
#import rr.Keys
import rr.Draw
import rr.Camera
import rr.RenderTexture
#import rand.Random

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

    # WHAT IS THIS?
    #splitScreenRect = { x: 0, y: 0, width: screenWidth / 2, height: screenHeight }

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

    ## UPDATE CAMERA
    #rotation =
    #    (
    #        if Keys.down keys KeyA then
    #            model.cameraSettings.rotation - 1
    #        else if Keys.down keys KeyS then
    #            model.cameraSettings.rotation + 1
    #        else
    #            model.cameraSettings.rotation
    #    )
    #    |> limit { upper: 40, lower: -40 }
    #    |> \r -> if Keys.pressed keys KeyR then 0 else r

    #zoom =
    #    (model.cameraSettings.zoom + (mouse.wheel * 0.05))
    #    |> limit { upper: 3, lower: 0.1 }
    #    |> \z -> if Keys.pressed keys KeyR then 1 else z

    #cameraSettings =
    #    model.cameraSettings
    #    |> &target model.player
    #    |> &rotation rotation
    #    |> &zoom zoom

    #Camera.update! model.camera cameraSettings

    ## UPDATE PLAYER
    #player =
    #    if Keys.down keys KeyLeft then
    #        { x: model.player.x - 10, y: model.player.y }
    #    else if Keys.down keys KeyRight then
    #        { x: model.player.x + 10, y: model.player.y }
    #    else
    #        model.player
    #

    # RENDER THE SCENE INTO THE LEFT SCREEN TEXTURE
    Draw.withTexture! model.screenLeft Aqua \{} ->

        Draw.withMode2D! model.cameraLeft \{} ->

            Draw.rectangle! { rect: model.playerOne, color: Red }

            drawScene!

    # RENDER FRAMEBUFFER
    Draw.draw! White \{} ->

        # DRAW THE LEFT SCREEN TEXTURE INTO THE FRAMEBUFFER
        Draw.renderTextureRec! {
            texture : model.screenLeft,
            source : { x : 0, y : 0, width : screenWidth / 2, height: screenHeight / 2 },
            pos : { x: 0, y: 0},
            tint : White,
        }

    Task.ok model

drawScene : Task {} []
drawScene =

    List.range { start: At 0, end: Before ((screenWidth/playerSize) + 1)}
    |> List.map \i -> { start: { x: playerSize*i, y: 0 }, end: { x: playerSize*i, y: screenHeight }, color: lightGray }
    |> Task.forEach! Draw.line

lightGray = RGBA 200 200 200 255
