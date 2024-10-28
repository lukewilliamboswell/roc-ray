app [Model, init!, render!] {
    rr: platform "../../platform/main.roc",
    json: "https://github.com/lukewilliamboswell/roc-json/releases/download/0.10.2/FH4N0Sw-JSFXJfG3j54VEDPtXOoN-6I9v_IA8S18IGk.tar.br",
}

import rr.RocRay exposing [Texture, Rectangle, Vector2, PlatformState]
import rr.Draw
import rr.Texture
import rr.Network exposing [UUID]

import json.Json

import World exposing [World]

width = 400
height = 400

Model : [Waiting WaitingModel, Connected ConnectedModel]

WaitingModel : {
    dude : Texture,
    localPlayer : World.LocalPlayer,
}

ConnectedModel : {
    dude : Texture,
    world : World,
    timestampMillis : U64,
}

init! : {} => Result Model []
init! = \{} ->
    RocRay.setTargetFPS! 120
    RocRay.initWindow! { title: "Animated Sprite Example", width, height }

    dude = Texture.load! "examples/assets/sprite-dude/sheet.png"

    pos = { x: width / 2, y: height / 2 }

    localPlayer : World.LocalPlayer
    localPlayer = {
        pos,
        intent: Idle Right,
        animation: {
            frame: 0,
            frameRate: 10,
            nextAnimationTick: 0,
        },
    }

    waiting : WaitingModel
    waiting = { dude, localPlayer }

    Ok (Waiting waiting)

render! : Model, RocRay.PlatformState => Result Model []
render! = \model, state ->
    when model is
        Waiting waiting -> renderWaiting! waiting state
        Connected connected -> renderConnected! connected state

drawConnected! : ConnectedModel, PlatformState => {}
drawConnected! = \{ dude, world }, state ->
    Draw.draw! White \{} ->
        Draw.text! { pos: { x: 10, y: 10 }, text: "Rocci the Cool Dude", size: 40, color: Navy }
        Draw.text! { pos: { x: 10, y: 50 }, text: "Use arrow keys to walk around", size: 20, color: Green }

        playerFacing = World.playerFacing world.localPlayer
        Draw.textureRec! {
            texture: dude,
            source: dudeSprite playerFacing world.localPlayer.animation.frame,
            pos: world.localPlayer.pos,
            tint: White,
        }

        displayPeerConnections! state.network.peers
        displayMessages! state.network.messages

        drawRemotePlayer! world.remotePlayer

renderWaiting! : WaitingModel, PlatformState => Result Model []
renderWaiting! = \waiting, state ->
    # SEND NEW PLAYER POSITION TO NETWORK
    sendPlayerPosition! waiting.localPlayer.pos state.network.peers.connected

    # NOTE silently drops decode error
    when List.last state.network.messages is
        Ok firstMessage ->
            when decodeSingleUpdate firstMessage is
                Ok firstUpdate ->
                    waitingToConnected! waiting state firstUpdate

                Err TooShort ->
                    stayWaiting! waiting

                Err (Leftover _) ->
                    stayWaiting! waiting

        Err ListWasEmpty ->
            stayWaiting! waiting

stayWaiting! : WaitingModel => Result Model []
stayWaiting! = \waiting ->
    drawWaiting! waiting
    Ok (Waiting waiting)

waitingToConnected! : WaitingModel, PlatformState, World.PeerUpdate => Result Model []
waitingToConnected! = \waiting, state, firstUpdate ->
    timestampMillis = state.timestamp.renderStart
    { dude, localPlayer } = waiting

    world = World.init { localPlayer, firstUpdate }

    connected : ConnectedModel
    connected = { dude, world, timestampMillis }

    drawConnected! connected state

    Ok (Connected connected)

drawWaiting! : WaitingModel => {}
drawWaiting! = \waiting ->
    Draw.draw! Silver \{} ->
        Draw.text! { pos: { x: 10, y: 10 }, text: "Rocci the Cool Dude", size: 40, color: Navy }
        Draw.text! { pos: { x: 10, y: 50 }, text: "Use arrow keys to walk around", size: 20, color: Green }

        playerFacing = World.playerFacing waiting.localPlayer
        Draw.textureRec! {
            texture: waiting.dude,
            source: dudeSprite playerFacing waiting.localPlayer.animation.frame,
            pos: waiting.localPlayer.pos,
            tint: Silver,
        }

renderConnected! : ConnectedModel, PlatformState => Result Model []
renderConnected! = \oldModel, state ->
    timestampMillis = state.timestamp.renderStart
    network = state.network

    deltaMillis = timestampMillis - oldModel.timestampMillis
    deltaTime = Num.toF32 deltaMillis

    # NOTE assuming only one opponent for now
    # should we log decode errors? what does it mean? out of date client?
    inbox : List World.PeerUpdate
    inbox = decodePeerUpdates network.messages

    world = World.frameTicks oldModel.world { platformState: state, deltaTime, inbox }

    model = { oldModel & world, timestampMillis }

    # SEND NEW PLAYER POSITION TO NETWORK
    sendPlayerPosition! world.localPlayer.pos network.peers.connected

    drawConnected! model state

    Ok (Connected model)

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

displayPeerConnections! : RocRay.NetworkPeers => {}
displayPeerConnections! = \{ connected, disconnected } ->
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
    |> forEach! Draw.text!

displayMessages! : List RocRay.NetworkMessage => {}
displayMessages! = \messages ->
    total = List.len messages

    totalMsg = "MESSAGES TOTAL $(Num.toStr total)"

    totalWidth =
        tw = RocRay.measureText! { text: totalMsg, size: 10 }
        Num.toFrac tw

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
    |> forEach! Draw.text!

sendPlayerPosition! : Vector2, List UUID => {}
sendPlayerPosition! = \player, peers ->
    bytes = Encode.toBytes player Json.utf8
    forEach! peers \peer -> RocRay.sendToPeer! bytes peer

drawRemotePlayer! : World.RemotePlayer => {}
drawRemotePlayer! = \{ id, pos } ->
    Draw.text! { pos, text: "$(Inspect.toStr id)", size: 10, color: Red }
    Draw.rectangle! { rect: { x: pos.x - 5, y: pos.y + 15, width: 20, height: 40 }, color: Red }

decodePeerUpdates : List RocRay.NetworkMessage -> List World.PeerUpdate
decodePeerUpdates = \messages ->
    List.keepOks messages decodeSingleUpdate

decodeSingleUpdate : RocRay.NetworkMessage -> Result World.PeerUpdate [Leftover (List U8)]DecodeError
decodeSingleUpdate = \{ id, bytes } ->
    decodeResult : Result { x : I64, y : I64 } _
    decodeResult = Decode.fromBytes bytes Json.utf8
    Result.map decodeResult \{ x, y } -> { id, x: Num.toF32 x, y: Num.toF32 y }

# TODO REPLACE WITH BUILTIN
forEach! : List a, (a => {}) => {}
forEach! = \l, f! ->
    when l is
        [] -> {}
        [x, .. as xs] ->
            f! x
            forEach! xs f!
