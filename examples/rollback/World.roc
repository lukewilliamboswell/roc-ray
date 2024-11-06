module [
    World,
    AnimatedSprite,
    Facing,
    Intent,
    LocalPlayer,
    RemotePlayer,
    advance,
    init,
    playerFacing,
    playerStart,
    roundVec,
    waitingMessage,
]

# TODO: before merge
# split out a separate module
# try using bytes instead of json
# more unit tests
# address/remove in-code TODOs
# explain that the inline expects don't do anything
#   ask on PR about that
# use ring buffers
# confirm whether we need deduping in frameMessagesToTicks
#   if we do it's a bug
#
# TODO: later
# add input delay
#   use a separate buffer for local inputs from snapshots
# make rollback stuff configurable (including going fully delay-based)
#   input delay frames/ticks
#   rollbackLog max length
#   maxRollbackTicks and tickAdvantageLimit
# send overlapping histories of inputs to handle packet loss
# recover from desyncs - request-response?
#   maybe just expose to the app/user and make it game's problem?
# allow disabling rollbacks entirely for testing game determinism
# incorporate fuzz testing?
# track more network events in rollbackLog
# when skipping inputs based on fixed timestep (ie, when returning Skipped),
#   provide some way for the game to access those inputs

import rr.RocRay exposing [Vector2]
import rr.Network exposing [UUID]

import Resolution exposing [width, height]
import Pixel exposing [PixelVec]
import Input

import GameState exposing [GameState]
import Recording exposing [Recording, FrameContext, FrameMessage]

World : Recording

LocalPlayer : {
    pos : PixelVec,
    animation : AnimatedSprite,
    intent : Intent,
}

RemotePlayer : {
    id : UUID,
    pos : PixelVec,
    animation : AnimatedSprite,
    intent : Intent,
}

AnimatedSprite : {
    frame : U8, # frame index, increments each tick
    frameRate : U8, # frames per second
    nextAnimationTick : F32, # milliseconds
}

Intent : [Walk Facing, Idle Facing]

Facing : [Up, Down, Left, Right]

millisPerTick : U64
millisPerTick = 1000 // 120

maxRollbackTicks : I64
maxRollbackTicks = 6

tickAdvantageLimit : I64
tickAdvantageLimit = 6

playerStart : LocalPlayer
playerStart =
    x = Pixel.fromParts { pixels: (width // 2) }
    y = Pixel.fromParts { pixels: (height // 2) }

    {
        pos: { x, y },
        animation: initialAnimation,
        intent: Idle Right,
    }

initialAnimation : AnimatedSprite
initialAnimation = { frame: 0, frameRate: 10, nextAnimationTick: 0 }

waitingMessage : FrameMessage
waitingMessage =
    syncTickChecksum = GameState.positionsChecksum {
        localPlayerPos: playerStart.pos,
        remotePlayerPos: playerStart.pos,
    }

    {
        firstTick: 0,
        lastTick: 0,
        tickAdvantage: 0,
        input: Input.blank,
        syncTick: 0,
        syncTickChecksum,
    }

init : { firstMessage : Recording.PeerMessage } -> Recording
init = \{ firstMessage: { id, message } } ->
    config : Recording.Config
    config = {
        millisPerTick,
        maxRollbackTicks,
        tickAdvantageLimit,
    }

    initialState : GameState
    initialState = {
        localPlayer: playerStart,
        remotePlayer: {
            id,
            pos: playerStart.pos,
            animation: playerStart.animation,
            intent: playerStart.intent,
        },
    }

    Recording.start { config, firstMessage: message, state: initialState }

advance : World, FrameContext -> (World, Result FrameMessage _)
advance = \world, ctx ->
    Recording.advance world ctx

roundVec : Vector2 -> { x : I64, y : I64 }
roundVec = \{ x, y } -> {
    x: x |> Num.round |> Num.toI64,
    y: y |> Num.round |> Num.toI64,
}

playerFacing : { intent : Intent }a -> Facing
playerFacing = \{ intent } ->
    when intent is
        Walk facing -> facing
        Idle facing -> facing

expect
    ourId = Network.fromU64Pair { upper: 0, lower: 0 }
    theirId = Network.fromU64Pair { upper: 0, lower: 1 }

    ourStart : Recording
    ourStart = init { firstMessage: { id: theirId, message: waitingMessage } }

    theirStart : Recording
    theirStart = init { firstMessage: { id: ourId, message: waitingMessage } }

    theirState = Recording.currentState theirStart
    theirPositions = (theirState.localPlayer.pos, theirState.remotePlayer.pos)

    ourState = Recording.currentState ourStart
    ourPositions = (ourState.remotePlayer.pos, ourState.localPlayer.pos)

    # Worlds are equal after init
    ourPositions == theirPositions
