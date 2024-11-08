module [
    GameState,
    LocalPlayer,
    RemotePlayer,
    AnimatedSprite,
    Facing,
    Intent,
    tick,
    checksum,
    positionsChecksum,
    playerFacing,
    initial,
    playerStart,
]

import Input exposing [Input, TickContext]
import Pixel exposing [PixelVec]
import Resolution exposing [width, height]

## the game state unrelated to rollback bookkeeping
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

# TODO remove?
RemotePlayer : {
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

initial : GameState
initial = {
    localPlayer: playerStart,
    remotePlayer: {
        pos: playerStart.pos,
        animation: playerStart.animation,
        intent: playerStart.intent,
    },
}

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

checksum : GameState -> I64
checksum = \{ localPlayer, remotePlayer } ->
    positionsChecksum {
        localPlayerPos: localPlayer.pos,
        remotePlayerPos: remotePlayer.pos,
    }

positionsChecksum : { localPlayerPos : PixelVec, remotePlayerPos : PixelVec } -> I64
positionsChecksum = \positions ->
    positions
    |> Inspect.toStr
    |> Str.toUtf8
    |> List.map Num.toI64
    |> List.sum

tick : GameState, TickContext -> GameState
tick = \state, { timestampMillis, localInput, remoteInput } ->
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
