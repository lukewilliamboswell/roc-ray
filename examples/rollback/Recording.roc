module [
    Recording,
    StartRecording,
    Config,
    start,
    advance,
    FrameContext,
    TickContext,
    PeerMessage,
    FrameMessage,
    showCrashInfo,
    writableHistory,
    currentState,
]

import rr.Network exposing [UUID]

import json.Json

import Input exposing [Input]

Recording state := Recorded state

currentState : Recording state -> state
currentState = \@Recording recording ->
    recording.state

Config state : {
    ## the milliseconds per simulation frame
    ## ie, 1000 / the frame rate
    millisPerTick : U64,
    ## the configured max rollback;
    ## a client with tick advantage >= this will block
    maxRollbackTicks : I64,
    ## the configured frame advantage limit;
    ## a client further ahead of their opponent than this will block
    tickAdvantageLimit : I64,

    ## TODO docs
    tick : state, TickContext -> state,
    checksum : state -> I64,
}

Recorded state : {
    config : Config,

    ## the live game state this frame
    state : state,
    ## the unspent milliseconds remaining after the last tick (or frame)
    remainingMillis : U64,

    ## the total number of simulation ticks so far
    tick : U64,
    ## the most recent tick received from the remote player
    remoteTick : U64,
    ## the last tick where we synchronized with the remote player
    syncTick : U64,
    ## the snapshot for our syncTick
    syncTickSnapshot : Snapshot state,
    ## the latest tick advantage received from the remote player
    remoteTickAdvantage : I64,

    ## the recent history of received network messages (since syncTick)
    remoteMessages : List FrameMessage,
    ## the recent history of remote player inputs (since syncTick)
    ## this is a smaller duplicate of information in remoteMessaages
    remoteInputTicks : List InputTick,
    ## the recent history of snapshots (since syncTick)
    snapshots : List (Snapshot state),
    ## the recent history of local player inputs (since syncTick)
    ## this is a smaller duplicate of information in snapshots
    localInputTicks : List InputTick,

    # TODO rename and docs
    blocked : [Advancing, Skipped, BlockedFor U64],

    ## a record of rollback events for debugging purposes
    rollbackLog : List RollbackEvent,
}

## a player input and the simulation frame it was polled on
InputTick : { tick : U64, input : Input }

## the record of what happened on a previous simulation frame
Snapshot state : {
    ## the simulation frame this occurred on
    tick : U64,
    ## a hash or digest for comparing snapshots to detect desyncs
    checksum : I64,
    ## the remote player's input; this can be predicted or confirmed
    remoteInput : Input,
    ## the local player's input; this is always known and set in stone
    localInput : Input,
    ## the previous game state to restore during a rollback
    state : state,
}

## message for broadcasting input for a frame range with rollback-related metadata
## note: these can be merged, in which case non-input fields are from the most recent message
FrameMessage : {
    ## the sender's local input for this range being broadcast
    input : Input,
    ## the first simulated tick
    firstTick : I64,
    ## the last simulated tick, inclusive
    lastTick : I64,
    ## how far ahead the sender is of their known remote inputs
    tickAdvantage : I64,
    ## the sender's most recent syncTick
    syncTick : I64,
    ## the checksum for the sender's most recent syncTick
    syncTickChecksum : I64,
}

PeerMessage : { id : UUID, message : FrameMessage }

## a rollback frame range recorded for debugging purposes
RollbackEvent : {
    ## the syncTick we rolled back to
    syncTick : U64,
    ## the current local tick we rolled forward to
    currentTick : U64,
}

## named arguments for starting a recording
StartRecording state : {
    firstMessage : FrameMessage,
    state : state,
    config : Config state,
}

## information about the current frame required by Recording.advance
FrameContext : {
    localInput : Input,
    deltaMillis : U64,
    inbox : List PeerMessage,
}

TickContext : {
    tick : U64,
    timestampMillis : U64,
    localInput : Input,
    remoteInput : Input,
}

