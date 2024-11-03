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
    writableHistory,
]

# TODO
# add input delay - write local inputTicks to buffer
# use ring buffers
# send overlapping histories of inputs to handle packet loss
# recover from desyncs - request-response?
#   maybe just expose to the app/user and make it game's problem?
# track network event history
# make rollback stuff configurable (including going full delay-based)

import rr.RocRay exposing [Vector2]
import rr.Network exposing [UUID]

import json.Json

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
    blocked : [Unblocked, Skipped, BlockedFor U64],
    rollbackLog : List RollbackEvent,
}

RollbackEvent : {
    syncTick : U64,
    rollForwardRange : (U64, U64),
}

InputTick : { tick : U64, input : Input }

lastLocalInput : World -> Result InputTick [ListWasEmpty]
lastLocalInput = \{ snapshots } ->
    snapshots
    |> List.last
    |> Result.map \snap -> { tick: snap.tick, input: snap.localInput }

lastRemoteInput : World -> Result InputTick [NotFound]
lastRemoteInput = \{ syncTick, snapshots } ->
    # TODO remove these?
    snapshots
    |> List.findLast \snap -> snap.tick == syncTick
    |> Result.map \snap -> { tick: snap.tick, input: snap.predictedInput }

## A previous game state
Snapshot : {
    tick : U64,
    localPlayer : LocalPlayer,
    remotePlayer : RemotePlayer,
    # TODO this includes confirmed inputs;
    # rename it or change the type
    predictedInput : Input,
    localInput : Input,
    checksum : I64,
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
    ## the first simulated tick
    firstTick : I64,
    ## the last simulated tick, inclusive
    lastTick : I64,
    tickAdvantage : I64,
    input : Input,
    checksum : I64,
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
        checksum: makeChecksum { localPlayer, remotePlayer },
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
        rollbackLog: [],
    }

frameMessagesToTicks : List FrameMessage -> List InputTick
frameMessagesToTicks = \messages ->
    messages
    |> List.joinMap \msg ->
        range = List.range { start: At msg.firstTick, end: At msg.lastTick }
        List.map range \tick -> { tick: Num.toU64 tick, input: msg.input }
    |> List.walk [] \kept, inputTick ->
        when List.last kept is
            # keep only the last of a run of inputs for the same tick
            # FIXME this shouldn't happen so regularly
            # but it was happening almost every frame
            # TODO retest this with the outgoing message lastTick change
            Ok last if last.tick == inputTick.tick ->
                lastIndex = List.len kept - 1
                List.set kept lastIndex inputTick

            _ ->
                List.append kept inputTick

expect
    leftDown : Input
    leftDown = { Input.blank & left: Down }

    inputTicks = frameMessagesToTicks [
        {
            firstTick: 3,
            lastTick: 4,
            tickAdvantage: 0,
            input: Input.blank,
            checksum: 0,
        },
        {
            firstTick: 5,
            lastTick: 6,
            tickAdvantage: 0,
            input: leftDown,
            checksum: 0,
        },
    ]

    expected = [
        { tick: 3, input: Input.blank },
        { tick: 4, input: Input.blank },
        { tick: 5, input: leftDown },
        { tick: 6, input: leftDown },
    ]

    inputTicks == expected

expect
    leftDown : Input
    leftDown = { Input.blank & left: Down }

    inputTicks = frameMessagesToTicks [
        {
            firstTick: 0,
            lastTick: 1,
            tickAdvantage: 0,
            input: Input.blank,
            checksum: 0,
        },
        {
            firstTick: 1,
            lastTick: 2,
            tickAdvantage: 0,
            input: leftDown,
            checksum: 0,
        },
    ]

    expected = [
        { tick: 0, input: Input.blank },
        { tick: 1, input: leftDown },
        { tick: 2, input: leftDown },
    ]

    inputTicks == expected

FrameState : {
    input : Input,
    deltaMillis : U64,
    inbox : List PeerMessage,
}

