app [Model, init!, render!] {
    rr: platform "../../platform/main.roc",
    json: "https://github.com/lukewilliamboswell/roc-json/releases/download/0.10.2/FH4N0Sw-JSFXJfG3j54VEDPtXOoN-6I9v_IA8S18IGk.tar.br",
}

import rr.RocRay exposing [Texture, Rectangle, PlatformState]
import rr.Draw
import rr.Texture
import rr.Network

import json.Json

import Resolution exposing [width, height]
import World exposing [World]

Model : [Waiting WaitingModel, Connected ConnectedModel]

WaitingModel : {
    dude : Texture,
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

    waiting : WaitingModel
    waiting = { dude }

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

        # draw local player
        playerFacing = World.playerFacing world.localPlayer
        Draw.textureRec! {
            texture: dude,
            source: dudeSprite playerFacing world.localPlayer.animation.frame,
            pos: world.localPlayer.pos,
            tint: White,
        }

        # draw remote player

        Draw.text! {
            pos: world.remotePlayer.pos,
            text: "$(Inspect.toStr world.remotePlayer.id)",
            size: 10,
            color: Red,
        }
        Draw.textureRec! {
            texture: dude,
            source: dudeSprite Down world.remotePlayer.animation.frame,
            pos: world.remotePlayer.pos,
            tint: Red,
        }

        # draw ui
        displayPeerConnections! state.network.peers
        displayMessages! state.network.messages

renderWaiting! : WaitingModel, PlatformState => Result Model []
renderWaiting! = \waiting, state ->
    guestJoinMessage =
        state.network.messages
        |> List.last
        |> Result.try decodeSingleFrameMessage

    when guestJoinMessage is
        Ok firstUpdate ->
            waitingToConnected! waiting state firstUpdate

        Err _ ->
            sendHostWaiting! state.network
            drawWaiting! waiting
            Ok (Waiting waiting)

waitingToConnected! : WaitingModel, PlatformState, World.PeerMessage => Result Model []
waitingToConnected! = \waiting, state, firstMessage ->
    timestampMillis = state.timestamp.renderStart
    { dude } = waiting

    world = World.init { firstMessage }

    connected : ConnectedModel
    connected = { dude, world, timestampMillis }

    drawConnected! connected state

    Ok (Connected connected)

drawWaiting! : WaitingModel => {}
drawWaiting! = \waiting ->
    Draw.draw! Silver \{} ->
        Draw.text! { pos: { x: 10, y: 10 }, text: "Rocci the Cool Dude", size: 40, color: Navy }
        Draw.text! { pos: { x: 10, y: 50 }, text: "Use arrow keys to walk around", size: 20, color: Green }

        localPlayer = World.playerStart
        playerFacing = World.playerFacing localPlayer
        Draw.textureRec! {
            texture: waiting.dude,
            source: dudeSprite playerFacing localPlayer.animation.frame,
            pos: localPlayer.pos,
            tint: Silver,
        }

renderConnected! : ConnectedModel, PlatformState => Result Model []
renderConnected! = \oldModel, state ->
    timestampMillis = state.timestamp.renderStart
    network = state.network

    deltaMillis = timestampMillis - oldModel.timestampMillis
    deltaTime = Num.toF32 deltaMillis

    inbox : List World.PeerMessage
    inbox = decodeFrameMessages network.messages

    (world, message) = World.frameTicks oldModel.world { platformState: state, deltaTime, inbox }

    model = { oldModel & world, timestampMillis }

    sendFrameMessage! message network

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

sendHostWaiting! : RocRay.NetworkState => {}
sendHostWaiting! = \network ->
    message : World.FrameMessage
    message = {
        firstTick: 0,
        lastTick: 1,
        tickAdvantage: 0,
        input: { up: Up, down: Up, left: Up, right: Up },
        pos: World.roundVec World.playerStart.pos,
    }

    sendFrameMessage! message network

sendFrameMessage! : World.FrameMessage, RocRay.NetworkState => {}
sendFrameMessage! = \message, network ->
    bytes = Encode.toBytes (worldToNetwork message) Json.utf8
    forEach! network.peers.connected \peer -> RocRay.sendToPeer! bytes peer

decodeFrameMessages : List RocRay.NetworkMessage -> List World.PeerMessage
decodeFrameMessages = \messages ->
    List.keepOks messages decodeSingleFrameMessage

FrameMessageJson : {
    firstTick : I64,
    lastTick : I64,
    tickAdvantage : I64,
    up : Bool,
    down : Bool,
    left : Bool,
    right : Bool,
    x : I64,
    y : I64,
}

networkToWorld : FrameMessageJson -> World.FrameMessage
networkToWorld = \json ->
    up = if json.up then Down else Up
    down = if json.down then Down else Up
    left = if json.left then Down else Up
    right = if json.right then Down else Up

    {
        firstTick: json.firstTick,
        lastTick: json.lastTick,
        tickAdvantage: json.tickAdvantage,
        input: { up, down, left, right },
        pos: { x: json.x, y: json.y },
    }

worldToNetwork : World.FrameMessage -> FrameMessageJson
worldToNetwork = \message -> {
    firstTick: message.firstTick,
    lastTick: message.lastTick,
    tickAdvantage: message.tickAdvantage,
    up: message.input.up == Down,
    down: message.input.down == Down,
    left: message.input.left == Down,
    right: message.input.right == Down,
    x: message.pos.x,
    y: message.pos.y,
}

decodeSingleFrameMessage : RocRay.NetworkMessage -> Result World.PeerMessage _
decodeSingleFrameMessage = \{ id, bytes } ->
    decodeResult : Result FrameMessageJson _
    decodeResult = Decode.fromBytes bytes Json.utf8
    Result.map decodeResult \json ->
        { id, message: networkToWorld json }

# TODO REPLACE WITH BUILTIN
forEach! : List a, (a => {}) => {}
forEach! = \l, f! ->
    when l is
        [] -> {}
        [x, .. as xs] ->
            f! x
            forEach! xs f!
