module [
    World,
    LocalPlayer,
    RemotePlayer,
    AnimatedSprite,
    PeerUpdate,
    FrameState,
    Intent,
    Facing,
    frameTicks,
    init,
    playerFacing,
]

import rr.Keys
import rr.RocRay exposing [Vector2, PlatformState]
import rr.Network exposing [UUID]

World : {
    localPlayer : LocalPlayer,
    remotePlayer : RemotePlayer,
    ## the unspent milliseconds remaining after the last tick (or frame)
    remainingMillis : F32,
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
}

PeerUpdate : {
    id : UUID,
    x : F32,
    y : F32,
}

AnimatedSprite : {
    frame : U8, # frame index, increments each tick
    frameRate : U8, # frames per second
    nextAnimationTick : F32, # milliseconds
}

Intent : [Walk Facing, Idle Facing]
Facing : [Up, Down, Left, Right]

ticksPerSecond : U64
ticksPerSecond = 120

millisPerTick : F32
millisPerTick = 1000 / Num.toF32 ticksPerSecond

init : { localPlayer : LocalPlayer, firstUpdate : PeerUpdate } -> World
init = \{ localPlayer, firstUpdate } ->
    remainingMillis = 0
    tick = 0
    pos = { x: firstUpdate.x, y: firstUpdate.y }
    remotePlayer = { id: firstUpdate.id, pos }

    { localPlayer, remotePlayer, remainingMillis, tick }

FrameState : {
    platformState : PlatformState,
    deltaTime : F32,
    inbox : List PeerUpdate,
}

## use as many physics ticks as the frame duration allows
frameTicks : World, FrameState -> World
frameTicks = \world, { platformState, deltaTime, inbox } ->
    remainingMillis = world.remainingMillis + deltaTime
    newWorld = useAllRemainingTime { world & remainingMillis } platformState

    # TODO use recorded inputs instead of last known position
    remotePlayer : RemotePlayer
    remotePlayer =
        when List.last inbox is
            Ok { id, x, y } -> { id, pos: { x, y } }
            Err ListWasEmpty -> world.remotePlayer

    { newWorld & remotePlayer }

useAllRemainingTime : World, PlatformState -> World
useAllRemainingTime = \world, platformState ->
    if world.remainingMillis <= millisPerTick then
        world
    else
        tickedWorld = tickOnce world platformState
        useAllRemainingTime tickedWorld platformState

## execute a single simulation tick
tickOnce : World, PlatformState -> World
tickOnce = \world, state ->
    localPlayer =
        oldPlayer = world.localPlayer
        animation = updateAnimation oldPlayer.animation millisPerTick
        intent = readInput state.keys (playerFacing oldPlayer)

        movePlayer { oldPlayer & animation, intent }

    # TODO animate remotePlayer

    remainingMillis = world.remainingMillis - millisPerTick
    tick = world.tick + 1

    { world & localPlayer, remainingMillis, tick }

readInput : Keys.Keys, Facing -> Intent
readInput = \keys, facing ->
    up = if Keys.anyDown keys [KeyUp, KeyW] then Down else Up
    down = if Keys.anyDown keys [KeyDown, KeyS] then Down else Up
    left = if Keys.anyDown keys [KeyLeft, KeyA] then Down else Up
    right = if Keys.anyDown keys [KeyRight, KeyD] then Down else Up

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