frameTicks : World, FrameState -> (World, Result FrameMessage _)
frameTicks = \oldWorld, { input, deltaMillis, inbox } ->
    rollbackDone =
        oldWorld
        |> addRemoteInputs inbox
        |> updateRemoteTick
        |> updateSyncTick
        |> rollbackIfNecessary

    newWorld =
        if timeSynced rollbackDone then
            (updatedWorld, ticksTicked) = normalUpdate rollbackDone { input, deltaMillis }
            blocked = if ticksTicked == 0 then Skipped else Unblocked
            { updatedWorld & blocked }
        else
            # Block on remote updates
            blocked =
                when rollbackDone.blocked is
                    BlockedFor frames -> BlockedFor (frames + 1)
                    Unblocked | Skipped -> BlockedFor 1

            { rollbackDone & blocked }

    # TODO get these values from normalUpdate in a reliable way
    firstTick = rollbackDone.tick + 1 |> Num.toI64
    lastTick = newWorld.tick |> Num.toI64
    tickAdvantage = Num.toI64 newWorld.tick - Num.toI64 newWorld.remoteTick

    checksum = makeChecksum newWorld

    outgoingMessage : Result FrameMessage [BlockedFor U64, Skipped]
    outgoingMessage =
        when newWorld.blocked is
            # blocking on remote input
            BlockedFor n -> Err (BlockedFor n)
            # not enough millis for a timestep;
            # not blocked but didn't do anything besides accumulate millis
            # TODO buffer these inputs? how to handle changes before execution?
            Skipped -> Err Skipped
            # executed at least one tick
            Unblocked ->
                # This eliminated (1) for sure
                # when List.last newWorld.snapshots is
                #     Ok snap ->
                #         if snap.localInput == input then
                #             {}
                #         else
                #             info = Inspect.toStr { firstTick, lastTick, input, checksum }
                #             crashInfo = showCrashInfo newWorld
                #             crash "sending input that wasn't written:\n$(info)\n$(crashInfo)"
                #     Err _ -> crash "unreachable"
                Ok { firstTick, lastTick, tickAdvantage, input, checksum }

    snapshots =
        # newWorld.snapshots # <- good for debugging a short session but will crash
        List.dropIf newWorld.snapshots \snap -> snap.tick < newWorld.syncTick

    ({ newWorld & snapshots }, outgoingMessage)

makeChecksum : { localPlayer : LocalPlayer, remotePlayer : RemotePlayer }w -> I64
makeChecksum = \world ->
    # TODO use a real checksum
    localX = Pixel.totalSubpixels world.localPlayer.pos.x
    localY = Pixel.totalSubpixels world.localPlayer.pos.y

    remoteX = Pixel.totalSubpixels world.remotePlayer.pos.x
    remoteY = Pixel.totalSubpixels world.remotePlayer.pos.y

    localX + 10 * localY + 100 * remoteX + 1000 * remoteY

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
normalUpdate : World, { input : Input, deltaMillis : U64 } -> (World, U64)
normalUpdate = \world, { input, deltaMillis } ->
    millisToUse = world.remainingMillis + deltaMillis
    useAllRemainingTime { world & remainingMillis: millisToUse } input 0

useAllRemainingTime : World, Input, U64 -> (World, U64)
useAllRemainingTime = \world, input, ticksTicked ->
    if world.remainingMillis < millisPerTick then
        (world, ticksTicked)
    else
        tickedWorld = tickOnce world { input }
        useAllRemainingTime tickedWorld input (ticksTicked + 1)

cleanAndSortInputs : List FrameMessage, { syncTick : U64 } -> List FrameMessage
cleanAndSortInputs = \history, { syncTick } ->
    sorted = List.sortWith history \left, right ->
        Num.compare left.firstTick right.firstTick
    sortedUnique = List.walk sorted [] \lst, fresh ->
        isMergeable = \lastMessage ->
            contiguous = lastMessage.lastTick == fresh.firstTick - 1
            equalInput = lastMessage.input == fresh.input
            contiguous && equalInput

        when List.last lst is
            # same start tick
            Ok last if last.firstTick == fresh.firstTick ->
                # they're blocking or they rolled back;
                # replace their input with the latest
                lst |> List.dropLast 1 |> List.append fresh

            # contiguous & mergeable
            # TODO is this a good idea?
            # it's useful for debugging, but kind of lies about metadata.
            # still useful, but only if you know it's happening
            # maybe rename the field?
            Ok last if isMergeable last ->
                merged = { last & lastTick: fresh.lastTick }
                lastIndex = List.len lst - 1
                List.set lst lastIndex merged

            # TODO check for other overlaps?
            _ -> List.append lst fresh

    keptLast = List.last sortedUnique
    cleaned =
        List.keepOks sortedUnique \msg ->
            if msg.lastTick < Num.toI64 syncTick then Err TooOld else Ok msg

    when (cleaned, keptLast) is
        ([], Ok lst) -> [lst]
        ([], Err _) -> []
        (cleanHistory, _) -> cleanHistory

