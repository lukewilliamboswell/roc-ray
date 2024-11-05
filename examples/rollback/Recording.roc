module [
    Recording,
    StartRecording,
    Config,
    start,
]

import Input exposing [Input]

import Rollback exposing [Rollback]

Recording state := InternalRecording state

Config : {
    ## the configured max rollback;
    ## a client with tick advantage >= this will block
    maxRollbackTicks : I64,
    ## the configured frame advantage limit;
    ## a client further ahead of their opponent than this will block
    tickAdvantageLimit : I64,
}

InternalRecording state : {
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
    ## the recent history of snapshots (since syncTick)
    snapshots : List (Snapshot state),

    ## the recent history of received network messages (since syncTick)
    remoteMessages : List FrameMessage,
    ## the recent history of remote player inputs (since syncTick)
    remoteInputTicks : List InputTick,
    ## the recent history of local player inputs (since syncTick)
    localInputTicks : List InputTick,

    ## whether we're blocked on remote input and for how long
    blocked : [Advancing, BlockedFor U64],

    ## a record of rollback events for debugging purposes
    rollbackLog : List RollbackEvent,

    ## the configured max rollback;
    ## a client with tick advantage >= this will block
    maxRollbackTicks : I64,
    ## the configured frame advantage limit;
    ## a client further ahead of their opponent than this will block
    tickAdvantageLimit : I64,
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
    config : Config,
} where state implements Rollback

start : StartRecording state -> Recording state where state implements Rollback
start = \{ firstMessage, state, config } ->
    remoteMessages = [firstMessage]
    remoteInputTicks = frameMessagesToTicks remoteMessages

    initialSyncSnapshot : Snapshot state
    initialSyncSnapshot = {
        tick: 0,
        remoteInput: Input.blank,
        localInput: Input.blank,
        checksum: Rollback.checksum state,
        state,
    }

    firstLocalInputTick : InputTick
    firstLocalInputTick = { tick: 0, input: Input.blank }

    recording : InternalRecording state
    recording = {
        tick: 0,
        remoteTick: 0,
        syncTick: 0,
        syncTickSnapshot: initialSyncSnapshot,
        remoteTickAdvantage: 0,
        snapshots: [initialSyncSnapshot],
        remoteMessages,
        remoteInputTicks,
        localInputTicks: [firstLocalInputTick],
        blocked: Advancing,
        rollbackLog: [],
        maxRollbackTicks: config.maxRollbackTicks,
        tickAdvantageLimit: config.tickAdvantageLimit,
    }

    @Recording recording

frameMessagesToTicks : List FrameMessage -> List InputTick
frameMessagesToTicks = \messages ->
    List.joinMap messages \msg ->
        range = List.range { start: At msg.firstTick, end: At msg.lastTick }
        List.map range \tick -> { tick: Num.toU64 tick, input: msg.input }
