module [
    World,
    LocalPlayer,
    RemotePlayer,
    AnimatedSprite,
    FrameMessage,
    PeerMessage,
    FrameState,
    Intent,
    Facing,
    frameTicks,
    init,
    playerFacing,
    playerStart,
    roundVec,
    showCrashInfo,
    lastLocalInput,
    lastRemoteInput,
    InputTick,
]

# TODO
# 1. write local inputTicks to buffer
# 2. input delay for both local and remote
# 3. send overlapping HISTORIES of inputs?

# TODO later
# use ring buffers

import rr.RocRay exposing [Vector2]
import rr.Network exposing [UUID]

# import json.Json

import Resolution exposing [width, height]
import Pixel exposing [PixelVec]
import Input exposing [Input]

## The current game state and rollback metadata
World : {
    ## the player on the machine we're running on
    localPlayer : LocalPlayer,
    ## the player on a remote machine
    remotePlayer : RemotePlayer,

    ## the unspent milliseconds remaining after the last tick (or frame)
    remainingMillis : U64,

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

    ## whether we're blocked on remote input and for how long
    blocked : [Unblocked, BlockedFor U64],
}

InputTick : { tick : U64, input : Input }

lastLocalInput : World -> Result InputTick [ListWasEmpty]
lastLocalInput = \{ snapshots } ->
    snapshots
    |> List.last
    |> Result.map \snap -> { tick: snap.tick, input: snap.localInput }

lastRemoteInput : World -> Result InputTick [ListWasEmpty]
lastRemoteInput = \{ remoteInputTicks } ->
    List.last remoteInputTicks

