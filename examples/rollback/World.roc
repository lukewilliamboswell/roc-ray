module [
    World,
    LocalPlayer,
    RemotePlayer,
    AnimatedSprite,
    FrameMessage,
    PeerMessage,
    FrameState,
    Input,
    Intent,
    Facing,
    frameTicks,
    init,
    playerFacing,
    playerStart,
    roundVec,
]

import rr.Keys
import rr.RocRay exposing [Vector2, PlatformState]
import rr.Network exposing [UUID]

import Resolution exposing [width, height]

## The current game state and rollback metadata
World : {
    ## the player on the machine we're running on
    localPlayer : LocalPlayer,
    ## the player on a remote machine
    remotePlayer : RemotePlayer,

    ## the unspent milliseconds remaining after the last tick (or frame)
    remainingMillis : F32,

    ## the total number of simulation ticks so far
    tick : U64,
    ## the most recent tick received from the remote player
    remoteTick : U64,
    ## the last tick where we synchronized with the remote player
    syncTick : U64,
    ## the latest tick advantage received from the remote player
    remoteTickAdvantage : I64,
}

## A previous game state
Snapshot : {
    localPlayer : LocalPlayer,
    remotePlayer : RemotePlayer,
    tick : U64,
}

LocalPlayer : {
    pos : Vector2,
    animation : AnimatedSprite,
    intent : Intent,
}

RemotePlayer : {
    id : UUID,
    pos : Vector2,
    animation : AnimatedSprite,
}

FrameMessage : {
    firstTick : I64,
    nextTick : I64,
    tickAdvantage : I64,
    input : Input,
    pos : { x : I64, y : I64 },
}

PeerMessage : { id : UUID, message : FrameMessage }

AnimatedSprite : {
    frame : U8, # frame index, increments each tick
    frameRate : U8, # frames per second
    nextAnimationTick : F32, # milliseconds
}

Intent : [Walk Facing, Idle Facing]
Facing : [Up, Down, Left, Right]

Input : {
    up : [Up, Down],
    down : [Up, Down],
    left : [Up, Down],
    right : [Up, Down],
}

ticksPerSecond : U64
ticksPerSecond = 120

millisPerTick : F32
millisPerTick = 1000 / Num.toF32 ticksPerSecond

maxRollbackTicks : I64
maxRollbackTicks = 6

tickAdvantageLimit : I64
tickAdvantageLimit = 5

initialAnimation : AnimatedSprite
initialAnimation = { frame: 0, frameRate: 10, nextAnimationTick: 0 }

playerStart : LocalPlayer
playerStart = {
    pos: { x: width / 2, y: height / 2 },
    animation: initialAnimation,
    intent: Idle Right,
}

init : { firstMessage : PeerMessage } -> World
init = \{ firstMessage: { id, message } } ->
    remotePos = floatVec message.pos
    remotePlayer = { id, pos: remotePos, animation: initialAnimation }

    # TODO add message to buffer

    {
        localPlayer: playerStart,
        remotePlayer,
        remainingMillis: 0,
        tick: 0,
        remoteTick: 0,
        syncTick: 0,
        remoteTickAdvantage: 0,
    }

FrameState : {
    platformState : PlatformState,
    deltaTime : F32,
    inbox : List PeerMessage,
}

## use as many physics ticks as the frame duration allows,
## then handle any new messages from remotePlayer
frameTicks : World, FrameState -> (World, FrameMessage)
frameTicks = \oldWorld, { platformState, deltaTime, inbox } ->
    remainingMillis = oldWorld.remainingMillis + deltaTime
    input = readInput platformState.keys

    firstTick = oldWorld.tick

    newWorld =
        { oldWorld & remainingMillis }
        |> useAllRemainingTime input
        |> \world -> List.walk inbox world handlePeerUpdate

    # TODO rename this?
    nextTick = newWorld.tick

    localTickAdvantage = Num.toI64 newWorld.tick - Num.toI64 newWorld.remoteTick

    message : FrameMessage
    message = {
        firstTick: firstTick |> Num.toI64,
        nextTick: nextTick |> Num.toI64,
        tickAdvantage: localTickAdvantage,
        input,
        pos: roundVec newWorld.localPlayer.pos,
    }

    (newWorld, message)