start : StartRecording state -> Recording state
start = \{ firstMessage, state, config } ->
    remoteMessages = [firstMessage]
    remoteInputTicks = frameMessagesToTicks remoteMessages

    checksum = config.checksum state

    initialSyncSnapshot : Snapshot state
    initialSyncSnapshot = {
        tick: 0,
        remoteInput: Input.blank,
        localInput: Input.blank,
        checksum,
        state,
    }

    firstLocalInputTick : InputTick
    firstLocalInputTick = { tick: 0, input: Input.blank }

    recording : Recorded state
    recording = {
        config,
        remainingMillis: 0,
        tick: 0u64,
        remoteTick: 0u64,
        syncTick: 0u64,
        syncTickSnapshot: initialSyncSnapshot,
        remoteTickAdvantage: 0i64,
        state: state,
        snapshots: [initialSyncSnapshot],
        remoteMessages,
        remoteInputTicks,
        localInputTicks: [firstLocalInputTick],
        blocked: Advancing,
        rollbackLog: [],
    }

    @Recording recording

frameMessagesToTicks : List FrameMessage -> List InputTick
frameMessagesToTicks = \messages ->
    List.joinMap messages \msg ->
        range = List.range { start: At msg.firstTick, end: At msg.lastTick }
        List.map range \tick -> { tick: Num.toU64 tick, input: msg.input }

## ticks the game state forward 0 or more times based on deltaMillis
## returns a new game state and an optional network message to publish if necessary
advance : Recording state, FrameContext -> (Recording state, Result FrameMessage _)
advance = \@Recording oldWorld, { localInput, deltaMillis, inbox } ->
    rollbackDone =
        oldWorld
        |> addRemoteInputs inbox
        |> updateRemoteTick
        |> updateSyncTick
        |> rollbackIfNecessary

    newWorld : Recorded state
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

    (@Recording { newWorld & snapshots }, outgoingMessage)

addRemoteInputs : Recorded state, List PeerMessage -> Recorded state
addRemoteInputs = \world, inbox ->
    remoteMessages =
        newMessages = List.map inbox \peerMessage -> peerMessage.message

        world.remoteMessages
        |> List.concat newMessages
        |> cleanAndSortInputs { syncTick: world.syncTick }

    remoteInputTicks = frameMessagesToTicks remoteMessages

    { world & remoteMessages, remoteInputTicks }

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

updateRemoteTick : Recorded state -> Recorded state
updateRemoteTick = \world ->
    (remoteTick, remoteTickAdvantage) =
        world.remoteMessages
        |> List.last
        |> Result.map \{ lastTick, tickAdvantage } -> (Num.toU64 lastTick, tickAdvantage)
        |> Result.withDefault (0, 0)

    { world & remoteTick, remoteTickAdvantage }

updateSyncTick : Recorded state -> Recorded state
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
                crashInfo = internalShowCrashInfo world
                crash "snapshot not found for new sync tick: $(Inspect.toStr syncTick)\n$(crashInfo)"

    { world & syncTick, syncTickSnapshot }

findMisprediction : Recorded state, (U64, U64) -> Result U64 [NotFound]
findMisprediction = \{ snapshots, remoteInputTicks }, (begin, end) ->
    findMatch : Snapshot state -> Result InputTick [NotFound]
    findMatch = \snapshot ->
        List.findLast remoteInputTicks \inputTick ->
            inputTick.tick == snapshot.tick

    misprediction : Result (Snapshot state) [NotFound]
    misprediction =
        snapshots
        |> List.keepIf \snapshot -> snapshot.tick >= begin && snapshot.tick <= end
        |> List.findFirst \snapshot ->
            when findMatch snapshot is
                Ok match -> match.input != snapshot.remoteInput
                _ -> Bool.false

    Result.map misprediction \m -> m.tick

## true if we're in sync enough with remote player to continue updates
timeSynced : Recorded state -> Bool
timeSynced = \{ config, tick, remoteTick, remoteTickAdvantage } ->
    localTickAdvantage = Num.toI64 tick - Num.toI64 remoteTick
    tickAdvantageDifference = localTickAdvantage - remoteTickAdvantage
    localTickAdvantage < config.maxRollbackTicks && tickAdvantageDifference <= config.tickAdvantageLimit