## A previous game state
Snapshot : {
    tick : U64,
    localPlayer : LocalPlayer,
    remotePlayer : RemotePlayer,
    predictedInput : Input,
    localInput : Input,
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

millisPerTick : U64
millisPerTick = 1000 // 120

maxRollbackTicks : I64
maxRollbackTicks = 6

tickAdvantageLimit : I64
tickAdvantageLimit = 6

initialAnimation : AnimatedSprite
initialAnimation = { frame: 0, frameRate: 10, nextAnimationTick: 0 }

playerStart : LocalPlayer
playerStart =
    x = Pixel.fromParts { pixels: (width // 2) }
    y = Pixel.fromParts { pixels: (height // 2) }

    {
        pos: { x, y },
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
        predictedInput: Input.blank,
        localInput: Input.blank,
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
        range = List.range { start: At msg.firstTick, end: At msg.lastTick }
        List.map range \tick -> { tick: Num.toU64 tick, input: msg.input }

FrameState : {
    input : Input,
    deltaMillis : U64,
    inbox : List PeerMessage,
}

frameTicks : World, FrameState -> (World, Result FrameMessage [Blocking])
frameTicks = \oldWorld, { input, deltaMillis, inbox } ->
    rollbackDone =
        oldWorld
        |> addRemoteInputs inbox
        |> updateRemoteTick
        |> updateSyncTick
        |> rollbackIfNecessary

    firstTick = rollbackDone.tick |> Num.toI64

    newWorld =
        if timeSynced rollbackDone then
            rollbackDone
            |> normalUpdate { input, deltaMillis }
            |> &blocked Unblocked
        else
            # Block on remote updates
            blocked =
                when rollbackDone.blocked is
                    BlockedFor frames -> BlockedFor (frames + 1)
                    Unblocked -> BlockedFor 1

            { rollbackDone & blocked }

    lastTick = newWorld.tick |> Num.toI64
    tickAdvantage = Num.toI64 newWorld.tick - Num.toI64 newWorld.remoteTick

    outgoingMessage : Result FrameMessage [Blocking]
    outgoingMessage =
        when newWorld.blocked is
            Unblocked -> Ok { firstTick, lastTick, tickAdvantage, input }
            BlockedFor _ -> Err Blocking

    # cleaning snapshots like this caused problems for some reason
    # newWorld.snapshots
    # |> List.dropIf \snap -> snap.tick < newWorld.syncTick

    (newWorld, outgoingMessage)

addRemoteInputs : World, List PeerMessage -> World
addRemoteInputs = \world, inbox ->
    remoteInputs =
        newMessages = List.map inbox \peerMessage -> peerMessage.message

        world.remoteInputs
        |> List.concat newMessages
        |> cleanAndSortInputs { syncTick: world.syncTick }

    remoteInputTicks = frameMessagesToTicks remoteInputs

    { world & remoteInputs, remoteInputTicks }

## use as many physics ticks as the frame duration allows
normalUpdate : World, { input : Input, deltaMillis : U64 } -> World
normalUpdate = \world, { input, deltaMillis } ->
    useAllRemainingTime
        { world & remainingMillis: world.remainingMillis + deltaMillis }
        input

useAllRemainingTime : World, Input -> World
useAllRemainingTime = \world, input ->
    if world.remainingMillis < millisPerTick then
        world
    else
        tickedWorld = tickOnce world { input }
        useAllRemainingTime tickedWorld input

cleanAndSortInputs : List FrameMessage, { syncTick : U64 } -> List FrameMessage
cleanAndSortInputs = \history, { syncTick } ->
    sorted = List.sortWith history \left, right ->
        Num.compare left.firstTick right.firstTick
    sortedUnique = List.walk sorted [] \lst, fresh ->
        isMergeable = \lastMessage ->
            contiguous = lastMessage.lastTick == (fresh.firstTick - 1)
            equal = lastMessage.input == fresh.input
            contiguous && equal

        when List.last lst is
            # same start tick
            Ok last if last.firstTick == fresh.firstTick ->
                # they're blocking or they rolled back;
                # replace their input with the latest
                lst |> List.dropLast 1 |> List.append fresh

            # contiguous & mergeable
            Ok last if isMergeable last ->
                merged = { last & lastTick: fresh.lastTick }
                lastIndex = List.len lst - 1
                List.set lst lastIndex merged

            _ -> List.append lst fresh

    keptLast = List.last sortedUnique
    cleaned =
        List.keepOks sortedUnique \msg ->
            if msg.lastTick < Num.toI64 syncTick then Err TooOld else Ok msg

    when (cleaned, keptLast) is
        ([], Ok lst) -> [lst]
        ([], Err _) -> []
        (cleanHistory, _) -> cleanHistory

# pre-rollback network bookkeeping
updateRemoteTick : World -> World
updateRemoteTick = \world ->
    # NOTE: this depends on the remote inputs update before this

    (remoteTick, remoteTickAdvantage) =
        world.remoteInputs
        |> List.last
        |> Result.map \{ lastTick, tickAdvantage } -> (Num.toU64 lastTick, tickAdvantage)
        |> Result.withDefault (0, 0)

    { world & remoteTick, remoteTickAdvantage }

roundVec : Vector2 -> { x : I64, y : I64 }
roundVec = \{ x, y } -> {
    x: x |> Num.round |> Num.toI64,
    y: y |> Num.round |> Num.toI64,
}

## execute a single simulation tick
tickOnce : World, { input : Input } -> World
tickOnce = \world, { input } ->
    tick = world.tick + 1
    animationTimestamp = world.tick * millisPerTick
    remainingMillis = world.remainingMillis - millisPerTick

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
                    Err _ ->
                        # TODO inline expect
                        if tick >= 1 then
                            crash "defaulting to allUp when there should be remoteInputTicks"
                        else
                            Input.blank

    remotePlayer =
        oldRemotePlayer = world.remotePlayer
        animation = updateAnimation oldRemotePlayer.animation animationTimestamp
        intent = inputToIntent predictedInput (playerFacing oldRemotePlayer)
        movePlayer { oldRemotePlayer & animation, intent } intent

    snapshots =
        newSnapshot : Snapshot
        newSnapshot = { localInput: input, tick, localPlayer, remotePlayer, predictedInput }
        oldSnapshots = world.snapshots |> List.dropIf \snap -> snap.tick == tick
        List.append oldSnapshots newSnapshot

    { world &
        localPlayer,
        remotePlayer,
        remainingMillis,
        tick,
        snapshots,
    }

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

## true if we're in sync enough with remote player to continue updates
timeSynced : World -> Bool
timeSynced = \{ tick, remoteTick, remoteTickAdvantage } ->
    localTickAdvantage = Num.toI64 tick - Num.toI64 remoteTick
    tickAdvantageDifference = localTickAdvantage - remoteTickAdvantage
    localTickAdvantage < maxRollbackTicks && tickAdvantageDifference <= tickAdvantageLimit

updateSyncTick : World -> World
updateSyncTick = \world ->
    checkUpTo = Num.min world.tick world.remoteTick

    beforeMisprediction : Result U64 [NotFound]
    beforeMisprediction =
        findMisprediction world
        |> Result.map (\mispredictedTick -> mispredictedTick - 1)

    beforeInputGap : Result U64 [NotFound]
    beforeInputGap = findRemoteInputGap world

    syncTick =
        when (beforeMisprediction, beforeInputGap) is
            (Ok beforeMiss, Ok beforeGap) -> Num.min beforeMiss beforeGap
            (Err NotFound, Ok beforeGap) -> beforeGap
            (Ok beforeMiss, Err NotFound) -> beforeMiss
            (Err NotFound, Err NotFound) -> checkUpTo

    { world & syncTick }

findRemoteInputGap : { remoteInputTicks : List InputTick }w -> Result U64 [NotFound]
findRemoteInputGap = \{ remoteInputTicks } ->
    gap =
        List.walkUntil remoteInputTicks Start \state, inputTick ->
            when state is
                Start -> Continue (Contiguous inputTick)
                Contiguous previous ->
                    if inputTick.tick == previous.tick + 1 then
                        Continue (Contiguous inputTick)
                    else
                        Break (Gap previous)

                Gap _ -> crash "unreachable"
    when gap is
        Gap previous -> Ok previous.tick
        _ -> Err NotFound

expect
    remoteInputTicks = [
        { tick: 1, input: Input.blank },
        { tick: 2, input: Input.blank },
        { tick: 3, input: Input.blank },
        { tick: 5, input: Input.blank },
        { tick: 7, input: Input.blank },
    ]

    result = findRemoteInputGap { remoteInputTicks }

    result == Ok 3

expect
    remoteInputTicks = [
        { tick: 1, input: Input.blank },
        { tick: 2, input: Input.blank },
        { tick: 3, input: Input.blank },
    ]

    result = findRemoteInputGap { remoteInputTicks }

    result == Err NotFound

findMisprediction : World -> Result U64 [NotFound]
findMisprediction = \{ snapshots, remoteInputs } ->
    # TODO should this use inputTicks instead?
    findMatch : Snapshot -> Result FrameMessage [NotFound]
    findMatch = \snapshot ->
        List.findFirst remoteInputs \msg ->
            snapshotTick = Num.toI64 snapshot.tick
            snapshotTick >= msg.firstTick && snapshotTick < msg.lastTick

    misprediction : Result Snapshot [NotFound]
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
                Err NotFound ->
                    crashInfo = showCrashInfo world
                    crash "sync tick not present in snapshots; crashInfo: $(crashInfo)"

        restoredToSync =
            { world &
                tick: world.syncTick,
                localPlayer: syncSnapshot.localPlayer,
                remotePlayer: syncSnapshot.remotePlayer,
            }

        rollForwardRange = (world.syncTick, world.tick - 1) # inclusive

        # when rollForwardRange is
        #     (start, end) if start > end ->
        #         crashInfo = showCrashInfo world
        #         crash "end before start in roll forward: $(Inspect.toStr rollForwardRange), $(crashInfo)"
        #     (_start, _end) -> {}

        rollForwardFromSyncTick restoredToSync { rollForwardRange }

rollForwardFromSyncTick : World, { rollForwardRange : (U64, U64) } -> World
rollForwardFromSyncTick = \wrongFutureWorld, { rollForwardRange: (start, end) } ->
    rollForwardTicks = List.range { start: At start, end: At end }

    # touch up the snapshots to have their 'predictions' match what happened
    fixedWorld : World
    fixedWorld =
        snapshots : List Snapshot
        snapshots = List.map wrongFutureWorld.snapshots \questionableSnap ->
            when List.findFirst wrongFutureWorld.remoteInputTicks \it -> it.tick == questionableSnap.tick is
                # we're ahead of them; our prediction is fake but not wrong yet
                Err NotFound -> questionableSnap
                # we found an actual input to overwrite out prediction with
                # overwrite our prediction with whatever they actually did
                Ok inputTick -> { questionableSnap & predictedInput: inputTick.input }

        lastRemoteInputTick =
            when List.last wrongFutureWorld.remoteInputTicks is
                Ok last -> last.tick
                Err ListWasEmpty ->
                    crashInfo = showCrashInfo wrongFutureWorld
                    crash "no last input tick during roll forward: $(crashInfo)"

        { wrongFutureWorld & snapshots, remoteTick: lastRemoteInputTick, syncTick: lastRemoteInputTick }

    remainingMillisBeforeRollForward = fixedWorld.remainingMillis
    rollForwardWorld = { fixedWorld & remainingMillis: Num.maxU64 }

    # simulate every tick between syncTick and the present to catch up
    rolledForwardWorld =
        List.walk rollForwardTicks rollForwardWorld \steppingWorld, tick ->
            localInput : Input
            localInput =
                when List.findFirst rollForwardWorld.snapshots \snap -> snap.tick == tick is
                    Ok snap -> snap.localInput
                    Err NotFound ->
                        crashInfo = showCrashInfo rollForwardWorld
                        notFoundTick = Inspect.toStr tick
                        displayRange =
                            "($(Inspect.toStr start), $(Inspect.toStr end))"
                        crash "snapshot not found in roll forward: notFoundTick: $(notFoundTick) rollForwardRange: $(displayRange), crashInfo: $(crashInfo)"

            tickOnce steppingWorld { input: localInput }

    { rolledForwardWorld & remainingMillis: remainingMillisBeforeRollForward }

showCrashInfo : World -> Str
showCrashInfo = \world ->
    remoteInputTicksRange =
        first = List.first world.remoteInputTicks |> Result.map \it -> it.tick
        last = List.last world.remoteInputTicks |> Result.map \it -> it.tick
        (first, last)

    snapshotsRange =
        first = List.first world.snapshots |> Result.map \snap -> snap.tick
        last = List.last world.snapshots |> Result.map \snap -> snap.tick
        (first, last)

    crashInfo = {
        tick: world.tick,
        remoteTick: world.remoteTick,
        syncTick: world.syncTick,
        localPos: world.localPlayer.pos,
        remotePos: world.remotePlayer.pos,
        remoteInputTicksRange,
        snapshotsRange,
    }

    Inspect.toStr crashInfo

expect
    theirPositions = (theirStart.localPlayer.pos, theirStart.remotePlayer.pos)
    ourPositions = (ourStart.remotePlayer.pos, ourStart.localPlayer.pos)

    # Worlds are equal after init
    ourPositions == theirPositions

# this causes a compiler crash at crates/repl_eval/src/eval.rs:1444
# expect
#     (ourFirstFrame, ourFirstOutgoing) = frameTicks ourStart {
#         input: { Input.blank & up: Down },
#         deltaMillis: millisPerTick,
#         inbox: [],
#     }
#     ourFirstMessage : FrameMessage
#     ourFirstMessage =
#         when ourFirstOutgoing is
#             Ok message -> message
#             Err Blocking -> crash "block in test"

#     (theirFirstFrame, theirFirstOutgoing) = frameTicks theirStart {
#         input: { Input.blank & down: Down },
#         deltaMillis: millisPerTick,
#         inbox: [{ id: ourId, message: ourFirstMessage }],
#     }
#     theirFirstMessage : FrameMessage
#     theirFirstMessage =
#         when theirFirstOutgoing is
#             Ok message -> message
#             Err Blocking -> crash "block in test"

#     (ourSecondFrame, _) = frameTicks ourFirstFrame {
#         input: Input.blank,
#         deltaMillis: millisPerTick,
#         inbox: [{ id: theirId, message: theirFirstMessage }],
#     }

#     theirPositions : (PixelVec, PixelVec)
#     theirPositions = (theirFirstFrame.localPlayer.pos, theirFirstFrame.remotePlayer.pos)

#     ourPositions : (PixelVec, PixelVec)
#     ourPositions = (ourSecondFrame.remotePlayer.pos, ourSecondFrame.localPlayer.pos)

#     theirPositions == ourPositions

# Test Fixtures

ourId = Network.fromU64Pair { upper: 0, lower: 0 }
theirId = Network.fromU64Pair { upper: 0, lower: 1 }

waitingMessage : FrameMessage
waitingMessage = {
    firstTick: 0,
    lastTick: 0,
    tickAdvantage: 0,
    input: { up: Up, down: Up, left: Up, right: Up },
}

ourStart : World
ourStart = init { firstMessage: { id: theirId, message: waitingMessage } }

theirStart : World
theirStart = init { firstMessage: { id: ourId, message: waitingMessage } }