expect
    leftDown : Input
    leftDown = { Input.blank & left: Down }

    messages : List FrameMessage
    messages = [
        {
            firstTick: 10,
            lastTick: 11,
            tickAdvantage: 0,
            input: Input.blank,
            checksum: 0,
        },
        {
            firstTick: 12,
            lastTick: 13,
            tickAdvantage: 0,
            input: leftDown,
            checksum: 0,
        },
    ]

    cleans = cleanAndSortInputs messages { syncTick: 10 }

    expected : List FrameMessage
    expected = [
        {
            firstTick: 10,
            lastTick: 11,
            tickAdvantage: 0,
            input: Input.blank,
            checksum: 0,
        },
        {
            firstTick: 12,
            lastTick: 13,
            tickAdvantage: 0,
            input: leftDown,
            checksum: 0,
        },
    ]

    cleans == expected

expect
    leftDown : Input
    leftDown = { Input.blank & left: Down }

    messages : List FrameMessage
    messages = [
        {
            firstTick: 10,
            lastTick: 11,
            tickAdvantage: 0,
            input: Input.blank,
            checksum: 0,
        },
        {
            firstTick: 11,
            lastTick: 13,
            tickAdvantage: 0,
            input: leftDown,
            checksum: 0,
        },
    ]

    cleans = cleanAndSortInputs messages { syncTick: 10 }

    # FIXME the code treats this as an overlap
    # this is not the cause of the current early prediction bug (11/3)
    expected : List FrameMessage
    expected = [
        {
            firstTick: 10,
            lastTick: 11,
            tickAdvantage: 0,
            input: Input.blank,
            checksum: 0,
        },
        {
            firstTick: 11,
            lastTick: 13,
            tickAdvantage: 0,
            input: leftDown,
            checksum: 0,
        },
    ]

    cleans == expected

expect
    leftDown : Input
    leftDown = { Input.blank & left: Down }

    messages : List FrameMessage
    messages = [
        {
            firstTick: 10,
            lastTick: 13,
            tickAdvantage: 0,
            input: Input.blank,
            checksum: 0,
        },
        {
            firstTick: 11,
            lastTick: 15,
            tickAdvantage: 0,
            input: leftDown,
            checksum: 0,
        },
    ]

    cleans = cleanAndSortInputs messages { syncTick: 10 }

    # FIXME overlap should be prevented or normalized
    # this is not the cause of the current early prediction bug (11/3)
    expected : List FrameMessage
    expected = [
        {
            firstTick: 10,
            lastTick: 13,
            tickAdvantage: 0,
            input: Input.blank,
            checksum: 0,
        },
        {
            firstTick: 11,
            lastTick: 15,
            tickAdvantage: 0,
            input: leftDown,
            checksum: 0,
        },
    ]

    cleans == expected