## use as many physics ticks as the frame duration allows
normalUpdate : Recorded state, { localInput : Input, deltaMillis : U64 } -> (Recorded state, U64)
normalUpdate = \initialWorld, { localInput, deltaMillis } ->
    millisToUse = initialWorld.remainingMillis + deltaMillis
    tickingWorld = { initialWorld & remainingMillis: millisToUse }
    useAllRemainingTime tickingWorld { localInput } 0

useAllRemainingTime : Recorded state, { localInput : Input }, U64 -> (Recorded state, U64)
useAllRemainingTime = \world, inputs, ticksTicked ->
    if world.remainingMillis < world.config.millisPerTick then
        (world, ticksTicked)
    else
        tickedWorld = tickOnce world inputs
        useAllRemainingTime tickedWorld inputs (ticksTicked + 1)

tickOnce : Recorded state, { localInput : Input } -> Recorded state
tickOnce = \world, { localInput: newInput } ->
    tick = world.tick + 1
    timestampMillis = world.tick * world.config.millisPerTick
    remainingMillis = world.remainingMillis - world.config.millisPerTick

    (localInput, localInputIsNew) =
        # avoid overwriting inputs that have been published to other players
        when List.findLast world.localInputTicks \it -> it.tick == tick is
            Ok it -> (it.input, Bool.false)
            Err NotFound -> (newInput, Bool.true)

    (remoteInput, _predicted) = predictRemoteInput world { tick }

    state = world.config.tick world.state {
        tick,
        timestampMillis,
        localInput,
        remoteInput,
    }

    snapshots =
        checksum = world.config.checksum state

        # NOTE:
        # We need to use our previously-sent localInput from above.
        # Changing our own recorded input would break our opponent's rollbacks.
        newSnapshot : Snapshot state
        newSnapshot = { localInput, tick, remoteInput, checksum, state }

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

predictRemoteInput : Recorded state, { tick : U64 } -> (Input, [Predicted, Confirmed])
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
                    crashInfo = internalShowCrashInfo world
                    crash "predictRemoteInput: no remoteInputTicks after first tick:\n$(crashInfo)"

# ROLLBACK

rollbackIfNecessary : Recorded state -> Recorded state
rollbackIfNecessary = \world ->
    shouldRollback = world.tick > world.syncTick && world.remoteTick > world.syncTick

    if !shouldRollback then
        world
    else
        # TODO replace this with rollbackEvent?
        rollForwardRange = (world.syncTick, world.tick - 1) # inclusive

        rollbackEvent : RollbackEvent
        rollbackEvent = { syncTick: world.syncTick, currentTick: world.tick - 1 }

        restoredToSync =
            { world &
                tick: world.syncTick,
                state: world.syncTickSnapshot.state,
                rollbackLog: List.append world.rollbackLog rollbackEvent,
            }

        rollForwardFromSyncTick restoredToSync { rollForwardRange }

