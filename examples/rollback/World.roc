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
    showCrashInfo,
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
    remoteInputs : List FrameMessage,
    remoteInputTicks : List InputTick,
    ## whether we're blocked on remote input and for how long; used for logging
    blocked : [Unblocked, BlockedFor U64],
}

InputTick : { tick : U64, input : Input }

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

millisPerTick : U64
millisPerTick = 1000 // 120

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
    remotePlayer = { id, pos: playerStart.pos, animation: initialAnimation, intent: Idle Left }
    localPlayer = playerStart

    remoteInputs = [message]
    remoteInputTicks = frameMessagesToTicks remoteInputs

    initialSyncSnapshot : Snapshot
    initialSyncSnapshot = {
        tick: 0,
        localPlayer,
        remotePlayer,
        predictedInput: allUp,
        localInput: allUp,
    }

    {
        localPlayer,
        remotePlayer,
        remainingMillis: 0,
        tick: 0,
        remoteTick: 0,
        syncTick: 0,
        remoteTickAdvantage: 0,
        snapshots: [initialSyncSnapshot],
        remoteInputs,
        remoteInputTicks,
        blocked: Unblocked,
    }

frameMessagesToTicks : List FrameMessage -> List InputTick
frameMessagesToTicks = \messages ->
    List.joinMap messages \msg ->
        range =
            when Num.compare msg.firstTick msg.lastTick is
                LT -> List.range { start: At msg.firstTick, end: At msg.lastTick }
                GT -> []
                EQ -> [msg.firstTick]

        List.map range \tick -> { tick: Num.toU64 tick, input: msg.input }

FrameState : {
    platformState : PlatformState,
    deltaTime : F32,
    inbox : List PeerMessage,
}

## then handle any new messages from remotePlayer
frameTicks : World, FrameState -> (World, FrameMessage)
frameTicks = \oldWorld, { platformState, deltaTime, inbox } ->
    input = readInput platformState.keys

    rollbackDone =
        oldWorld
        |> updateRemoteTick inbox
        |> updateSyncTick
        |> rollbackIfNecessary { input }

    newWorld =
        if timeSynced rollbackDone then
            # Normal Update
            rollbackDone
            |> \w -> { w & remainingMillis: w.remainingMillis + deltaTime }
            |> normalUpdate { input, deltaTime }
            |> &blocked Unblocked
        else
            # Block on remote updates
            blocked =
                when rollbackDone.blocked is
                    BlockedFor frames -> BlockedFor (frames + 1)
                    Unblocked -> BlockedFor 1
            { rollbackDone & blocked }

    outgoingMessage : FrameMessage
    outgoingMessage = {
        firstTick: oldWorld.tick |> Num.toI64,
        lastTick: newWorld.tick |> Num.toI64,
        tickAdvantage: Num.toI64 newWorld.tick - Num.toI64 newWorld.remoteTick,
        input,
    }

    snapshots = newWorld.snapshots
    # this caused problems for some reason
    # newWorld.snapshots
    # |> List.dropIf \snap -> snap.tick < newWorld.syncTick

    # TODO should these be handled before the normal update?
    # both local and remote as very first thing maybe
    remoteInputs =
        newMessages = List.map inbox \peerMessage -> peerMessage.message
        newWorld.remoteInputs
        |> List.concat newMessages
        |> cleanAndSortInputs { syncTick: newWorld.syncTick }
    remoteInputTicks = frameMessagesToTicks remoteInputs

    (
        { newWorld & remoteInputs, remoteInputTicks, snapshots },
        outgoingMessage,
    )

## use as many physics ticks as the frame duration allows
normalUpdate : World, { input : Input, deltaTime : F32 } -> World
normalUpdate = \world, { input, deltaTime } ->
    useAllRemainingTime
        { world & remainingMillis: world.remainingMillis + deltaTime }
        input

useAllRemainingTime : World, Input -> World
useAllRemainingTime = \world, input ->
    if world.remainingMillis <= Num.toF32 millisPerTick then
        world
    else
        tickedWorld = tickOnce world input
        useAllRemainingTime tickedWorld input

cleanAndSortInputs : List FrameMessage, { syncTick : U64 } -> List FrameMessage
cleanAndSortInputs = \history, { syncTick } ->
    last = List.last history
    sorted = List.sortWith history \left, right ->
        Num.compare left.firstTick right.firstTick
    sortedUnique = List.walk sorted [] \lst, item ->
        when List.last lst is
            Ok same if same.firstTick == item.firstTick -> lst
            _ -> List.append lst item

    cleaned =
        List.keepOks sortedUnique \msg ->
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

allUp : Input
allUp = { up: Up, down: Up, left: Up, right: Up }

