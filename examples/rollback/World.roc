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
    snapshots : List Snapshot,
    # TODO instead of this, merge into snapshots
    localInputs : List FrameMessage,
    remoteInputs : List FrameMessage,
}

## A previous game state
Snapshot : {
    tick : U64,
    localPlayer : LocalPlayer,
    remotePlayer : RemotePlayer,
    predictedInput : Input,
    localInput : Input,
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
    intent : Intent,
}

FrameMessage : {
    firstTick : I64,
    lastTick : I64,
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
tickAdvantageLimit = 6

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
    remotePlayer = { id, pos: remotePos, animation: initialAnimation, intent: Idle Left }

    {
        localPlayer: playerStart,
        remotePlayer,
        remainingMillis: 0,
        tick: 0,
        remoteTick: 0,
        syncTick: 0,
        remoteTickAdvantage: 0,
        snapshots: [],
        localInputs: [],
        remoteInputs: [message],
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
    input = readInput platformState.keys

    rollbackDone =
        oldWorld
        |> updateRemoteTick inbox
        |> updateSyncTick
        |> rollbackIfNecessary

    newWorld =
        if timeSynced rollbackDone then
            # Normal Update
            rollbackDone
            |> \w -> { w & remainingMillis: w.remainingMillis + deltaTime }
            |> useAllRemainingTime input #
            # # TODO remove this after rollback is done getting added
            # |> \world -> List.walk inbox world handlePeerUpdate
        else
            # Block on network
            rollbackDone

    outgoingMessage : FrameMessage
    outgoingMessage = {
        firstTick: oldWorld.tick |> Num.toI64,
        lastTick: newWorld.tick |> Num.toI64,
        tickAdvantage: Num.toI64 newWorld.tick - Num.toI64 newWorld.remoteTick,
        input,
        pos: roundVec newWorld.localPlayer.pos,
    }

    # record input history
    localInputs =
        historyWithNew = List.append newWorld.localInputs outgoingMessage
        cleanAndSortInputs historyWithNew { syncTick: newWorld.syncTick }

    remoteInputs =
        newMessages = List.map inbox \peerMessage -> peerMessage.message
        historyWithNew = List.concat newWorld.remoteInputs newMessages
        cleanAndSortInputs historyWithNew { syncTick: newWorld.syncTick }

    (
        { newWorld & localInputs, remoteInputs },
        outgoingMessage,
    )

cleanAndSortInputs : List FrameMessage, { syncTick : U64 } -> List FrameMessage
cleanAndSortInputs = \history, { syncTick } ->
    last = List.last history
    sorted = List.sortWith history \left, right ->
        Num.compare left.firstTick right.firstTick
    cleaned =
        List.keepOks sorted \msg ->
            if msg.lastTick < Num.toI64 syncTick then Err TooOld else Ok msg
    when (cleaned, last) is
        ([], Ok l) -> [l]
        ([], Err _) -> []
        (cleans, _) -> cleans

# pre-rollback network bookkeeping
updateRemoteTick : World, List PeerMessage -> World
updateRemoteTick = \world, inbox ->
    latestRemoteMsg =
        lastInboxMsg = inbox |> List.last
        lastRecordedMsg = world.remoteInputs |> List.last
        when (lastInboxMsg, lastRecordedMsg) is
            (Ok latest, _) -> Ok latest.message
            (Err _quiet, Ok recorded) -> Ok recorded
            _none -> Err None

    (remoteTick, remoteTickAdvantage) =
        latestRemoteMsg
        |> Result.map \{ lastTick, tickAdvantage } -> (Num.toU64 lastTick, tickAdvantage)
        |> Result.withDefault (0, 0)

    { world & remoteTick, remoteTickAdvantage }

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

allUp : Input
allUp = { up: Up, down: Up, left: Up, right: Up }

## execute a single simulation tick
tickOnce : World, Input -> World
tickOnce = \world, input ->
    tick = world.tick + 1
    animationTimestamp = (Num.toFrac world.tick) * millisPerTick
    remainingMillis = world.remainingMillis - millisPerTick

    localPlayer =
        oldPlayer = world.localPlayer
        animation = updateAnimation oldPlayer.animation animationTimestamp
        intent = inputToIntent input (playerFacing oldPlayer)

        movePlayer { oldPlayer & animation, intent } intent

    predictedInput =
        inRange = \msg ->
            msg.firstTick <= Num.toI64 tick && msg.lastTick > Num.toI64 tick
        when List.last world.remoteInputs is
            Ok last if inRange last -> last.input
            Ok _ ->
                world.remoteInputs
                |> List.findLast inRange
                |> Result.map \msg -> msg.input
                |> Result.withDefault allUp

            Err _ -> allUp

    # TODO use predicted input if necessary
    remotePlayer =
        oldRemotePlayer = world.remotePlayer
        animation = updateAnimation oldRemotePlayer.animation animationTimestamp
        intent = inputToIntent predictedInput (playerFacing oldRemotePlayer)
        movePlayer { oldRemotePlayer & animation, intent } intent

    snapshots =
        newSnapshot = { tick, localPlayer, remotePlayer, predictedInput, localInput: input }
        List.append world.snapshots newSnapshot

    { world & localPlayer, remotePlayer, remainingMillis, tick, snapshots }

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

movePlayer : { pos : Vector2 }a, Intent -> { pos : Vector2 }a
movePlayer = \player, intent ->
    { pos } = player

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

updateSyncTick : World -> World
updateSyncTick = \world ->
    checkUpTo = Num.min world.tick world.remoteTick
    syncTick =
        when findMisprediction world is
            Ok mispredictedTick -> mispredictedTick - 1
            Err _perfect -> checkUpTo
    { world & syncTick }

findMisprediction : World -> Result U64 _
findMisprediction = \{ snapshots, remoteInputs } ->
    findMatch : Snapshot -> Result FrameMessage _
    findMatch = \snapshot ->
        List.findFirst remoteInputs \msg ->
            snapshotTick = Num.toI64 snapshot.tick
            snapshotTick >= msg.firstTick && snapshotTick < msg.lastTick

    misprediction : Result Snapshot _
    misprediction =
        List.findFirst snapshots \snapshot ->
            when findMatch snapshot is
                Ok match if match.input != snapshot.predictedInput -> Bool.true
                _ -> Bool.false

    Result.map misprediction \m -> m.tick

# NOTE this relies on updateSyncTick having been ran
rollbackIfNecessary : World -> World
rollbackIfNecessary = \world ->
    shouldRollback = world.tick > world.syncTick && world.remoteTick > world.syncTick
    if !shouldRollback then
        world
    else
        syncSnapshot =
            when List.findFirst world.snapshots \snap -> snap.tick == world.syncTick is
                Ok snap -> snap
                Err _ -> crash "rolled back to before the earliest snapshot"

        restoredToSync =
            { world &
                tick: world.syncTick,
                localPlayer: syncSnapshot.localPlayer,
                remotePlayer: syncSnapshot.remotePlayer,
            }

        rollForwardFromSyncTick restoredToSync

rollForwardFromSyncTick : World -> World
rollForwardFromSyncTick = \world ->
    ticksTodo = List.range { start: At (world.syncTick + 1), end: At world.tick }

    List.walk ticksTodo world \w, tick ->
        signedTick = Num.toI64 tick
        containsTick : FrameMessage -> Bool
        containsTick = \msg ->
            msg.firstTick >= signedTick && msg.lastTick > signedTick

        # actual remote input from received message
        remoteInput =
            when List.findFirst world.remoteInputs containsTick is
                Ok msg -> msg.input
                Err NotFound -> crash "matching remote input nnot found in roll forward"
        # |> Result.map \msg -> msg.input
        # |> Result.withDefault allUp

        snapshot =
            when List.findFirst snapshots \snap -> snap.tick == tick is
                Ok snap -> snap
                Err NotFound -> crash "snapshot not found in roll forward"

        # touch up the snapshots to have their 'predictions' match what happened
        snapshots = List.map w.snapshots \snap ->
            if snap.tick == tick then
                { snap & predictedInput: remoteInput }
            else
                snap

        tickOnce { w & snapshots } snapshot.localInput
