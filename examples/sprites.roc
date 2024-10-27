app [Model, init, render] {
    rr: platform "../platform/main.roc",
    json: "https://github.com/lukewilliamboswell/roc-json/releases/download/0.10.2/FH4N0Sw-JSFXJfG3j54VEDPtXOoN-6I9v_IA8S18IGk.tar.br",

}

import rr.RocRay exposing [Texture, Rectangle, Vector2]
import rr.Keys
import rr.Draw
import rr.Texture
import rr.Network exposing [UUID]
import json.Json

width = 400
height = 400

Model : {
    player : { x : F32, y : F32 },
    direction : [WalkUp, WalkDown, WalkLeft, WalkRight],
    dude : Texture,
    dudeAnimation : AnimatedSprite,
    others : Dict UUID { x : F32, y : F32 },
}

updateOtherPlayers : Model, List { id : UUID, bytes : List U8 } -> Dict UUID { x : F32, y : F32 }
updateOtherPlayers = \{ others }, messages ->
    List.walk messages others \state, { id, bytes } ->

        pos : Result { x : I64, y : I64 } _
        pos = Decode.fromBytes bytes Json.utf8

        when pos is
            Ok { x, y } -> Dict.insert state id { x: Num.toF32 x, y: Num.toF32 y }
            Err _ -> Dict.insert state id { x: 50, y: 50 }

init : Task Model []
init =

    RocRay.setTargetFPS! 120
    RocRay.initWindow! { title: "Animated Sprite Example", width, height }

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
        others: Dict.empty {},
    }

render : Model, RocRay.PlatformState -> Task Model []
render = \model, { timestampMillis, keys, network } ->

    # SEND PLAYER POSITION TO NETWORK
    sendPlayerPosition! model.player network.peers.connected

    others = updateOtherPlayers model network.messages

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

        # RENDER OTHER PLAYERS
        drawOtherPlayers! others

    Task.ok { model & player, dudeAnimation, direction, others }

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

drawOtherPlayers : Dict UUID Vector2 -> Task {} _
drawOtherPlayers = \others ->

    Dict.toList others
        |> Task.forEach \(id, player) ->
            Draw.text! { pos: player, text: "$(Inspect.toStr id)", size: 10, color: Red }
            Draw.rectangle! { rect: { x: player.x - 5, y: player.y + 15, width: 20, height: 40 }, color: Red }