# pre-rollback network bookkeeping
# NOTE: this depends on the remote inputs update before this
updateRemoteTick : World -> World
updateRemoteTick = \world ->
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
tickOnce = \world, { input: newInput } ->
    tick = world.tick + 1
    animationTimestamp = world.tick * millisPerTick
    remainingMillis = world.remainingMillis - millisPerTick

    localInput : Input
    localInput =
        when List.findLast world.snapshots \snap -> snap.tick == tick is
            Ok snap -> snap.localInput
            Err NotFound -> newInput

    localPlayer =
        oldPlayer = world.localPlayer
        animation = updateAnimation oldPlayer.animation animationTimestamp
        intent = inputToIntent localInput (playerFacing oldPlayer)
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
                when (List.last world.remoteInputTicks, tick) is
                    # predict the last thing they did
                    (Ok last, _) -> last.input
                    (Err _, 0) -> Input.blank
                    (Err _, _) -> crash "no remoteInputTicks after first tick"

    remotePlayer =
        oldRemotePlayer = world.remotePlayer
        animation = updateAnimation oldRemotePlayer.animation animationTimestamp
        intent = inputToIntent predictedInput (playerFacing oldRemotePlayer)
        movePlayer { oldRemotePlayer & animation, intent } intent

    snapshots =
        checksum = makeChecksum { localPlayer, remotePlayer }

        newSnapshot : Snapshot
        newSnapshot = { localInput, tick, localPlayer, remotePlayer, predictedInput, checksum }

        # FIXME is it wrong to overwrite this?
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
    checkRange = (world.syncTick + 1, checkUpTo)

    beforeMisprediction : Result U64 [NotFound]
    beforeMisprediction =
        findMisprediction world checkRange
        |> Result.map (\mispredictedTick -> mispredictedTick - 1)

    syncTick =
        when beforeMisprediction is
            Ok beforeMiss -> beforeMiss
            Err NotFound -> checkUpTo

    # syncTick should not move backwards
    expect world.syncTick <= syncTick

    { world & syncTick }

findMisprediction : World, (U64, U64) -> Result U64 [NotFound]
findMisprediction = \{ snapshots, remoteInputTicks }, (start, end) ->
    findMatch : Snapshot -> Result InputTick [NotFound]
    findMatch = \snapshot ->
        remoteInputTicks
        |> List.findFirst \inputTick -> inputTick.tick == snapshot.tick

    misprediction : Result Snapshot [NotFound]
    misprediction =
        snapshots
        |> List.keepIf \snapshot -> snapshot.tick >= start && snapshot.tick <= end
        |> List.findFirst \snapshot ->
            when findMatch snapshot is
                Ok match -> match.input != snapshot.predictedInput
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
                    crash "sync tick not present in snapshots: $(crashInfo)"

        # TODO should this be syncTick + 1 on the left?
        rollForwardRange = (world.syncTick, world.tick - 1) # inclusive

        rollbackEvent : RollbackEvent
        rollbackEvent = { syncTick: world.syncTick, rollForwardRange }

        restoredToSync =
            { world &
                tick: world.syncTick,
                localPlayer: syncSnapshot.localPlayer,
                remotePlayer: syncSnapshot.remotePlayer,
                rollbackLog: List.append world.rollbackLog rollbackEvent,
            }

        rollForwardFromSyncTick restoredToSync { rollForwardRange }

