app [Model, init, render] { rr: platform "../platform/main.roc" }

import rr.RocRay exposing [Texture, Rectangle]
import rr.Keys
import rr.Draw
import rr.Texture
import rr.Network

width = 800
height = 600

Model : {
    player : { x : F32, y : F32 },
    direction : [WalkUp, WalkDown, WalkLeft, WalkRight],
    dude : Texture,
    dudeAnimation : AnimatedSprite,
}

init : Task Model []
init =

    RocRay.setTargetFPS! 60
    RocRay.initWindow! { title: "Animated Sprite Example" }

    dude = Texture.load! "examples/assets/sprite-dude/sheet.png"

    Task.ok {
        player: { x: width / 2, y: height / 2 },
        direction: WalkRight,
        dude,
        dudeAnimation: {
            frame: 0,
            frameRate: 10,
            nextAnimationTick: 0,
        },
    }

render : Model, RocRay.PlatformState -> Task Model []
render = \model, { timestampMillis, keys, network } ->



    (player, direction) =
        if Keys.down keys KeyUp then
            ({ x: model.player.x, y: model.player.y - 10 }, WalkUp)
        else if Keys.down keys KeyDown then
            ({ x: model.player.x, y: model.player.y + 10 }, WalkDown)
        else if Keys.down keys KeyLeft then
            ({ x: model.player.x - 10, y: model.player.y }, WalkLeft)
        else if Keys.down keys KeyRight then
            ({ x: model.player.x + 10, y: model.player.y }, WalkRight)
        else
            (model.player, model.direction)

    dudeAnimation = updateAnimation model.dudeAnimation timestampMillis

    Draw.draw! White \{} ->

        Draw.text! { pos: { x: 10, y: 10 }, text: "Rocci the Cool Dude", size: 40, color: Navy }
        Draw.text! { pos: { x: 10, y: 50 }, text: "Use arrow keys to walk around", size: 20, color: Green }

        Draw.textureRec! {
            texture: model.dude,
            source: dudeSprite model.direction dudeAnimation.frame,
            pos: model.player,
            tint: White,
        }

        displayPeerConnections! network.peers
        displayMessages! network.messages

    Task.ok { model & player, dudeAnimation, direction }

dudeSprite : [WalkUp, WalkDown, WalkLeft, WalkRight], U8 -> Rectangle
dudeSprite = \sequence, frame ->
    when sequence is
        WalkUp -> sprite64x64source { row: 8, col: frame % 9 }
        WalkDown -> sprite64x64source { row: 10, col: frame % 9 }
        WalkLeft -> sprite64x64source { row: 9, col: frame % 9 }
        WalkRight -> sprite64x64source { row: 11, col: frame % 9 }

AnimatedSprite : {
    frame : U8, # frame index, increments each tick
    frameRate : U8, # frames per second
    nextAnimationTick : U64, # milliseconds
}

updateAnimation : AnimatedSprite, U64 -> AnimatedSprite
updateAnimation = \{ frame, frameRate, nextAnimationTick }, timestampMillis ->

    if timestampMillis > nextAnimationTick then
        {
            frame: Num.addWrap frame 1,
            frameRate,
            nextAnimationTick: timestampMillis + (Num.toU64 (Num.round (1000 / (Num.toF64 frameRate)))),
        }
    else
        { frame, frameRate, nextAnimationTick }

# get the pixel coordinates of a 64x64 sprite in the spritesheet
sprite64x64source : { row : U8, col : U8 } -> Rectangle
sprite64x64source = \{ row, col } -> {
    x: 64 * (Num.toF32 col),
    y: 64 * (Num.toF32 row),
    width: 64,
    height: 64,
}

displayPeerConnections : {
    connected : List Network.UUID,
    disconnected : List Network.UUID,
} -> Task {} _
displayPeerConnections = \{ connected, disconnected } ->

    combined =
        List.concat
            (connected |> List.map \uuid -> "CONNECTED: $(Network.toStr uuid)")
            (disconnected |> List.map \uuid -> "DISCONNECTED: $(Network.toStr uuid)")
        |> List.append "NETWORK PEERS $(Num.toStr (List.len connected)) connected, $(Num.toStr (List.len disconnected)) disconnected"

    List.range { start: At 0, end: Before (List.len combined)}
    |> List.map \i -> {
        pos: { x: 10, y: Num.toFrac (height - 10 - (i*10)) },
        text: List.get combined i |> Result.withDefault "OUT OF BOUNDS",
        size: 10,
        color: Black,
    }
    |> Task.forEach Draw.text

displayMessages : List {
    id: Network.UUID,
    bytes: List U8,
} -> Task {} _
displayMessages = \messages ->

    total = List.len messages

    totalMsg = "MESSAGES TOTAL $(Num.toStr total)"

    totalWidth = RocRay.measureText {text: totalMsg, size: 10} |> Task.map! Num.toFrac

    Draw.text! {
        pos: { x: (width - 10 - totalWidth), y: Num.toFrac (height - 10 - (total*10)) },
        text: totalMsg,
        size: 10,
        color: Black,
    }

    messages
    |> List.mapWithIndex \msg, i -> {
        pos: { x: width  - 10, y: Num.toFrac (height - 10 - (i*10)) },
        text: "FROM $(Inspect.toStr msg.id), $(msg.bytes |> List.len |> Num.toStr) BYTES",
        size: 10,
        color: Black,
    }
    |> Task.forEach Draw.text
