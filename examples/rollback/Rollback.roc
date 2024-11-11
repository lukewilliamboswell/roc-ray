module [
    Recording,
    StartRecording,
    Config,
    start,
    advance,
    FrameContext,
    PeerMessage,
    FrameMessage,
    showCrashInfo,
    writableHistory,
    currentState,
    recentMessages,
]

import rr.Network exposing [UUID]

import json.Json

import Input exposing [Input]
import World exposing [World]

import NonEmptyList exposing [NonEmptyList]

Recording := RecordedWorld

currentState : Recording -> World
currentState = \@Recording recording ->
    recording.state

recentMessages : Recording, U64 -> List FrameMessage
recentMessages = \@Recording recording, n ->
    recording.outgoingMessages
    |> List.keepOks \res -> res
    |> List.takeLast n

Config : {
    ## the milliseconds per simulation frame
    ## ie, 1000 / the frame rate
    millisPerTick : U64,
    ## the configured max rollback;
    ## a client with tick advantage >= this will block
    maxRollbackTicks : I64,
    ## the configured frame advantage limit;
    ## a client further ahead of their opponent than this will block
    tickAdvantageLimit : I64,
}

## a World with rollback and fixed timestep related bookkeeping
RecordedWorld : {
    config : Config,

    ## the live game state this frame
    state : World,
    ## the unspent milliseconds remaining after the last tick (or frame)
    remainingMillis : U64,

    ## the total number of simulation ticks so far
    tick : U64,
    ## the last tick where we synchronized with the remote player
    syncTick : U64,
    ## the snapshot for our syncTick
    syncTickSnapshot : Snapshot,

    ## the most recent tick received from the remote player
    remoteTick : U64,
    ## the most recent syncTick received from remotePlayer
    remoteSyncTick : U64,
    ## the checksum remotePlayer sent with their most recent syncTick
    remoteSyncTickChecksum : I64,
    ## the latest tick advantage received from the remote player
    remoteTickAdvantage : I64,

    ## the recent history of received network messages
    receivedInputs : NonEmptyList ReceivedInput,
    ## the recent history of snapshots (since syncTick/remoteSyncTick)
    snapshots : NonEmptyList Snapshot,

    ## whether the simulation advanced this frame
    ## Advancing - the simulation advanced at least one frame
    ## Skipped - the simulation advanced 0 ticks this frame due to the fixed timestep
    ## BlockedFor frames - the simulation is blocked waiting for remote player inputs
    blocked : [Advancing, Skipped, BlockedFor U64],

    ## a record of rollback events for debugging purposes
    rollbackLog : List RollbackEvent,
    outgoingMessages : List PublishedMessage,
}

