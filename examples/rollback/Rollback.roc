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
    waitingMessage,
]

import rr.Network exposing [UUID]

import json.Json

import Input exposing [Input]
import GameState exposing [GameState]

import InputBuffer

# TODO better name for internal record
Recording := RecordedWorld

currentState : Recording -> GameState
currentState = \@Recording recording ->
    recording.state

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

## a GameState with rollback and timestep related bookkeeping
RecordedWorld : {
    config : Config,

    ## the live game state this frame
    state : GameState,
    ## the unspent milliseconds remaining after the last tick (or frame)
    remainingMillis : U64,

    ## the total number of simulation ticks so far
    tick : U64,
    ## the most recent tick received from the remote player
    remoteTick : U64,
    ## the last tick where we synchronized with the remote player
    syncTick : U64,
    ## the snapshot for our syncTick
    syncTickSnapshot : Snapshot,
    ## the most recent syncTick received from remotePlayer
    remoteSyncTick : U64,
    ## the checksum remotePlayer sent with their most recent syncTick
    remoteSyncTickChecksum : I64,
    ## the latest tick advantage received from the remote player
    remoteTickAdvantage : I64,

    ## the recent history of received network messages (since syncTick)
    remoteMessages : List FrameMessage,
    ## the recent history of remote player inputs (since syncTick)
    ## this is a smaller duplicate of information in remoteMessages
    remoteInputTicks : List InputTick,
    ## the recent history of snapshots (since syncTick)
    snapshots : List Snapshot,
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
    state : GameState,
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
    state : GameState,
    config : Config,
}

## information about the current frame required by Recording.advance
FrameContext : {
    localInput : Input,
    deltaMillis : U64,
    inbox : List PeerMessage,
}

start : StartRecording -> Recording
start = \{ firstMessage, state, config } ->
    remoteMessages = [firstMessage]
    remoteInputTicks = frameMessagesToTicks remoteMessages

    checksum = GameState.checksum state

    initialSyncSnapshot : Snapshot
    initialSyncSnapshot = {
        tick: 0,
        remoteInput: Input.blank,
        localInput: Input.blank,
        checksum,
        state,
    }

    firstLocalInputTick : InputTick
    firstLocalInputTick = { tick: 0, input: Input.blank }

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
advance : Recording, FrameContext -> (Recording, Result FrameMessage _)
advance = \@Recording oldWorld, { localInput, deltaMillis, inbox } ->
    rollbackDone =
        oldWorld
        |> addRemoteInputs inbox
        |> updateRemoteTicks
        |> updateSyncTick
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
        minSyncTick = Num.min newWorld.syncTick newWorld.remoteSyncTick
        List.dropIf newWorld.snapshots \snap -> snap.tick < minSyncTick

    (@Recording { newWorld & snapshots }, outgoingMessage)

addRemoteInputs : RecordedWorld, List PeerMessage -> RecordedWorld
addRemoteInputs = \world, inbox ->
    remoteMessages =
        newMessages = List.map inbox \peerMessage -> peerMessage.message

        world.remoteMessages
        |> List.concat newMessages
        |> cleanAndSortInputs { syncTick: world.syncTick }

    remoteInputTicks = frameMessagesToTicks remoteMessages

    { world & remoteMessages, remoteInputTicks }

# TODO is the sorting required? it would be with UDP
#   does ringbuffer need a way to add sorted? require that internal items have a tick?
#   that'd require changing the name in FrameMessage; or storing a wrapping record
cleanAndSortInputs : List FrameMessage, { syncTick : U64 } -> List FrameMessage
cleanAndSortInputs = \history, { syncTick } ->
    sorted = List.sortWith history \left, right ->
        Num.compare left.firstTick right.firstTick

    keptLast = List.last sorted
    cleaned =
        List.keepOks sorted \msg ->
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

updateRemoteTicks : RecordedWorld -> RecordedWorld
updateRemoteTicks = \world ->
    { remoteTick, remoteTickAdvantage, remoteSyncTick, remoteSyncTickChecksum } =
        world.remoteMessages
        |> List.last
        |> Result.map \lastMessage -> {
            remoteTick: Num.toU64 lastMessage.lastTick,
            remoteTickAdvantage: lastMessage.tickAdvantage,
            remoteSyncTick: Num.toU64 lastMessage.syncTick,
            remoteSyncTickChecksum: lastMessage.syncTickChecksum,
        }
        |> Result.withDefault {
            remoteTick: world.remoteTick,
            remoteTickAdvantage: world.remoteTickAdvantage,
            remoteSyncTick: world.remoteSyncTick,
            remoteSyncTickChecksum: world.remoteSyncTickChecksum,
        }

    { world &
        remoteTick,
        remoteTickAdvantage,
        remoteSyncTick,
        remoteSyncTickChecksum,
    }

