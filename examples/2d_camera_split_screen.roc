app [Model, init!, render!] {
    rr: platform "../platform/main.roc",
}

import rr.RocRay exposing [Rectangle]
import rr.Draw
import rr.Camera
import rr.RenderTexture
import rr.Keys

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

init! : {} => Result Model _
init! = \{} ->

    RocRay.initWindow! {
        title: "2D camera split-screen",
        width: screenWidth,
        height: screenHeight,
    }

    playerOne = { x: 200, y: 200, width: playerSize, height: playerSize }
    playerTwo = { x: 250, y: 200, width: playerSize, height: playerSize }

    settingsLeft = {
        target: { x: playerOne.x, y: playerOne.y },
        offset: { x: 200, y: 200 },
        rotation: 0,
        zoom: 1,
    }

    settingsRight = {
        target: { x: playerTwo.x, y: playerTwo.y },
        offset: { x: 200, y: 200 },
        rotation: 0,
        zoom: 1,
    }

    # TODO replace with something more normal once we have `try` available
    when (Camera.create! settingsLeft, Camera.create! settingsRight, RenderTexture.create! { width: screenWidth / 2, height: screenHeight }, RenderTexture.create! { width: screenWidth / 2, height: screenHeight }) is
        (Ok cameraLeft, Ok cameraRight, Ok screenLeft, Ok screenRight) ->
            Ok {
                playerOne,
                playerTwo,
                settingsLeft,
                settingsRight,
                cameraLeft,
                cameraRight,
                screenLeft,
                screenRight,
            }

        _ -> crash "Failed to create camera or render texture."

render! : Model, RocRay.PlatformState => Result Model []
render! = \model, { keys } ->

    # RENDER THE SCENE INTO THE LEFT SCREEN TEXTURE
    Draw.withTexture! model.screenLeft White \{} ->

        Draw.withMode2D! model.cameraLeft \{} ->

            drawGrid! {}

            Draw.rectangle! { rect: model.playerOne, color: Red }
            Draw.rectangle! { rect: model.playerTwo, color: Blue }

            Draw.text! { pos: { x: 10, y: 10 }, text: "PLAYER1: W/S/A/D to move", size: 10, color: Red }

    # RENDER THE SCENE INTO THE RIGHT SCREEN TEXTURE
    Draw.withTexture! model.screenRight White \{} ->

        Draw.withMode2D! model.cameraRight \{} ->

            drawGrid! {}

            Draw.rectangle! { rect: model.playerOne, color: Red }
            Draw.rectangle! { rect: model.playerTwo, color: Blue }

            Draw.text! { pos: { x: 10, y: 10 }, text: "PLAYER2: UP/DOWN/LEFT/RIGHT to move", size: 10, color: Blue }

    # RENDER FRAMEBUFFER
    Draw.draw! White \{} ->

        # DRAW THE LEFT SCREEN TEXTURE INTO THE FRAMEBUFFER
        Draw.renderTextureRec! {
            texture: model.screenLeft,
            source: { x: 0, y: 0, width: screenWidth / 2, height: -screenHeight },
            pos: { x: 0, y: 0 },
            tint: White,
        }

        # DRAW THE RIGHT SCREEN TEXTURE INTO THE FRAMEBUFFER
        Draw.renderTextureRec! {
            texture: model.screenRight,
            source: { x: 0, y: 0, width: screenWidth / 2, height: -screenHeight },
            pos: { x: screenWidth / 2, y: 0 },
            tint: White,
        }

        # DRAW THE SPLIT LINE
        Draw.rectangle! { rect: { x: (screenWidth / 2) - 2, y: 0, width: 4, height: screenHeight }, color: Black }

    playerOne =
        if Keys.down keys KeyUp then
            model.playerOne |> &y (model.playerOne.y - 10)
        else if Keys.down keys KeyDown then
            model.playerOne |> &y (model.playerOne.y + 10)
        else if Keys.down keys KeyLeft then
            model.playerOne |> &x (model.playerOne.x - 10)
        else if Keys.down keys KeyRight then
            model.playerOne |> &x (model.playerOne.x + 10)
        else
            model.playerOne

    playerTwo =
        if Keys.down keys KeyW then
            model.playerTwo |> &y (model.playerTwo.y - 10)
        else if Keys.down keys KeyS then
            model.playerTwo |> &y (model.playerTwo.y + 10)
        else if Keys.down keys KeyA then
            model.playerTwo |> &x (model.playerTwo.x - 10)
        else if Keys.down keys KeyD then
            model.playerTwo |> &x (model.playerTwo.x + 10)
        else
            model.playerTwo

    settingsLeft = model.settingsLeft |> &target { x: model.playerOne.x, y: model.playerOne.y }

    settingsRight = model.settingsLeft |> &target { x: model.playerTwo.x, y: model.playerTwo.y }

    Camera.update! model.cameraLeft settingsLeft
    Camera.update! model.cameraRight settingsRight

    Ok { model & playerOne, playerTwo, settingsLeft, settingsRight }

drawGrid! : {} => {}
drawGrid! = \{} ->

    # VERTICAL LINES
    List.range { start: At 0, end: At (screenWidth / playerSize) }
    |> List.map \i -> { start: { x: playerSize * i, y: 0 }, end: { x: playerSize * i, y: screenHeight }, color: lightGray }
    |> forEach! Draw.line!

    # HORIZONTAL LINES
    List.range { start: At 0, end: At (screenHeight / playerSize) }
    |> List.map \j -> { start: { x: 0, y: playerSize * j }, end: { x: screenWidth, y: playerSize * j }, color: lightGray }
    |> forEach! Draw.line!

    # GRID COORDINATES
    List.range { start: At 0, end: Before (screenWidth / playerSize) }
    |> List.map \i ->
        List.range { start: At 0, end: Before (screenHeight / playerSize) }
        |> List.map \j -> {
            pos: { x: 10 + (playerSize * i), y: 15 + (playerSize * j) },
            text: "[$(Num.toStr (Num.round i)),$(Num.toStr (Num.round j))]",
            size: 10,
            color: lightGray,
        }
    |> List.join
    |> forEach! Draw.text!

lightGray = RGBA 200 200 200 255

# TODO REPLACE WITH BUILTIN
forEach! : List a, (a => {}) => {}
forEach! = \l, f! ->
    when l is
        [] -> {}
        [x, .. as xs] ->
            f! x
            forEach! xs f!