roundVec : Vector2 -> { x : I64, y : I64 }
roundVec = \{ x, y } -> {
    x: x |> Num.round |> Num.toI64,
    y: y |> Num.round |> Num.toI64,
}

floatVec : { x : I64, y : I64 } -> Vector2
floatVec = \{ x, y } -> {
    x: x |> Num.toF32,
    y: y |> Num.toF32,
}

handlePeerUpdate : World, PeerMessage -> World
handlePeerUpdate = \world, { message } ->
    remotePlayer : RemotePlayer
    remotePlayer =
        oldRemotePlayer = world.remotePlayer
        { oldRemotePlayer & pos: floatVec message.pos }

    { world & remotePlayer }

useAllRemainingTime : World, Input -> World
useAllRemainingTime = \world, input ->
    if world.remainingMillis <= millisPerTick then
        world
    else
        tickedWorld = tickOnce world input
        useAllRemainingTime tickedWorld input

## execute a single simulation tick
tickOnce : World, Input -> World
tickOnce = \world, input ->
    animationTimestamp = (Num.toFrac world.tick) * millisPerTick

    localPlayer =
        oldPlayer = world.localPlayer
        animation = updateAnimation oldPlayer.animation animationTimestamp
        intent = inputToIntent input (playerFacing oldPlayer)

        movePlayer { oldPlayer & animation, intent }

    remotePlayer =
        oldRemotePlayer = world.remotePlayer
        animation = updateAnimation oldRemotePlayer.animation animationTimestamp
        { oldRemotePlayer & animation }

    remainingMillis = world.remainingMillis - millisPerTick
    tick = world.tick + 1

    { world & localPlayer, remotePlayer, remainingMillis, tick }

readInput : Keys.Keys -> Input
readInput = \keys ->
    up = if Keys.anyDown keys [KeyUp, KeyW] then Down else Up
    down = if Keys.anyDown keys [KeyDown, KeyS] then Down else Up
    left = if Keys.anyDown keys [KeyLeft, KeyA] then Down else Up
    right = if Keys.anyDown keys [KeyRight, KeyD] then Down else Up

    { up, down, left, right }

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

movePlayer : { pos : Vector2, intent : Intent }a -> { pos : Vector2, intent : Intent }a
movePlayer = \player ->
    { pos, intent } = player

    moveSpeed = 10.0
    newPos =
        when intent is
            Walk Up -> { pos & y: pos.y - moveSpeed }
            Walk Down -> { pos & y: pos.y + moveSpeed }
            Walk Right -> { pos & x: pos.x + moveSpeed }
            Walk Left -> { pos & x: pos.x - moveSpeed }
            Idle _ -> pos

    { player & pos: newPos }

updateAnimation : AnimatedSprite, F32 -> AnimatedSprite
updateAnimation = \animation, timestampMillis ->
    if timestampMillis > animation.nextAnimationTick then
        frame = Num.addWrap animation.frame 1
        millisToGo = 1000 / (Num.toF32 animation.frameRate)
        nextAnimationTick = timestampMillis + millisToGo
        { animation & frame, nextAnimationTick }
    else
        animation

## true if we're in sync enough with remote player to continue updates
timeSynced : World -> Bool
timeSynced = \{ tick, remoteTick, remoteTickAdvantage } ->
    localTickAdvantage = Num.toI64 tick - Num.toI64 remoteTick
    tickAdvantageDifference = localTickAdvantage - remoteTickAdvantage
    localTickAdvantage < maxRollbackTicks && tickAdvantageDifference <= tickAdvantageLimit
