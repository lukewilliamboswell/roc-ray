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
import Input exposing [Input]

import Recording exposing [Recording, FrameContext, FrameMessage]

World : Recording GameState

## the non-rollback game state
GameState : {
    ## the player on the machine we're running on
    localPlayer : LocalPlayer,
    ## the player on a remote machine
    remotePlayer : RemotePlayer,
}

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
    syncTickChecksum = makeChecksum {
        localPlayer: playerStart,
        remotePlayer: playerStart,
    }

    {
        firstTick: 0,
        lastTick: 0,
        tickAdvantage: 0,
        input: Input.blank,
        syncTick: 0,
        syncTickChecksum,
    }

init : { firstMessage : Recording.PeerMessage } -> Recording GameState
init = \{ firstMessage: { id, message } } ->
    config : Recording.Config GameState
    config = {
        millisPerTick,
        maxRollbackTicks,
        tickAdvantageLimit,
        tick: gameStateTick,
        checksum: makeChecksum,
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

    recording : Recording GameState
    recording =
        Recording.start { config, firstMessage: message, state: initialState }

    recording

advance : World, FrameContext -> (World, Result FrameMessage _)
advance = \world, ctx ->
    Recording.advance world ctx

makeChecksum : { localPlayer : { pos : PixelVec }l, remotePlayer : { pos : PixelVec }r }w -> I64
makeChecksum = \{ localPlayer, remotePlayer } ->
    { localPlayerPos: localPlayer.pos, remotePlayerPos: remotePlayer.pos }
    |> Inspect.toStr
    |> Str.toUtf8
    |> List.map Num.toI64
    |> List.sum

checksumFixture =
    posA = { x: Pixel.fromParts { pixels: 300 }, y: Pixel.fromParts { pixels: 400 } }
    posB = { x: Pixel.fromParts { pixels: 300 }, y: Pixel.fromParts { pixels: 390 } }

    localChecksum = makeChecksum { localPlayer: { pos: posA }, remotePlayer: { pos: posB } }
    remoteChecksum = makeChecksum { localPlayer: { pos: posB }, remotePlayer: { pos: posA } }

    (localChecksum, remoteChecksum)

expect
    (localChecksum, remoteChecksum) = checksumFixture

    localChecksum == remoteChecksum

expect
    (localChecksum, _remoteChecksum) = checksumFixture

    localChecksum == 14709

roundVec : Vector2 -> { x : I64, y : I64 }
roundVec = \{ x, y } -> {
    x: x |> Num.round |> Num.toI64,
    y: y |> Num.round |> Num.toI64,
}

gameStateTick : GameState, Recording.TickContext -> GameState
gameStateTick = \state, { tick: _tick, timestampMillis, localInput, remoteInput } ->
    localPlayer =
        oldPlayer = state.localPlayer
        animation = updateAnimation oldPlayer.animation timestampMillis
        intent = inputToIntent localInput (playerFacing oldPlayer)
        movePlayer { oldPlayer & animation, intent } intent

    remotePlayer =
        oldRemotePlayer = state.remotePlayer
        animation = updateAnimation oldRemotePlayer.animation timestampMillis
        intent = inputToIntent remoteInput (playerFacing oldRemotePlayer)
        movePlayer { oldRemotePlayer & animation, intent } intent

    { localPlayer, remotePlayer }

inputToIntent : Input, Facing -> Intent
inputToIntent = \{ up, down, left, right }, facing ->
    horizontal =
        when (left, right) is
            (Down, Up) -> Walk Left
            (Up, Down) -> Walk Right
            _same -> Idle facing

    vertical =
        when (up, down) is
            (Down, Up) -> Walk Up
            (Up, Down) -> Walk Down
            _same -> Idle facing

    when (horizontal, vertical) is
        (Walk horizontalFacing, _) -> Walk horizontalFacing
        (Idle _, Walk verticalFacing) -> Walk verticalFacing
        (Idle idleFacing, _) -> Idle idleFacing

playerFacing : { intent : Intent }a -> Facing
playerFacing = \{ intent } ->
    when intent is
        Walk facing -> facing
        Idle facing -> facing

movePlayer : { pos : PixelVec }a, Intent -> { pos : PixelVec }a
movePlayer = \player, intent ->
    { pos } = player

    moveSpeed = { subpixels: 80 }

    newPos =
        when intent is
            Walk Up -> { pos & y: Pixel.sub pos.y moveSpeed }
            Walk Down -> { pos & y: Pixel.add pos.y moveSpeed }
            Walk Right -> { pos & x: Pixel.add pos.x moveSpeed }
            Walk Left -> { pos & x: Pixel.sub pos.x moveSpeed }
            Idle _ -> pos

    { player & pos: newPos }

updateAnimation : AnimatedSprite, U64 -> AnimatedSprite
updateAnimation = \animation, timestampMillis ->
    t = Num.toF32 timestampMillis
    if t > animation.nextAnimationTick then
        frame = Num.addWrap animation.frame 1
        millisToGo = 1000 / (Num.toF32 animation.frameRate)
        nextAnimationTick = t + millisToGo
        { animation & frame, nextAnimationTick }
    else
        animation

expect
    ourId = Network.fromU64Pair { upper: 0, lower: 0 }
    theirId = Network.fromU64Pair { upper: 0, lower: 1 }

    ourStart : Recording GameState
    ourStart = init { firstMessage: { id: theirId, message: waitingMessage } }

    theirStart : Recording GameState
    theirStart = init { firstMessage: { id: ourId, message: waitingMessage } }

    theirState = Recording.currentState theirStart
    theirPositions = (theirState.localPlayer.pos, theirState.remotePlayer.pos)

    ourState = Recording.currentState ourStart
    ourPositions = (ourState.remotePlayer.pos, ourState.localPlayer.pos)

    # Worlds are equal after init
    ourPositions == theirPositions