rollForwardFromSyncTick : Recorded state, { rollForwardRange : (U64, U64) } -> Recorded state
rollForwardFromSyncTick = \wrongFutureWorld, { rollForwardRange: (begin, end) } ->
    expect begin <= end

    rollForwardTicks = List.range { start: At begin, end: At end }

    # touch up the snapshots to have their 'predictions' match what happened
    fixedWorld : Recorded state
    fixedWorld =
        snapshots : List (Snapshot state)
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
                        remoteInput: inputTick.input,
                    }

        remoteTick =
            when List.last wrongFutureWorld.remoteInputTicks is
                Ok last -> last.tick
                Err ListWasEmpty ->
                    crashInfo = internalShowCrashInfo wrongFutureWorld
                    crash "no last input tick during roll forward: $(crashInfo)"

        lastSnapshotTick =
            when List.last snapshots is
                Ok snap -> snap.tick
                Err _ ->
                    crashInfo = internalShowCrashInfo wrongFutureWorld
                    crash "no snapshots in roll forward fixup: $(crashInfo)"
        syncTick = Num.min remoteTick lastSnapshotTick
        syncTickSnapshot =
            when List.findLast snapshots \snap -> snap.tick == syncTick is
                Ok snap -> snap
                Err _ ->
                    crashInfo = internalShowCrashInfo wrongFutureWorld
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
                        crashInfo = internalShowCrashInfo rollForwardWorld
                        moreInfo = Inspect.toStr { notFoundTick: tick, rollForwardRange: (begin, end) }
                        crash "local input not found in roll forward: $(moreInfo), $(crashInfo)"

            tickOnce steppingWorld { localInput }

    (remoteSyncTick, remoteSyncTickChecksum) =
        when List.last rolledForwardWorld.remoteMessages is
            Ok last -> (last.syncTick, last.syncTickChecksum)
            Err _ ->
                crashInfo = internalShowCrashInfo rolledForwardWorld
                crash "no last remote message during roll forward:\n$(crashInfo)"

    localMatchingChecksum =
        matchingSnap =
            rolledForwardWorld.snapshots
            |> List.findLast \snap -> Num.toI64 snap.tick == remoteSyncTick
        when matchingSnap is
            Ok snap -> snap.checksum
            Err _ ->
                info = Inspect.toStr { remoteSyncTick }
                crashInfo = internalShowCrashInfo rolledForwardWorld
                crash "no matching local snapshot for remote sync tick:$(info)\n$(crashInfo)"

    remainingMillis =
        if remoteSyncTickChecksum == localMatchingChecksum then
            # this is a weird reassignment to avoid the roc warning for a void statement
            remainingMillisBeforeRollForward
        else
            history = internalWritableHistory rolledForwardWorld
            crashInfo = internalShowCrashInfo rolledForwardWorld
            frameMessages = rolledForwardWorld.remoteMessages
            checksums = (remoteSyncTickChecksum, localMatchingChecksum)
            info = Inspect.toStr { remoteSyncTick, checksums, frameMessages }

            crash "different checksums for sync tick: $(info),\n$(crashInfo),\nhistory:\n$(history)"

    { rolledForwardWorld & remainingMillis }

# DEBUG HELPERS

showCrashInfo : Recording state -> Str
showCrashInfo = \@Recording recordedState ->
    internalShowCrashInfo recordedState

internalShowCrashInfo : Recorded state -> Str
internalShowCrashInfo = \world ->
    # TODO require that state is Inspect

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
        # syncTickSnapshot: world.syncTickSnapshot,
        # localPos: world.localPlayer.pos,
        # remotePos: world.remotePlayer.pos,
        rollbackLog: world.rollbackLog,
        remoteInputTicksRange,
        snapshotsRange,
    }

    Inspect.toStr crashInfo

## Creates a multi-line json log of snapshotted inputs.
## This allows creating diffable input logs from multiple clients when debugging.
writableHistory : Recording state -> Str
writableHistory = \@Recording recordedState ->
    internalWritableHistory recordedState

internalWritableHistory : Recorded state -> Str
internalWritableHistory = \{ snapshots } ->
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

    inputSnapshot : Snapshot state -> _
    inputSnapshot = \snap -> {
        tick: snap.tick,
        localInput: writeInput snap.localInput,
        remoteInput: writeInput snap.remoteInput,
    }

    # positionSnapshot : Snapshot state -> _
    # positionSnapshot = \snap -> {
    #     tick: snap.tick,
    #     localPos: Inspect.toStr snap.localPlayer.pos,
    #     remotePos: Inspect.toStr snap.remotePlayer.pos,
    # }

    toUtf8Unchecked = \bytes ->
        when Str.fromUtf8 bytes is
            Ok str -> str
            Err _ -> crash "toUtf8Unchecked"

    writeSnapshot : Snapshot state -> Str
    writeSnapshot = \snap ->
        inputJson =
            snap
            |> inputSnapshot
            |> Encode.toBytes Json.utf8
            |> toUtf8Unchecked

        # positionJson =
        #     snap
        #     |> positionSnapshot
        #     |> Encode.toBytes Json.utf8
        #     |> toUtf8Unchecked

        # "$(inputJson)\n$(positionJson)"
        inputJson

    snapshots
    |> List.map writeSnapshot
    |> Str.joinWith "\n"
