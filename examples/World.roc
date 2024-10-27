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
    new,
    opponentPositions,
    playerFacing,
]

import rr.Keys
import rr.RocRay exposing [Vector2, PlatformState]
import rr.Network exposing [UUID]

World : {
    localPlayer : LocalPlayer,
    opponent : [Connected RemotePlayer, Disconnected],
    ## the unspent milliseconds remaining after the last tick (or frame)
    remainingMillis : F32,
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

AnimatedSprite : {
    frame : U8, # frame index, increments each tick
    frameRate : U8, # frames per second
    nextAnimationTick : F32, # milliseconds
}

Intent : [Walk Facing, Idle Facing]
Facing : [Up, Down, Left, Right]

updateAnimation : AnimatedSprite, F32 -> AnimatedSprite
updateAnimation = \animation, timestampMillis ->
    if timestampMillis > animation.nextAnimationTick then
        frame = Num.addWrap animation.frame 1
        millisToGo = 1000 / (Num.toF32 animation.frameRate)
        nextAnimationTick = timestampMillis + millisToGo
        { animation & frame, nextAnimationTick }
    else
        animation

ticksPerSecond : U64
ticksPerSecond = 120

millisPerTick : F32
millisPerTick = 1000 / Num.toF32 ticksPerSecond

new : { localPlayer : LocalPlayer } -> World
new = \{ localPlayer } -> {
    localPlayer,
    opponent: Disconnected,
    remainingMillis: 0,
}

FrameState : {
    platformState : PlatformState,
    deltaTime : F32,
    inbox : List PeerUpdate,
}

PeerUpdate : {
    id : UUID,
    x : F32,
    y : F32,
}

## use as many physics ticks as the frame duration allows
frameTicks : World, FrameState -> World
frameTicks = \world, { platformState, deltaTime, inbox } ->
    remainingMillis = world.remainingMillis + deltaTime
    newWorld = useAllRemainingTime { world & remainingMillis } platformState

    # TODO use inputs instead of last known position
    opponent =
        when (newWorld.opponent, inbox) is
            (Disconnected, []) -> Disconnected
            (Connected remotePlayer, []) -> Connected remotePlayer
            (_, messages) ->
                when List.last messages is
                    Ok { id, x, y } -> Connected { id, pos: { x, y } }
                    Err _ -> crash "bug in frameTicks opponent update"

    { newWorld & opponent }

useAllRemainingTime : World, PlatformState -> World
useAllRemainingTime = \world, platformState ->
    if world.remainingMillis <= millisPerTick then
        world
    else
        tickedWorld = tick world platformState
        useAllRemainingTime tickedWorld platformState

## a single simulation tick
tick : World, PlatformState -> World
tick = \world, state ->
    localPlayer =
        oldPlayer = world.localPlayer
        animation = updateAnimation oldPlayer.animation millisPerTick
        intent = readInput state.keys (playerFacing oldPlayer)

        { oldPlayer & animation, intent }
        |> movePlayer

    opponent = world.opponent

    # opponent =
    #     when world.opponent is
    #         Disconnected -> Disconnected
    #         Connected remotePlayer ->
    #             animation = updateAnimation remotePlayer.animation millisPerTick
    #             Connected { remotePlayer & animation }

    remainingMillis = world.remainingMillis - millisPerTick

    { world & localPlayer, opponent, remainingMillis }

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

opponentPositions : World -> List RemotePlayer
opponentPositions = \world ->
    when world.opponent is
        Connected remotePlayer -> [remotePlayer]
        Disconnected -> []
