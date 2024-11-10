app [Model, init!, render!] {
    rr: platform "../../platform/main.roc",
    json: "https://github.com/lukewilliamboswell/roc-json/releases/download/0.10.2/FH4N0Sw-JSFXJfG3j54VEDPtXOoN-6I9v_IA8S18IGk.tar.br",
}

### This is an example of using RocRay's matchbox networking integration for a peer-to-peer multiplayer game.
### The Rollback module is based on pseudocode from the Guilty Gear Strive team.
### Note that this version relies on TCP for handling message ordering and packet loss.
### In a real game or polished networking library, you'd likely do many things differently.
###
### Matchbox WebRTC: https://github.com/johanhelsing/matchbox
### GGST's Rollback Pseudocode: https://gist.github.com/rcmagic/f8d76bca32b5609e85ab156db38387e9
### An explanation of fixed timestep: https://gafferongames.com/post/fix_your_timestep/

import rr.RocRay exposing [Texture, Rectangle, PlatformState]
import rr.Draw
import rr.Texture
import rr.Network

import json.Json

import Resolution exposing [width, height]
import Rollback
import Pixel
import Input
import World

Model : [Waiting WaitingModel, Connected ConnectedModel]

WaitingModel : {
    dude : Texture,
}

ConnectedModel : {
    dude : Texture,
    world : Rollback.Recording,
    timestampMillis : U64,
}

init! : {} => Result Model _
init! = \{} ->
    serverUrl = "ws://localhost:3536/yolo?next=2"

    RocRay.setTargetFPS! 120
    RocRay.displayFPS! { fps: Visible, pos: { x: 100, y: 100 } }
    Network.configure! { serverUrl }
    RocRay.initWindow! {
        title: "Rollback Example",
        width: Num.toF32 width,
        height: Num.toF32 height,
    }

    dude = Texture.load!? "examples/assets/sprite-dude/sheet.png"

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

        currentState = Rollback.currentState world

        # draw local player
        localPlayer = currentState.localPlayer
        localPlayerFacing = World.playerFacing localPlayer
        Draw.textureRec! {
            texture: dude,
            source: dudeSprite localPlayerFacing localPlayer.animation.frame,
            pos: Pixel.toVector2 localPlayer.pos,
            tint: White,
        }

        # draw remote player
        remotePlayer = currentState.remotePlayer
        remotePlayerIdPos = Pixel.toVector2 remotePlayer.pos
        Draw.text! {
            pos: remotePlayerIdPos,
            text: "remote player",
            size: 10,
            color: Red,
        }
        remotePlayerFacing = World.playerFacing remotePlayer
        Draw.textureRec! {
            texture: dude,
            source: dudeSprite remotePlayerFacing remotePlayer.animation.frame,
            pos: Pixel.toVector2 remotePlayer.pos,
            tint: Red,
        }

        # draw ui
        displayPeerConnections! state.network.peers

renderWaiting! : WaitingModel, PlatformState => Result Model []
renderWaiting! = \waiting, state ->
    guestJoinMessage =
        state.network.messages
        |> List.last
        |> Result.try decodeSingleFrameMessage

    when guestJoinMessage is
        Ok firstUpdate ->
            waitingToConnected! waiting state firstUpdate

        Err ListWasEmpty ->
            sendHostWaiting! state.network
            drawWaiting! waiting
            Ok (Waiting waiting)

        Err (Leftover _) | Err TooShort ->
            RocRay.log! "decode error" LogError
            sendHostWaiting! state.network
            drawWaiting! waiting
            Ok (Waiting waiting)

waitingToConnected! : WaitingModel, PlatformState, Rollback.PeerMessage => Result Model []
waitingToConnected! = \waiting, state, firstMessage ->
    config : Rollback.Config
    config = {
        millisPerTick: 1000 // 120,
        maxRollbackTicks: 16,
        tickAdvantageLimit: 10,
    }

    world : Rollback.Recording
    world = Rollback.start {
        config,
        firstMessage: firstMessage.message,
        state: World.initial,
    }

    connected : ConnectedModel
    connected = {
        world,
        dude: waiting.dude,
        timestampMillis: state.timestamp.renderStart,
    }

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
            pos: Pixel.toVector2 localPlayer.pos,
            tint: Silver,
        }

