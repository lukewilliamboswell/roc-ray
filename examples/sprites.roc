app [Model, init, render] {
    rr: platform "../platform/main.roc",
    json: "https://github.com/lukewilliamboswell/roc-json/releases/download/0.10.2/FH4N0Sw-JSFXJfG3j54VEDPtXOoN-6I9v_IA8S18IGk.tar.br",

}

import rr.RocRay exposing [Texture, Rectangle, Vector2]
import rr.Draw
import rr.Texture
import rr.Network exposing [UUID]
import json.Json

import World exposing [World]

width = 400
height = 400

Model : {
    dude : Texture,
    world : World,
    timestampMillis : [FirstFrame, Timestamp U64],
}

init : Task Model []
init =
    RocRay.setTargetFPS! 120
    RocRay.initWindow! { title: "Animated Sprite Example", width, height }

    dude = Texture.load! "examples/assets/sprite-dude/sheet.png"

    player = { x: width / 2, y: height / 2 }

    localPlayer = {
        pos: player,
        intent: Idle Right,
        animation: {
            frame: 0,
            frameRate: 10,
            nextAnimationTick: 0,
        },
    }
    world = World.new { localPlayer }

    Task.ok { dude, world, timestampMillis: FirstFrame }

render : Model, RocRay.PlatformState -> Task Model []
render = \model, state ->
    { timestampMillis, network } = state

    deltaMillis =
        when model.timestampMillis is
            FirstFrame -> 0
            Timestamp previous -> timestampMillis - previous
    deltaTime = Num.toF32 deltaMillis

    # NOTE assuming only one opponent for now
    # should we log decode errors? what does it mean? out of date client?
    inbox : List World.PeerUpdate
    inbox = List.keepOks network.messages \{ id, bytes } ->
        decodeResult : Result { x : I64, y : I64 } _
        decodeResult = Decode.fromBytes bytes Json.utf8
        Result.map decodeResult \{ x, y } -> { id, x: Num.toF32 x, y: Num.toF32 y }

    world = World.frameTicks model.world { platformState: state, deltaTime, inbox }

    # SEND NEW PLAYER POSITION TO NETWORK
    sendPlayerPosition! world.localPlayer.pos network.peers.connected

    Draw.draw! White \{} ->

        Draw.text! { pos: { x: 10, y: 10 }, text: "Rocci the Cool Dude", size: 40, color: Navy }
        Draw.text! { pos: { x: 10, y: 50 }, text: "Use arrow keys to walk around", size: 20, color: Green }

        playerFacing = World.playerFacing world.localPlayer
        Draw.textureRec! {
            texture: model.dude,
            source: dudeSprite playerFacing world.localPlayer.animation.frame,
            pos: model.world.localPlayer.pos,
            tint: White,
        }

        displayPeerConnections! network.peers
        displayMessages! network.messages

        drawOtherPlayers! (World.opponentPositions world)

    Task.ok { model & world, timestampMillis: Timestamp timestampMillis }

dudeSprite : World.Facing, U8 -> Rectangle
dudeSprite = \sequence, frame ->
    when sequence is
        Up -> sprite64x64source { row: 8, col: frame % 9 }
        Down -> sprite64x64source { row: 10, col: frame % 9 }
        Left -> sprite64x64source { row: 9, col: frame % 9 }
        Right -> sprite64x64source { row: 11, col: frame % 9 }

# get the pixel coordinates of a 64x64 sprite in the spritesheet
sprite64x64source : { row : U8, col : U8 } -> Rectangle
sprite64x64source = \{ row, col } -> {
    x: 64 * (Num.toF32 col),
    y: 64 * (Num.toF32 row),
    width: 64,
    height: 64,
}

displayPeerConnections :
    {
        connected : List UUID,
        disconnected : List UUID,
    }
    -> Task {} _
displayPeerConnections = \{ connected, disconnected } ->

    combined =
        List.concat
            (connected |> List.map \uuid -> "CONNECTED: $(Network.toStr uuid)")
            (disconnected |> List.map \uuid -> "DISCONNECTED: $(Network.toStr uuid)")
        |> List.append "NETWORK PEERS $(Num.toStr (List.len connected)) connected, $(Num.toStr (List.len disconnected)) disconnected"

    List.range { start: At 0, end: Before (List.len combined) }
    |> List.map \i -> {
        pos: { x: 10, y: height - 10 - (Num.toFrac (i * 10)) },
        text: List.get combined i |> Result.withDefault "OUT OF BOUNDS",
        size: 10,
        color: Black,
    }
    |> Task.forEach Draw.text

displayMessages : List {
        id : UUID,
        bytes : List U8,
    }
    -> Task {} _
displayMessages = \messages ->

    total = List.len messages

    totalMsg = "MESSAGES TOTAL $(Num.toStr total)"

    totalWidth = RocRay.measureText { text: totalMsg, size: 10 } |> Task.map! Num.toFrac

    Draw.text! {
        pos: { x: (width - 10 - totalWidth), y: height - 10 - (Num.toFrac (total * 10)) },
        text: totalMsg,
        size: 10,
        color: Black,
    }

    messages
    |> List.mapWithIndex \msg, i -> {
        pos: { x: width - 10, y: height - 10 - (Num.toFrac (i * 10)) },
        text: "FROM $(Inspect.toStr msg.id), $(msg.bytes |> List.len |> Num.toStr) BYTES",
        size: 10,
        color: Black,
    }
    |> Task.forEach Draw.text

sendPlayerPosition : Vector2, List UUID -> Task {} _
sendPlayerPosition = \player, peers ->

    bytes = Encode.toBytes player Json.utf8

    Task.forEach peers \peer ->
        RocRay.sendToPeer bytes peer

drawOtherPlayers : List World.RemotePlayer -> Task {} _
drawOtherPlayers = \others ->
    others
        |> Task.forEach \{ id, pos } ->
            Draw.text! { pos, text: "$(Inspect.toStr id)", size: 10, color: Red }
            Draw.rectangle! { rect: { x: pos.x - 5, y: pos.y + 15, width: 20, height: 40 }, color: Red }
