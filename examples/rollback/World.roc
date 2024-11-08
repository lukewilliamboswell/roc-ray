module [
    World,
    advance,
    init,
    playerStart,
    roundVec,
    waitingMessage,
]

# TODO: before merge
# finish module cleanup
#   split out current World, rename GameState
# use ring buffers
# use bytes instead of json
# address/remove in-code TODOs
# more unit tests
# explain that the inline expects don't do anything
#   ask on PR about that

# TODO: later
# add configurable input delay
#   need an input delay buffer for specifically not-yet-applied local inputs
# make rollback stuff configurable (including going fully delay-based)
#   rollbackLog max length
#
# allow disabling rollbacks entirely for testing game determinism
#   does configuring max rollback 0 do this already?
#
# when skipping inputs based on fixed timestep (ie, when returning Skipped),
#   provide some way for the game to access those inputs
#   or just leave a comment and make it a non-example problem
#
# UDP:
#   handle out of order messages
#     sort messages/inputs when added to ring buffer
#     updateSyncTick needs to handle late messages
#   handle/mitigate packet loss
#     have FrameMessages include overlapping windows
#   desync recovery? out of scope for example

import rr.RocRay exposing [Vector2]
import rr.Network

import Resolution exposing [width, height]
import Pixel
import Input

import GameState exposing [GameState, LocalPlayer, AnimatedSprite]
import Rollback

World : Rollback.Recording

# TODO move these to main
millisPerTick : U64
millisPerTick = 1000 // 120

maxRollbackTicks : I64
maxRollbackTicks = 6

tickAdvantageLimit : I64
tickAdvantageLimit = 6

# TODO move this to GameState
playerStart : LocalPlayer
playerStart =
    x = Pixel.fromParts { pixels: (width // 2) }
    y = Pixel.fromParts { pixels: (height // 2) }

    {
        pos: { x, y },
        animation: initialAnimation,
        intent: Idle Right,
    }

# TODO move this to GameState
initialAnimation : AnimatedSprite
initialAnimation = { frame: 0, frameRate: 10, nextAnimationTick: 0 }

# TODO move this to Rollback
waitingMessage : Rollback.FrameMessage
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

# TODO move this to Rollback
init : { firstMessage : Rollback.PeerMessage } -> Rollback.Recording
init = \{ firstMessage: { id, message } } ->
    config : Rollback.Config
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

    Rollback.start { config, firstMessage: message, state: initialState }

# TODO call this directly in main
advance : World, Rollback.FrameContext -> (World, Result Rollback.FrameMessage _)
advance = \world, ctx ->
    Rollback.advance world ctx

# TODO move this to main
roundVec : Vector2 -> { x : I64, y : I64 }
roundVec = \{ x, y } -> {
    x: x |> Num.round |> Num.toI64,
    y: y |> Num.round |> Num.toI64,
}

expect
    ourId = Network.fromU64Pair { upper: 0, lower: 0 }
    theirId = Network.fromU64Pair { upper: 0, lower: 1 }

    ourStart : Rollback.Recording
    ourStart = init { firstMessage: { id: theirId, message: waitingMessage } }

    theirStart : Rollback.Recording
    theirStart = init { firstMessage: { id: ourId, message: waitingMessage } }

    theirState = Rollback.currentState theirStart
    theirPositions = (theirState.localPlayer.pos, theirState.remotePlayer.pos)

    ourState = Rollback.currentState ourStart
    ourPositions = (ourState.remotePlayer.pos, ourState.localPlayer.pos)

    # Worlds are equal after init
    ourPositions == theirPositions