## execute a single simulation tick
tickOnce : World, Input -> World
tickOnce = \world, input ->
    tick = world.tick + 1
    animationTimestamp = world.tick * millisPerTick
    remainingMillis = world.remainingMillis - Num.toF32 millisPerTick

    localPlayer =
        oldPlayer = world.localPlayer
        animation = updateAnimation oldPlayer.animation animationTimestamp
        intent = inputToIntent input (playerFacing oldPlayer)

        movePlayer { oldPlayer & animation, intent } intent

    predictedInput =

        receivedInput =
            world.remoteInputTicks
            |> List.findLast \inputTick -> inputTick.tick == tick
            |> Result.map \inputTick -> inputTick.input

        when receivedInput is
            # confirmed remote input
            Ok received -> received
            Err NotFound ->
                when List.last world.remoteInputTicks is
                    # predict the last thing they did
                    Ok last -> last.input
                    # predict idle on the first frame
                    Err _ -> allUp

    remotePlayer =
        oldRemotePlayer = world.remotePlayer
        animation = updateAnimation oldRemotePlayer.animation animationTimestamp
        intent = inputToIntent predictedInput (playerFacing oldRemotePlayer)
        movePlayer { oldRemotePlayer & animation, intent } intent

    snapshots =
        newSnapshot = {
            tick,
            localPlayer,
            remotePlayer,
            predictedInput,
            localInput: input,
        }
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
rollbackIfNecessary : World, { input : Input } -> World
rollbackIfNecessary = \world, { input } ->
    shouldRollback = world.tick > world.syncTick && world.remoteTick > world.syncTick
    if !shouldRollback then
        world
    else
        syncSnapshot =
            when List.findFirst world.snapshots \snap -> snap.tick == world.syncTick is
                Ok snap -> snap
                Err NotFound ->
                    crashInfo = showCrashInfo world
                    crash "sync tick not present in snapshots; crashInfo: $(crashInfo)"

        restoredToSync =
            { world &
                tick: world.syncTick,
                localPlayer: syncSnapshot.localPlayer,
                remotePlayer: syncSnapshot.remotePlayer,
            }

        rollForwardRange = (world.syncTick + 1, world.tick) # inclusive
        rollForwardFromSyncTick restoredToSync { rollForwardRange, input }

rollForwardFromSyncTick : World, { rollForwardRange : (U64, U64), input : Input } -> World
rollForwardFromSyncTick = \world, { rollForwardRange: (start, end), input } ->
    rollForwardTicks =
        when Num.compare start end is
            LT -> List.range { start: At start, end: At end }
            GT -> []
            EQ -> [start]

    # touch up the snapshots to have their 'predictions' match what happened
    fixedWorld : World
    fixedWorld =
        snapshots : List Snapshot
        snapshots = List.walk world.remoteInputTicks [] \keptSnaps, inputTick ->
            when List.findFirst world.snapshots \s -> s.tick == inputTick.tick is
                # they're ahead of us and we haven't mispredicted yet
                Err NotFound -> keptSnaps
                # fix our old prediction
                Ok snap ->
                    fixedSnap = { snap & predictedInput: inputTick.input }
                    List.append keptSnaps fixedSnap
        { world & snapshots }

    # simulate every tick between syncTick and the present to catch up
    List.walk rollForwardTicks fixedWorld \w, tick ->
        localInput : Input
        localInput =
            # TODO keep local inputs separate from snapshots, and update them at start of frame
            if tick == world.tick then
                input
            else
                # NOTE take care to distinguish between world and w here
                # TODO use better names
                when List.findFirst world.snapshots \snap -> snap.tick == tick is
                    Ok snap -> snap.localInput
                    Err NotFound ->
                        crashInfo = showCrashInfo world
                        notFoundTick = Inspect.toStr tick
                        displayRange = "($(Inspect.toStr start), $(Inspect.toStr end))"
                        crash "snapshot not found in roll forward: notFoundTick: $(notFoundTick) rollForwardRange: $(displayRange), crashInfo: $(crashInfo)"

        tickOnce w localInput

showCrashInfo : World -> Str
showCrashInfo = \w ->
    remoteInputTicksRange =
        first = List.first w.remoteInputTicks |> Result.map \it -> it.tick
        last = List.last w.remoteInputTicks |> Result.map \it -> it.tick
        (first, last)

    snapshotsRange =
        first = List.first w.snapshots |> Result.map \snap -> snap.tick
        last = List.last w.snapshots |> Result.map \snap -> snap.tick
        (first, last)

    crashInfo = {
        tick: w.tick,
        remoteTick: w.remoteTick,
        syncTick: w.syncTick,
        localPos: w.localPlayer.pos,
        remotePos: w.remotePlayer.pos,
        remoteInputTicksRange,
        snapshotsRange,
    }

    Inspect.toStr crashInfo
