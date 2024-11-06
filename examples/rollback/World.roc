module [
    AnimatedSprite,
    Facing,
    FrameMessage,
    FrameContext,
    InputTick,
    Intent,
    LocalPlayer,
    PeerMessage,
    RemotePlayer,
    World,
    frameTicks,
    init,
    playerFacing,
    playerStart,
    roundVec,
    showCrashInfo,
    writableHistory,
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

import json.Json

import Resolution exposing [width, height]
import Pixel exposing [PixelVec]
import Input exposing [Input]

import Recording exposing [Recording]

## The current game state and rollback metadata
World : {
    state : GameState,

    ## the unspent milliseconds remaining after the last tick (or frame)
    remainingMillis : U64,

    ## the total number of simulation ticks so far
    tick : U64,
    ## the most recent tick received from the remote player
    remoteTick : U64,
    ## the last tick where we synchronized with the remote player
    syncTick : U64,
    syncTickSnapshot : Snapshot,
    ## the latest tick advantage received from the remote player
    remoteTickAdvantage : I64,
    snapshots : List Snapshot,
    remoteInputs : List FrameMessage,
    remoteInputTicks : List InputTick,
    localInputTicks : List InputTick,

    ## whether we're blocked on remote input and for how long
    blocked : [Advancing, Skipped, BlockedFor U64],
    rollbackLog : List RollbackEvent,
    # recording : Recording FakeGameState,
}

## the non-rollback game state
GameState : {
    ## the player on the machine we're running on
    localPlayer : LocalPlayer,
    ## the player on a remote machine
    remotePlayer : RemotePlayer,
}

RollbackEvent : {
    syncTick : U64,
    rollForwardRange : (U64, U64),
}

InputTick : { tick : U64, input : Input }

## A previous game state
Snapshot : {
    tick : U64,
    checksum : I64,
    predictedInput : Input,
    localInput : Input,
    state : GameState,
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
    ## how far ahead we are of our known remote inputs
    tickAdvantage : I64,
    ## our local input for this range being broadcast
    input : Input,
    ## our most recent syncTick
    syncTick : I64,
    ## the checksum for our most recent syncTick
    syncTickChecksum : I64,
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
        state: {
            localPlayer,
            remotePlayer,
        },
        predictedInput: Input.blank,
        localInput: Input.blank,
        checksum: makeChecksum { localPlayer, remotePlayer },
    }

    firstLocalInputTick : InputTick
    firstLocalInputTick = { tick: 0, input: Input.blank }

    config : Recording.Config FakeGameState
    config = {
        millisPerTick,
        maxRollbackTicks,
        tickAdvantageLimit,
        tick: fakeTick,
        checksum: fakeChecksum,
    }

    _recording : Recording FakeGameState
    _recording =
        Recording.start { firstMessage: message, state: {}, config }

    {
        state: {
            localPlayer,
            remotePlayer,
        },
        remainingMillis: 0,
        tick: 0,
        remoteTick: 0,
        syncTick: 0,
        syncTickSnapshot: initialSyncSnapshot,
        remoteTickAdvantage: 0,
        snapshots: [initialSyncSnapshot],
        remoteInputs,
        remoteInputTicks,
        localInputTicks: [firstLocalInputTick],
        blocked: Advancing,
        rollbackLog: [],
        # recording,
    }

FakeGameState : {}

fakeChecksum : FakeGameState -> I64
fakeChecksum = \_state -> 0

fakeTick : FakeGameState, Recording.TickContext -> FakeGameState
fakeTick = \state, _ -> state

frameMessagesToTicks : List FrameMessage -> List InputTick
frameMessagesToTicks = \messages ->
    List.joinMap messages \msg ->
        range = List.range { start: At msg.firstTick, end: At msg.lastTick }
        List.map range \tick -> { tick: Num.toU64 tick, input: msg.input }

expect
    leftDown : Input
    leftDown = { Input.blank & left: Down }

    inputTicks = frameMessagesToTicks [
        {
            firstTick: 3,
            lastTick: 4,
            tickAdvantage: 0,
            input: Input.blank,
            syncTick: 0,
            syncTickChecksum: 0,
        },
        {
            firstTick: 5,
            lastTick: 6,
            tickAdvantage: 0,
            input: leftDown,
            syncTick: 0,
            syncTickChecksum: 0,
        },
    ]

    expected = [
        { tick: 3, input: Input.blank },
        { tick: 4, input: Input.blank },
        { tick: 5, input: leftDown },
        { tick: 6, input: leftDown },
    ]

    inputTicks == expected

FrameContext : {
    localInput : Input,
    deltaMillis : U64,
    inbox : List PeerMessage,
}

frameTicks : World, FrameContext -> (World, Result FrameMessage _)
frameTicks = \oldWorld, { localInput, deltaMillis, inbox } ->
    rollbackDone =
        oldWorld
        |> addRemoteInputs inbox
        |> updateRemoteTick
        |> updateSyncTick
        |> rollbackIfNecessary

    newWorld =
        if timeSynced rollbackDone then
            (updatedWorld, ticksTicked) =
                normalUpdate rollbackDone { localInput, deltaMillis }
            blocked = if ticksTicked == 0 then Skipped else Advancing
            { updatedWorld & blocked }
        else
            # Block on remote updates
            blocked =
                when rollbackDone.blocked is
                    BlockedFor frames -> BlockedFor (frames + 1)
                    Advancing | Skipped -> BlockedFor 1

            { rollbackDone & blocked }

    firstTick = rollbackDone.tick + 1 |> Num.toI64
    lastTick = newWorld.tick |> Num.toI64
    tickAdvantage = Num.toI64 newWorld.tick - Num.toI64 newWorld.remoteTick

    outgoingMessage : Result FrameMessage [BlockedFor U64, Skipped]
    outgoingMessage =
        when newWorld.blocked is
            # blocking on remote input
            BlockedFor n -> Err (BlockedFor n)
            # not enough millis for a timestep;
            # not blocked, but didn't do anything besides accumulate millis
            # TODO buffer these inputs? how to handle changes before execution?
            Skipped -> Err Skipped
            # executed at least one tick
            Advancing ->
                frameMessage : FrameMessage
                frameMessage = {
                    firstTick,
                    lastTick,
                    tickAdvantage,
                    input: localInput,
                    syncTick: Num.toI64 newWorld.syncTick,
                    syncTickChecksum: newWorld.syncTickSnapshot.checksum,
                }

                Ok frameMessage

    snapshots =
        # newWorld.snapshots # <- good for debugging a short session but will crash
        List.dropIf newWorld.snapshots \snap -> snap.tick < newWorld.syncTick

    ({ newWorld & snapshots }, outgoingMessage)

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
normalUpdate : World, { localInput : Input, deltaMillis : U64 } -> (World, U64)
normalUpdate = \initialWorld, { localInput, deltaMillis } ->
    millisToUse = initialWorld.remainingMillis + deltaMillis
    tickingWorld = { initialWorld & remainingMillis: millisToUse }
    useAllRemainingTime tickingWorld { localInput } 0

useAllRemainingTime : World, { localInput : Input }, U64 -> (World, U64)
useAllRemainingTime = \world, inputs, ticksTicked ->
    if world.remainingMillis < millisPerTick then
        (world, ticksTicked)
    else
        tickedWorld = tickOnce world inputs
        useAllRemainingTime tickedWorld inputs (ticksTicked + 1)

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
            Ok last if isMergeable last ->
                merged = { fresh & firstTick: last.firstTick }
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
            syncTick: 0,
            syncTickChecksum: 0,
        },
        {
            firstTick: 12,
            lastTick: 13,
            tickAdvantage: 0,
            input: leftDown,
            syncTick: 0,
            syncTickChecksum: 0,
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
            syncTick: 0,
            syncTickChecksum: 0,
        },
        {
            firstTick: 12,
            lastTick: 13,
            tickAdvantage: 0,
            input: leftDown,
            syncTick: 0,
            syncTickChecksum: 0,
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

predictRemoteInput : World, { tick : U64 } -> (Input, [Predicted, Confirmed])
predictRemoteInput = \world, { tick } ->
    receivedInput =
        world.remoteInputTicks
        |> List.findLast \inputTick -> inputTick.tick == tick
        |> Result.map \inputTick -> inputTick.input

    when receivedInput is
        # confirmed remote input
        Ok received -> (received, Confirmed)
        # must predict remote input
        Err NotFound ->
            when (List.last world.remoteInputTicks, tick) is
                # predict the last thing they did
                (Ok last, _) -> (last.input, Predicted)
                # predict idle on the first frame
                (Err _, 0) -> (Input.blank, Predicted)
                # crash if we incorrectly threw away their last input after the first frame
                (Err _, _) ->
                    crashInfo = showCrashInfo world
                    crash "predictRemoteInput: no remoteInputTicks after first tick:\n$(crashInfo)"

gameStateTick : GameState, Recording.TickContext -> GameState
gameStateTick = \state, { tick, localInput, remoteInput } ->
    # TODO should this be in tickContext?
    # it definitely shouldn't be here, it relies on config
    animationTimestamp = tick * millisPerTick

    localPlayer =
        oldPlayer = state.localPlayer
        animation = updateAnimation oldPlayer.animation animationTimestamp
        intent = inputToIntent localInput (playerFacing oldPlayer)
        movePlayer { oldPlayer & animation, intent } intent

    remotePlayer =
        oldRemotePlayer = state.remotePlayer
        animation = updateAnimation oldRemotePlayer.animation animationTimestamp
        intent = inputToIntent remoteInput (playerFacing oldRemotePlayer)
        movePlayer { oldRemotePlayer & animation, intent } intent

    { localPlayer, remotePlayer }

## execute a single simulation tick
tickOnce : World, { localInput : Input } -> World
tickOnce = \world, { localInput: newInput } ->
    tick = world.tick + 1
    timestampMillis = world.tick * millisPerTick
    remainingMillis = world.remainingMillis - millisPerTick

    (localInput, localInputIsNew) =
        # avoid overwriting inputs that have been published to other players
        when List.findLast world.localInputTicks \it -> it.tick == tick is
            Ok it -> (it.input, Bool.false)
            Err NotFound -> (newInput, Bool.true)

    (predictedInput, _predicted) = predictRemoteInput world { tick }

    state = gameStateTick world.state {
        tick,
        timestampMillis,
        localInput,
        remoteInput: predictedInput,
    }

    snapshots =
        checksum = makeChecksum state

        # NOTE:
        # We need to use our previously-sent localInput from above.
        # Changing our own recorded input would break our opponent's rollbacks.
        newSnapshot : Snapshot
        newSnapshot = { localInput, tick, predictedInput, checksum, state }

        oldSnapshots = world.snapshots |> List.dropIf \snap -> snap.tick == tick

        List.append oldSnapshots newSnapshot

    localInputTicks =
        if localInputIsNew then
            List.append world.localInputTicks { tick, input: localInput }
        else
            world.localInputTicks

    { world &
        state,
        remainingMillis,
        tick,
        snapshots,
        localInputTicks,
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
        Result.withDefault beforeMisprediction checkUpTo

    # syncTick should not move backwards
    expect world.syncTick <= syncTick

    syncTickSnapshot =
        when List.findLast world.snapshots \snap -> snap.tick == syncTick is
            Ok snap -> snap
            Err _ ->
                crashInfo = showCrashInfo world
                crash "snapshot not found for new sync tick: $(Inspect.toStr syncTick)\n$(crashInfo)"

    { world & syncTick, syncTickSnapshot }

findMisprediction : World, (U64, U64) -> Result U64 [NotFound]
findMisprediction = \{ snapshots, remoteInputTicks }, (start, end) ->
    findMatch : Snapshot -> Result InputTick [NotFound]
    findMatch = \snapshot ->
        List.findLast remoteInputTicks \inputTick ->
            inputTick.tick == snapshot.tick

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
        rollForwardRange = (world.syncTick, world.tick - 1) # inclusive

        rollbackEvent : RollbackEvent
        rollbackEvent = { syncTick: world.syncTick, rollForwardRange }

        restoredToSync =
            { world &
                tick: world.syncTick,
                state: world.syncTickSnapshot.state,
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
                Ok inputTick ->
                    { questionableSnap &
                        predictedInput: inputTick.input,
                    }

        remoteTick =
            when List.last wrongFutureWorld.remoteInputTicks is
                Ok last -> last.tick
                Err ListWasEmpty ->
                    crashInfo = showCrashInfo wrongFutureWorld
                    crash "no last input tick during roll forward: $(crashInfo)"

        lastSnapshotTick =
            when List.last snapshots is
                Ok snap -> snap.tick
                Err _ ->
                    crashInfo = showCrashInfo wrongFutureWorld
                    crash "no snapshots in roll forward fixup: $(crashInfo)"
        syncTick = Num.min remoteTick lastSnapshotTick
        syncTickSnapshot =
            when List.findLast snapshots \snap -> snap.tick == syncTick is
                Ok snap -> snap
                Err _ ->
                    crashInfo = showCrashInfo wrongFutureWorld
                    crash "snapshot not found for new sync tick in roll forward fixup: $(Inspect.toStr syncTick)\n$(crashInfo)"

        { wrongFutureWorld & snapshots, remoteTick, syncTick, syncTickSnapshot }

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
                when List.findLast rollForwardWorld.localInputTicks \it -> it.tick == tick is
                    Ok it -> it.input
                    Err NotFound ->
                        crashInfo = showCrashInfo rollForwardWorld
                        moreInfo = Inspect.toStr { notFoundTick: tick, rollForwardRange: (start, end) }
                        crash "local input not found in roll forward: $(moreInfo), $(crashInfo)"

            tickOnce steppingWorld { localInput }

    (remoteSyncTick, remoteSyncTickChecksum) =
        when List.last rolledForwardWorld.remoteInputs is
            Ok last -> (last.syncTick, last.syncTickChecksum)
            Err _ ->
                crashInfo = showCrashInfo rolledForwardWorld
                crash "no last remote message during roll forward:\n$(crashInfo)"

    localMatchingChecksum =
        matchingSnap =
            rolledForwardWorld.snapshots
            |> List.findLast \snap -> Num.toI64 snap.tick == remoteSyncTick
        when matchingSnap is
            Ok snap -> snap.checksum
            Err _ ->
                info = Inspect.toStr { remoteSyncTick }
                crashInfo = showCrashInfo rolledForwardWorld
                crash "no matching local snapshot for remote sync tick:$(info)\n$(crashInfo)"

    remainingMillis =
        if remoteSyncTickChecksum == localMatchingChecksum then
            # this is a weird reassignment to avoid the roc warning for a void statement
            remainingMillisBeforeRollForward
        else
            history = writableHistory rolledForwardWorld
            crashInfo = showCrashInfo rolledForwardWorld
            frameMessages = rolledForwardWorld.remoteInputs
            checksums = (remoteSyncTickChecksum, localMatchingChecksum)
            info = Inspect.toStr { remoteSyncTick, checksums, frameMessages }

            crash "different checksums for sync tick: $(info),\n$(crashInfo),\nhistory:\n$(history)"

    { rolledForwardWorld & remainingMillis }

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
        syncTickSnapshot: world.syncTickSnapshot,
        localPos: world.state.localPlayer.pos,
        remotePos: world.state.remotePlayer.pos,
        rollbackLog: world.rollbackLog,
        remoteInputTicksRange,
        snapshotsRange,
    }

    Inspect.toStr crashInfo

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

expect
    ourId = Network.fromU64Pair { upper: 0, lower: 0 }
    theirId = Network.fromU64Pair { upper: 0, lower: 1 }

    ourStart : World
    ourStart = init { firstMessage: { id: theirId, message: waitingMessage } }

    theirStart : World
    theirStart = init { firstMessage: { id: ourId, message: waitingMessage } }

    theirPositions = (theirStart.state.localPlayer.pos, theirStart.state.remotePlayer.pos)
    ourPositions = (ourStart.state.remotePlayer.pos, ourStart.state.localPlayer.pos)

    # Worlds are equal after init
    ourPositions == theirPositions

## Creates a multi-line json log of snapshotted inputs.
## This allows creating diffable input logs from multiple clients when debugging.
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

    inputSnapshot : Snapshot -> _
    inputSnapshot = \snap -> {
        tick: snap.tick,
        localInput: writeInput snap.localInput,
        predictedInput: writeInput snap.predictedInput,
    }

    positionSnapshot : Snapshot -> _
    positionSnapshot = \snap -> {
        tick: snap.tick,
        localPos: Inspect.toStr snap.state.localPlayer.pos,
        remotePos: Inspect.toStr snap.state.remotePlayer.pos,
    }

    toUtf8Unchecked = \bytes ->
        when Str.fromUtf8 bytes is
            Ok str -> str
            Err _ -> crash "toUtf8Unchecked"

    writeSnapshot : Snapshot -> Str
    writeSnapshot = \snap ->
        inputJson =
            snap
            |> inputSnapshot
            |> Encode.toBytes Json.utf8
            |> toUtf8Unchecked

        positionJson =
            snap
            |> positionSnapshot
            |> Encode.toBytes Json.utf8
            |> toUtf8Unchecked

        "$(inputJson)\n$(positionJson)"

    snapshots
    |> List.map writeSnapshot
    |> Str.joinWith "\n"