rollForwardFromSyncTick : World, { rollForwardRange : (U64, U64) } -> World
rollForwardFromSyncTick = \wrongFutureWorld, { rollForwardRange: (start, end) } ->
    expect start <= end

    rollForwardTicks = List.range { start: At start, end: At end }

    # touch up the snapshots to have their 'predictions' match what happened
    fixedWorld : World
    fixedWorld =
        snapshots : List Snapshot
        snapshots = List.map wrongFutureWorld.snapshots \questionableSnap ->
            matchingInputTick = List.findFirst wrongFutureWorld.remoteInputTicks \inputTick ->
                inputTick.tick == questionableSnap.tick

            when matchingInputTick is
                # we're ahead of them; our prediction is fake but not wrong yet
                Err NotFound -> questionableSnap
                # we found an actual input to overwrite out prediction with
                # overwrite our prediction with whatever they actually did
                Ok inputTick -> { questionableSnap & predictedInput: inputTick.input }

        remoteTick =
            when List.last wrongFutureWorld.remoteInputTicks is
                Ok last -> last.tick
                Err ListWasEmpty ->
                    crashInfo = showCrashInfo wrongFutureWorld
                    crash "no last input tick during roll forward: $(crashInfo)"

        { wrongFutureWorld & snapshots, remoteTick, syncTick: remoteTick }

    remainingMillisBeforeRollForward = fixedWorld.remainingMillis
    rollForwardWorld = { fixedWorld & remainingMillis: Num.maxU64 }

    # simulate every tick between syncTick and the present to catch up
    rolledForwardWorld =
        List.walk rollForwardTicks rollForwardWorld \steppingWorld, tick ->
            # TODO will this be necessary if tickOnce just always works this way
            # yes, because the not found behavior is different
            # maybe tickonce could take a config with a variant for how to handle that case?
            localInput : Input
            localInput =
                when List.findLast rollForwardWorld.snapshots \snap -> snap.tick == tick is
                    Ok snap -> snap.localInput
                    Err NotFound ->
                        crashInfo = showCrashInfo rollForwardWorld
                        moreInfo = Inspect.toStr { notFoundTick: tick, rollForwardRange: (start, end) }
                        crash "snapshot not found in roll forward: $(moreInfo), $(crashInfo)"

            tickOnce steppingWorld { input: localInput }

    syncTick =
        Num.min rolledForwardWorld.tick rolledForwardWorld.remoteTick

    remoteChecksum =
        rolledForwardWorld.remoteInputs
        |> List.findLast \msg ->
            iSyncTick = syncTick |> Num.toI64
            msg.lastTick >= iSyncTick && msg.firstTick <= iSyncTick
        |> Result.map \msg -> msg.checksum
    localChecksum =
        rolledForwardWorld.snapshots
        |> List.findLast \snap -> snap.tick == syncTick
        |> Result.map \snap -> snap.checksum

    # when (localChecksum, remoteChecksum) is
    #     (Ok local, Ok remote) if local == remote -> {}
    #     (Ok local, Ok remote) ->
    #         history = writableHistory rolledForwardWorld
    #         crashInfo = showCrashInfo rolledForwardWorld
    #         frameMessages = rolledForwardWorld.remoteInputs
    #         info = Inspect.toStr { syncTick, checksums: (local, remote), frameMessages }
    #         # FIXME come up with some assertion for this
    #         # TODO is this ok? we could be ahead of them
    #         crash "different checksums for sync tick: $(info),\n$(crashInfo),\nhistory:\n$(history)"
    #     (local, remote) ->
    #         history = writableHistory rolledForwardWorld
    #         crashInfo = showCrashInfo rolledForwardWorld
    #         checksums = Inspect.toStr (local, remote)
    #         crash "missing checksum for sync tick: $(checksums), $(crashInfo), history: \n$(history)"

    { rolledForwardWorld & remainingMillis: remainingMillisBeforeRollForward, syncTick }

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
        rollbackLog: world.rollbackLog,
        remoteInputTicksRange,
        snapshotsRange,
    }

    Inspect.toStr crashInfo

expect
    theirPositions = (theirStart.localPlayer.pos, theirStart.remotePlayer.pos)
    ourPositions = (ourStart.remotePlayer.pos, ourStart.localPlayer.pos)

    # Worlds are equal after init
    ourPositions == theirPositions

# Test Fixtures

ourId = Network.fromU64Pair { upper: 0, lower: 0 }
theirId = Network.fromU64Pair { upper: 0, lower: 1 }

waitingMessage : FrameMessage
waitingMessage = {
    firstTick: 0,
    lastTick: 0,
    tickAdvantage: 0,
    input: { up: Up, down: Up, left: Up, right: Up },
    checksum: -1,
}

ourStart : World
ourStart = init { firstMessage: { id: theirId, message: waitingMessage } }

theirStart : World
theirStart = init { firstMessage: { id: ourId, message: waitingMessage } }

writableHistory : World -> Str
writableHistory = \{ snapshots } ->
    writeInput : Input -> Str
    writeInput = \input ->
        up = if input.up == Down then Ok "Up" else Err Up
        down = if input.down == Down then Ok "Down" else Err Up
        left = if input.left == Down then Ok "Left" else Err Up
        right = if input.right == Down then Ok "Right" else Err Up

        [up, down, left, right]
        |> List.keepOks \res -> res
        |> Str.joinWith ", "
        |> \inputs -> "[$(inputs)]"

    writableSnapshot : Snapshot -> _
    writableSnapshot = \snap -> {
        tick: snap.tick,
        localInput: writeInput snap.localInput,
        predictedInput: writeInput snap.predictedInput,
    }

    toUtf8Unchecked = \bytes ->
        when Str.fromUtf8 bytes is
            Ok str -> str
            Err _ -> crash "toUtf8Unchecked"

    writeSnapshot : Snapshot -> Str
    writeSnapshot = \snap ->
        writable = writableSnapshot snap
        bytes = Encode.toBytes writable Json.utf8
        toUtf8Unchecked bytes

    snapshots
    |> List.map writeSnapshot
    |> Str.joinWith "\n"