## the record of what happened on a previous simulation frame
Snapshot : {
    ## the simulation frame this occurred on
    tick : U64,
    ## a hash or digest for comparing snapshots to detect desyncs
    checksum : I64,
    ## the remote player's input; this can be predicted or confirmed
    remoteInput : Input,
    ## the local player's input; this is always known and set in stone
    localInput : Input,
    ## the previous game state to restore during a rollback
    state : World,
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
StartRecording : {
    firstMessage : FrameMessage,
    state : World,
    config : Config,
}

## information about the current frame required by Recording.advance
FrameContext : {
    localInput : Input,
    deltaMillis : U64,
    inbox : List PeerMessage,
}

start : StartRecording -> Recording
start = \{ firstMessage: _, state, config } ->
    # TODO use first message for input, or don't require it

    checksum = World.checksum state

    initialSyncSnapshot : Snapshot
    initialSyncSnapshot = {
        tick: 0,
        remoteInput: Input.blank,
        localInput: Input.blank,
        checksum,
        state,
    }

    firstReceivedInput : ReceivedInput
    firstReceivedInput = {
        inputTick: 0,
        receivedTick: 0,
        input: Input.blank,
    }

    recording : RecordedWorld
    recording = {
        config,
        remainingMillis: 0,
        tick: 0,
        remoteTick: 0,
        syncTick: 0,
        syncTickSnapshot: initialSyncSnapshot,
        remoteSyncTick: 0,
        remoteSyncTickChecksum: checksum,
        remoteTickAdvantage: 0,
        state: state,
        snapshots: NonEmptyList.new initialSyncSnapshot,
        receivedInputs: NonEmptyList.new firstReceivedInput,
        blocked: Advancing,
        rollbackLog: [],
        outgoingMessages: [],
    }

    @Recording recording

PublishedMessage : Result FrameMessage [Skipped, BlockedFor U64]

## ticks the game state forward 0 or more times based on deltaMillis
## returns a new game state and an optional network message to publish if the game state advanced
advance : Recording, FrameContext -> (Recording, PublishedMessage)
advance = \@Recording oldWorld, { localInput, deltaMillis, inbox } ->
    rollbackDone =
        oldWorld
        |> updateRemoteInputs inbox
        |> updateRemoteMeta inbox
        |> updateSyncTick
        |> dropOldData
        |> rollbackIfNecessary

    newWorld : RecordedWorld
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

    outgoingMessage : PublishedMessage
    outgoingMessage =
        when newWorld.blocked is
            # blocking on remote input
            BlockedFor n -> Err (BlockedFor n)
            # not enough millis for a timestep;
            # not blocked, but didn't do anything besides accumulate millis
            Skipped -> Err Skipped
            # executed at least one tick
            Advancing ->
                # TODO remove this from return?
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

    outgoingMessages =
        List.append newWorld.outgoingMessages outgoingMessage

    (@Recording { newWorld & outgoingMessages }, outgoingMessage)

ReceivedInput : { receivedTick : U64, inputTick : U64, input : Input }

## add new remote messages, and drop any older than sync ticks
updateRemoteInputs : RecordedWorld, List PeerMessage -> RecordedWorld
updateRemoteInputs = \world, inbox ->
    receivedTick = world.tick

    newReceivedInputs : List ReceivedInput
    newReceivedInputs =
        inbox
        |> List.map .message
        |> List.joinMap \{ firstTick, lastTick, input } ->
            tickRange = List.range { start: At firstTick, end: At lastTick }
            List.map tickRange \tick ->
                inputTick = Num.toU64 tick
                { receivedTick, input, inputTick }

    # drop the older copies of duplicate ticks
    deduplicate : List ReceivedInput -> List ReceivedInput
    deduplicate = \received ->
        initialInputsByTick : Dict U64 ReceivedInput
        initialInputsByTick = Dict.empty {}

        received
        |> List.walkBackwards initialInputsByTick \inputsByTick, recInput ->
            Dict.update inputsByTick recInput.inputTick \entry ->
                when entry is
                    Err Missing -> Ok recInput
                    Ok current ->
                        newer = recInput.receivedTick > current.receivedTick
                        Ok (if newer then recInput else current)
        |> Dict.values

    deduplicateNonEmpty : NonEmptyList ReceivedInput -> NonEmptyList ReceivedInput
    deduplicateNonEmpty = \withDuplicates ->
        deduped =
            withDuplicates
            |> NonEmptyList.toList
            |> deduplicate
            |> NonEmptyList.fromList

        when deduped is
            Err ListWasEmpty -> crash "empty list in received input deduplicate"
            Ok nonEmpty -> nonEmpty

    receivedInputs =
        world.receivedInputs
        |> NonEmptyList.appendAll newReceivedInputs
        |> deduplicateNonEmpty
        |> NonEmptyList.sortWith \left, right ->
            Num.compare left.inputTick right.inputTick

    { world & receivedInputs }

dropOldData : RecordedWorld -> RecordedWorld
dropOldData = \world ->
    beforeLastGap =
        initialState : [Empty, LastSeen U64]
        initialState = Empty

        walked =
            world.receivedInputs
            |> NonEmptyList.toList
            |> List.walkUntil initialState \state, received ->
                when state is
                    Empty -> Continue (LastSeen received.inputTick)
                    LastSeen lastSeen ->
                        if lastSeen + 1 == received.inputTick then
                            Continue (LastSeen received.inputTick)
                        else
                            Break (LastSeen lastSeen)

        when walked is
            Empty -> crash "unreachable"
            LastSeen lastSeen -> lastSeen

    beforeMaxRollback =
        (Num.toI64 world.tick - world.config.maxRollbackTicks)
        |> Num.max 0
        |> Num.toU64

    beforeTickAdvantageLimit =
        (Num.toI64 world.tick - world.config.tickAdvantageLimit)
        |> Num.max 0
        |> Num.toU64

    # avoid discarding received inputs newer than this minimum
    dropThreshold =
        [
            world.syncTick,
            world.remoteSyncTick,
            beforeLastGap,
            beforeMaxRollback,
            beforeTickAdvantageLimit,
        ]
        |> List.walk Num.maxU64 Num.min

    receivedInputs =
        NonEmptyList.dropNonLastIf world.receivedInputs \received ->
            received.inputTick < dropThreshold

    snapshots =
        NonEmptyList.dropNonLastIf world.snapshots \snap ->
            snap.tick < dropThreshold

    # TODO
    { world & receivedInputs, snapshots }

updateRemoteMeta : RecordedWorld, List PeerMessage -> RecordedWorld
updateRemoteMeta = \world, inbox ->
    # TODO
    # find the the temporally last message in the inbox
    # if empty, or if older than meta, keep current remote meta

    maybeLatest =
        inbox
        |> List.map .message
        |> List.sortWith \left, right -> Num.compare left.lastTick right.lastTick
        |> List.last

    when maybeLatest is
        Err ListWasEmpty -> world
        Ok outOfDate if Num.toU64 outOfDate.lastTick < world.remoteTick -> world
        Ok latestMessage ->
            remoteTick = Num.toU64 latestMessage.lastTick
            remoteTickAdvantage = latestMessage.tickAdvantage
            remoteSyncTick = Num.toU64 latestMessage.syncTick
            remoteSyncTickChecksum = latestMessage.syncTickChecksum

            { world &
                remoteTick,
                remoteTickAdvantage,
                remoteSyncTick,
                remoteSyncTickChecksum,
            }

## moves forward the local syncTick to one tick before the earliest misprediction,
## based on received remote inputs
updateSyncTick : RecordedWorld -> RecordedWorld
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
        when NonEmptyList.findLast world.snapshots \snap -> snap.tick == syncTick is
            Ok snap -> snap
            Err _ ->
                crashInfo = internalShowCrashInfo world
                crash "snapshot not found for new sync tick: $(Inspect.toStr syncTick)\n$(crashInfo)"

    { world & syncTick, syncTickSnapshot }

findMisprediction : RecordedWorld, (U64, U64) -> Result U64 [NotFound]
findMisprediction = \{ snapshots, receivedInputs }, (begin, end) ->
    findMatch : Snapshot -> Result ReceivedInput [NotFound]
    findMatch = \snap ->
        NonEmptyList.findLast receivedInputs \received ->
            received.inputTick == snap.tick

    misprediction : Result Snapshot [NotFound]
    misprediction =
        snapshots
        |> NonEmptyList.toList
        |> List.keepIf \snapshot -> snapshot.tick >= begin && snapshot.tick <= end
        |> List.findFirst \snapshot ->
            when findMatch snapshot is
                Ok match -> match.input != snapshot.remoteInput
                _ -> Bool.false

    Result.map misprediction \m -> m.tick

## true if we're in sync enough with remote player to continue updates
timeSynced : RecordedWorld -> Bool
timeSynced = \{ config, tick, remoteTick, remoteTickAdvantage } ->
    localTickAdvantage = Num.toI64 tick - Num.toI64 remoteTick
    tickAdvantageDifference = localTickAdvantage - remoteTickAdvantage
    localTickAdvantage < config.maxRollbackTicks && tickAdvantageDifference <= config.tickAdvantageLimit

## use as many physics ticks as the frame duration allows
normalUpdate : RecordedWorld, { localInput : Input, deltaMillis : U64 } -> (RecordedWorld, U64)
normalUpdate = \initialWorld, { localInput, deltaMillis } ->
    millisToUse = initialWorld.remainingMillis + deltaMillis
    tickingWorld = { initialWorld & remainingMillis: millisToUse }
    useAllRemainingTime tickingWorld { localInput, ticksTicked: 0 }

useAllRemainingTime : RecordedWorld, { localInput : Input, ticksTicked : U64 } -> (RecordedWorld, U64)
useAllRemainingTime = \world, { localInput, ticksTicked } ->
    if world.remainingMillis < world.config.millisPerTick then
        (world, ticksTicked)
    else
        tickedWorld = tickOnce { world, localInput: Fresh localInput }
        useAllRemainingTime tickedWorld { localInput, ticksTicked: ticksTicked + 1 }

tickOnce : { world : RecordedWorld, localInput : [Fresh Input, Recorded] } -> RecordedWorld
tickOnce = \{ world, localInput: inputSource } ->
    tick = world.tick + 1
    timestampMillis = world.tick * world.config.millisPerTick
    remainingMillis = world.remainingMillis - world.config.millisPerTick

    localInput : Input
    localInput =
        when inputSource is
            # we're executing a new, normal game tick
            Fresh input -> input
            # we're re-executing a previous tick in a roll forward
            # we need to avoid changing our inputs that have been sent to other players
            Recorded ->
                when NonEmptyList.findLast world.snapshots \s -> s.tick == tick is
                    Ok snap -> snap.localInput
                    Err NotFound ->
                        crashInfo = internalShowCrashInfo world
                        crash "local input not found in roll forward:\n$(crashInfo)"

    remoteInput = predictRemoteInput { world, tick }

    state = World.tick world.state { tick, timestampMillis, localInput, remoteInput }

    snapshots =
        checksum = World.checksum state

        # NOTE:
        # We need to use our previously-sent localInput from above.
        # Changing our own recorded input would break our opponent's rollbacks.
        # But we do want to overwrite the rest of the snapshot if we're rolling forward.
        newSnapshot : Snapshot
        newSnapshot = { localInput, tick, remoteInput, checksum, state }

        when inputSource is
            Fresh _ -> NonEmptyList.append world.snapshots newSnapshot
            Recorded ->
                NonEmptyList.map world.snapshots \snap ->
                    if snap.tick != tick then snap else newSnapshot

    { world &
        state,
        remainingMillis,
        tick,
        snapshots,
    }

predictRemoteInput : { world : RecordedWorld, tick : U64 } -> Input
predictRemoteInput = \{ world, tick } ->
    # TODO why shoul
    # if the specific tick we want is missing, predict the last thing they did
    predictedInput =
        world.receivedInputs
        |> NonEmptyList.findLast \received -> received.inputTick <= tick
        |> Result.map .input

    when predictedInput is
        Err NotFound ->
            # we need to hold onto old snapshots long enough to prevent this
            crashInfo = internalShowCrashInfo world
            crash "no input snapshot found for tick: $(Inspect.toStr tick)\n$(crashInfo)"

        Ok input -> input

# ROLLBACK

## if we had a misprediction,
## rolls back and resimulates the game state with newly received remote inputs
rollbackIfNecessary : RecordedWorld -> RecordedWorld
rollbackIfNecessary = \world ->
    # we need to roll back if both players have progressed since the last sync point
    shouldRollback = world.tick > world.syncTick && world.remoteTick > world.syncTick

    if !shouldRollback then
        world
    else
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

rollForwardFromSyncTick : RecordedWorld, { rollForwardRange : (U64, U64) } -> RecordedWorld
rollForwardFromSyncTick = \wrongFutureWorld, { rollForwardRange: (begin, end) } ->
    expect begin <= end

    # touch up the snapshots to have their 'predictions' match what happened
    fixedWorld : RecordedWorld
    fixedWorld =
        snapshots : NonEmptyList Snapshot
        snapshots = NonEmptyList.map wrongFutureWorld.snapshots \wrongFutureSnap ->
            recentReceived =
                NonEmptyList.findLast wrongFutureWorld.receivedInputs \received ->
                    received.inputTick <= wrongFutureSnap.tick

            when recentReceived is
                Err NotFound -> wrongFutureSnap
                Ok { input: remoteInput } -> { wrongFutureSnap & remoteInput }

        # TODO is this necessary? or would it already be updated in the normal flow?
        # remoteTick =
        #     lastReceived = NonEmptyList.last wrongFutureWorld.receivedInputs
        #     Num.toU64 lastReceived.inputTick
        remoteTick = wrongFutureWorld.remoteTick
        lastSnapshot = NonEmptyList.last snapshots
        syncTick = Num.min wrongFutureWorld.remoteTick lastSnapshot.tick
        syncTickSnapshot =
            when NonEmptyList.findLast snapshots \snap -> snap.tick == syncTick is
                Ok snap -> snap
                Err _ ->
                    crashInfo = internalShowCrashInfo wrongFutureWorld
                    crash "snapshot not found for new sync tick in roll forward fixup: $(Inspect.toStr syncTick)\n$(crashInfo)"

        { wrongFutureWorld & snapshots, remoteTick, syncTick, syncTickSnapshot }

    remainingMillis = fixedWorld.remainingMillis
    rollForwardWorld = { fixedWorld & remainingMillis: Num.maxU64 }

    # simulate every tick between syncTick and the present to catch up
    rollForwardTicks = List.range { start: At begin, end: At end }
    rolledForwardWorld =
        List.walk rollForwardTicks rollForwardWorld \world, _tick ->
            tickOnce { world, localInput: Recorded }

    # FIXME fix the checksum or remove the assertion
    checkedWorld = assertValidChecksum rolledForwardWorld

    { checkedWorld & remainingMillis }

## Crashes if we detect a desync at our opponent's latest sent sync tick.
## You'd what to handle desyncs more gracefully in a real game,
## and might want to check for them periodically outside of rollback as well.
assertValidChecksum : RecordedWorld -> RecordedWorld
assertValidChecksum = \world ->
    { remoteSyncTick, remoteSyncTickChecksum } = world

    localMatchingChecksum : Result I64 [NotFound]
    localMatchingChecksum =
        world.snapshots
        |> NonEmptyList.findLast \snap -> snap.tick == remoteSyncTick
        |> Result.map \snap -> snap.checksum

    history = internalWritableHistory world
    crashInfo = internalShowCrashInfo world
    receivedInputs = world.receivedInputs
    checksums = (remoteSyncTickChecksum, localMatchingChecksum)
    info = Inspect.toStr { remoteSyncTick, checksums, receivedInputs }

    when localMatchingChecksum is
        Ok local if local == remoteSyncTickChecksum ->
            # matching checksums; this is the normal/happy path
            world

        Ok _noMatch ->
            # Known wrong checksums indicate a desync,
            # which means unmanaged packet loss, a determinism bug, or cheating.
            # In a real game, you'd want to try to resolve missing inputs with request/response,
            # or end the match and kick both players to the launcher/lobby.
            crash "different checksums for sync tick: $(info),\n$(crashInfo),\nhistory:\n$(history)"

        Err NotFound ->
            # we should hold on to snapshots long enough to avoid this
            # hitting this case indicates a bug
            crash "missing local checksum in roll forward: $(info),\n$(crashInfo),\nhistory:\n$(history)"

# DEBUG HELPERS

showCrashInfo : Recording -> Str
showCrashInfo = \@Recording recordedState ->
    internalShowCrashInfo recordedState

internalShowCrashInfo : RecordedWorld -> Str
internalShowCrashInfo = \world ->
    receivedInputsRange =
        first = NonEmptyList.first world.receivedInputs |> .inputTick
        last = NonEmptyList.last world.receivedInputs |> .inputTick
        (first, last)

    snapshotsRange =
        first = NonEmptyList.first world.snapshots |> .tick
        last = NonEmptyList.last world.snapshots |> .tick
        (first, last)

    crashInfo = {
        tick: world.tick,
        remoteTick: world.remoteTick,
        syncTick: world.syncTick,
        syncTickSnapshot: world.syncTickSnapshot,
        localPos: world.state.localPlayer.pos,
        remotePos: world.state.remotePlayer.pos,
        rollbackLog: world.rollbackLog,
        receivedInputsRange,
        snapshotsRange,
    }

    Inspect.toStr crashInfo

## Creates a multi-line json log of snapshotted inputs.
## This allows creating diffable input logs from multiple clients when debugging.
writableHistory : Recording -> Str
writableHistory = \@Recording recordedState ->
    internalWritableHistory recordedState

internalWritableHistory : RecordedWorld -> Str
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

    inputSnapshot : Snapshot -> _
    inputSnapshot = \snap -> {
        tick: snap.tick,
        localInput: writeInput snap.localInput,
        remoteInput: writeInput snap.remoteInput,
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
    |> NonEmptyList.toList
    |> List.map writeSnapshot
    |> Str.joinWith "\n"