renderConnected! : ConnectedModel, PlatformState => Result Model []
renderConnected! = \oldModel, state ->
    timestampMillis = state.timestamp.renderStart
    network = state.network

    deltaMillis = timestampMillis - oldModel.timestampMillis

    inbox : List Rollback.PeerMessage
    inbox = decodeFrameMessages network.messages

    localInput = Input.read state.keys
    (world, outgoing) =
        Rollback.advance oldModel.world { localInput, deltaMillis, inbox }

    model = { oldModel & world, timestampMillis }

    blocked =
        when outgoing is
            Ok message ->
                sendFrameMessage! message network
                if message.input != Input.blank then
                    RocRay.log! "Sent Message:\n$(Inspect.toStr message)" LogInfo
                else
                    {}

                Advancing

            Err e -> e

    drawConnected! model state

    when blocked is
        Advancing -> {}
        Skipped -> {}
        BlockedFor blockedFrames ->
            when blockedFrames is
                f if f < 5 -> {}
                f if f < 100 ->
                    RocRay.log! "Blocked for $(Inspect.toStr blockedFrames) frames" LogWarning

                _f ->
                    crashInfo = Rollback.showCrashInfo world
                    history = Rollback.writableHistory world
                    crash "blocked world:\n$(crashInfo)\n$(history)"

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
        pos: { x: 10, y: (Num.toF32 height) - 10 - (Num.toFrac (i * 10)) },
        text: List.get combined i |> Result.withDefault "OUT OF BOUNDS",
        size: 10,
        color: Black,
    }
    |> forEach! Draw.text!

sendHostWaiting! : RocRay.NetworkState => {}
sendHostWaiting! = \network ->
    waitingMessage : Rollback.FrameMessage
    waitingMessage =
        syncTickChecksum = World.positionsChecksum {
            localPlayerPos: World.playerStart.pos,
            remotePlayerPos: World.playerStart.pos,
        }

        {
            firstTick: 0,
            lastTick: 0,
            tickAdvantage: 0,
            input: Input.blank,
            syncTick: 0,
            syncTickChecksum,
        }

    sendFrameMessage! waitingMessage network

sendFrameMessage! : Rollback.FrameMessage, RocRay.NetworkState => {}
sendFrameMessage! = \message, network ->
    bytes = Encode.toBytes (worldToNetwork message) Json.utf8
    forEach! network.peers.connected \peer -> RocRay.sendToPeer! bytes peer

decodeFrameMessages : List RocRay.NetworkMessage -> List Rollback.PeerMessage
decodeFrameMessages = \messages ->
    List.map messages \networkMsg ->
        when decodeSingleFrameMessage networkMsg is
            Ok msg -> msg
            Err e ->
                crashInfo = Inspect.toStr {
                    decodeError: e,
                    networkMessage: Str.fromUtf8 networkMsg.bytes,
                }
                crash "decode error: $(crashInfo)"

FrameMessageJson : {
    firstTick : I64,
    lastTick : I64,
    tickAdvantage : I64,
    up : Bool,
    down : Bool,
    left : Bool,
    right : Bool,
    syncTick : I64,
    syncTickChecksum : I64,
}

networkToWorld : FrameMessageJson -> Rollback.FrameMessage
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
        syncTick: json.syncTick,
        syncTickChecksum: json.syncTickChecksum,
    }

worldToNetwork : Rollback.FrameMessage -> FrameMessageJson
worldToNetwork = \message -> {
    firstTick: message.firstTick,
    lastTick: message.lastTick,
    tickAdvantage: message.tickAdvantage,
    up: message.input.up == Down,
    down: message.input.down == Down,
    left: message.input.left == Down,
    right: message.input.right == Down,
    syncTick: message.syncTick,
    syncTickChecksum: message.syncTickChecksum,
}

decodeSingleFrameMessage : RocRay.NetworkMessage -> Result Rollback.PeerMessage _
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