updateSyncTick : RecordedWorld -> RecordedWorld
updateSyncTick = \world ->
    checkUpTo = Num.min world.tick world.remoteTick
    # checkRange = (world.syncTick, checkUpTo)
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

findMisprediction : RecordedWorld, (U64, U64) -> Result U64 [NotFound]
findMisprediction = \{ snapshots, remoteInputTicks }, (begin, end) ->
    findMatch : Snapshot -> Result InputTick [NotFound]
    findMatch = \snapshot ->
        List.findLast remoteInputTicks \inputTick ->
            inputTick.tick == snapshot.tick

    misprediction : Result Snapshot [NotFound]
    misprediction =
        snapshots
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
    useAllRemainingTime tickingWorld { localInput } 0

useAllRemainingTime : RecordedWorld, { localInput : Input }, U64 -> (RecordedWorld, U64)
useAllRemainingTime = \world, inputs, ticksTicked ->
    if world.remainingMillis < world.config.millisPerTick then
        (world, ticksTicked)
    else
        tickedWorld = tickOnce world inputs
        useAllRemainingTime tickedWorld inputs (ticksTicked + 1)

tickOnce : RecordedWorld, { localInput : Input } -> RecordedWorld
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

    state = GameState.tick world.state {
        tick,
        timestampMillis,
        localInput,
        remoteInput,
    }

    snapshots =
        checksum = GameState.checksum state

        # NOTE:
        # We need to use our previously-sent localInput from above.
        # Changing our own recorded input would break our opponent's rollbacks.
        newSnapshot : Snapshot
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

predictRemoteInput : RecordedWorld, { tick : U64 } -> (Input, [Predicted, Confirmed])
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

rollbackIfNecessary : RecordedWorld -> RecordedWorld
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

rollForwardFromSyncTick : RecordedWorld, { rollForwardRange : (U64, U64) } -> RecordedWorld
rollForwardFromSyncTick = \wrongFutureWorld, { rollForwardRange: (begin, end) } ->
    expect begin <= end

    rollForwardTicks = List.range { start: At begin, end: At end }

    # touch up the snapshots to have their 'predictions' match what happened
    fixedWorld : RecordedWorld
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

    # TODO why is this assertion part of roll forward?
    # that's where my bug was, but the assertion could be more often;
    # to catch if the opponent is rolling back a lot or having packet loss but we're not
    { remoteSyncTick, remoteSyncTickChecksum } = rolledForwardWorld

    localMatchingChecksum : Result I64 _
    localMatchingChecksum =
        rolledForwardWorld.snapshots
        |> List.findLast \snap -> snap.tick == remoteSyncTick
        |> Result.map \snap -> snap.checksum

    # this is a weird reassignment to avoid the roc warning for a void statement
    # the 'when' exists for the crash assertion
    remainingMillis =
        history = internalWritableHistory rolledForwardWorld
        crashInfo = internalShowCrashInfo rolledForwardWorld
        frameMessages = rolledForwardWorld.remoteMessages
        checksums = (remoteSyncTickChecksum, localMatchingChecksum)
        info = Inspect.toStr { remoteSyncTick, checksums, frameMessages }

        when localMatchingChecksum is
            Ok local if local != remoteSyncTickChecksum ->
                # Known wrong checksums indicate a desync;
                # which means packet loss, a determinism bug, or cheating.
                # In a real game, you'd want to try to resolve missing inputs with request/response,
                # or end the match and kick both players to the launcher/lobby.
                crash "different checksums for sync tick: $(info),\n$(crashInfo),\nhistory:\n$(history)"

            Ok _localMatch ->
                # matching checksums; this is the normal/happy path
                remainingMillisBeforeRollForward

            Err _ ->
                # we should hold on to snapshots long enough to avoid this
                # hitting this case indicates a bug
                crash "missing local checksum in roll forward: $(info),\n$(crashInfo),\nhistory:\n$(history)"

    { rolledForwardWorld & remainingMillis }

# DEBUG HELPERS

showCrashInfo : Recording -> Str
showCrashInfo = \@Recording recordedState ->
    internalShowCrashInfo recordedState

internalShowCrashInfo : RecordedWorld -> Str
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
    |> List.map writeSnapshot
    |> Str.joinWith "\n"

waitingMessage : Rollback.FrameMessage
waitingMessage =
    syncTickChecksum = GameState.positionsChecksum {
        localPlayerPos: GameState.playerStart.pos,
        remotePlayerPos: GameState.playerStart.pos,
    }

    {
        firstTick: 0,
        lastTick: 0,
        tickAdvantage: 0,
        input: Input.blank,
        syncTick: 0,
        syncTickChecksum,
    }
