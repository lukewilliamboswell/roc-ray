module [
    Recording,
    StartRecording,
    Config,
    start,
    advance,
    FrameContext,
    PeerMessage,
    FrameMessage,
    show_crash_info,
    writable_history,
    current_state,
    recent_messages,
    desync_status,
    block_status,
]

import rr.Network exposing [UUID]

import json.Json

import Input exposing [Input]
import World exposing [World]

import NonEmptyList exposing [NonEmptyList]

Recording := RecordedWorld

current_state : Recording -> World
current_state = |@Recording(recording)|
    recording.state

recent_messages : Recording -> List FrameMessage
recent_messages = |@Recording(recording)|
    recording.outgoing_messages
    |> List.keep_oks(|res| res)
    |> List.take_last(recording.config.send_most_recent)

desync_status : Recording -> [Synced, Desynced DesyncBugReport]
desync_status = |@Recording(recording)|
    recording.desync

block_status : Recording -> _
block_status = |@Recording(recording)|
    recording.blocked

Config : {
    ## the milliseconds per simulation frame
    ## ie, 1000 / the frame rate
    millis_per_tick : U64,
    ## the configured max rollback;
    ## a client with tick advantage >= this will block
    max_rollback_ticks : I64,
    ## the configured frame advantage limit;
    ## a client further ahead of their opponent than this will block
    tick_advantage_limit : I64,
    ## how many recent frames of inputs to send each frame
    send_most_recent : U64,
}

## a World with rollback and fixed timestep related bookkeeping
RecordedWorld : {
    config : Config,

    ## the live game state this frame
    state : World,
    ## the unspent milliseconds remaining after the last tick (or frame)
    remaining_millis : U64,

    ## the total number of simulation ticks so far
    tick : U64,
    ## the last tick where we synchronized with the remote player
    sync_tick : U64,
    ## the snapshot for our syncTick
    sync_tick_snapshot : Snapshot,

    ## the most recent tick received from the remote player
    remote_tick : U64,
    ## the most recent syncTick received from remotePlayer
    remote_sync_tick : U64,
    ## the checksum remotePlayer sent with their most recent syncTick
    remote_sync_tick_checksum : I64,
    ## the latest tick advantage received from the remote player
    remote_tick_advantage : I64,

    ## the recent history of received network messages
    received_inputs : NonEmptyList ReceivedInput,
    ## the recent history of snapshots (since syncTick/remoteSyncTick)
    snapshots : NonEmptyList Snapshot,

    ## whether the simulation advanced this frame
    ## Advancing - the simulation advanced at least one frame
    ## Skipped - the simulation advanced 0 ticks this frame due to the fixed timestep
    ## BlockedFor frames - the simulation is blocked waiting for remote player inputs
    blocked : [Advancing, Skipped, BlockedFor U64],

    ## a record of rollback events for debugging purposes
    rollback_log : List RollbackEvent,
    outgoing_messages : List PublishedMessage,

    ## whether we've detected a desync with the remote player
    desync : [Synced, Desynced DesyncBugReport],
}

## the record of what happened on a previous simulation frame
Snapshot : {
    ## the simulation frame this occurred on
    tick : U64,
    ## a hash or digest for comparing snapshots to detect desyncs
    checksum : I64,
    ## the remote player's input; this can be predicted or confirmed
    remote_input : Input,
    ## the local player's input; this is always known and set in stone
    local_input : Input,
    ## the previous game state to restore during a rollback
    state : World,
}

## message for broadcasting input for a frame range with rollback-related metadata
## note: these can be merged, in which case non-input fields are from the most recent message
FrameMessage : {
    ## the sender's local input for this range being broadcast
    input : Input,
    ## the first simulated tick
    first_tick : I64,
    ## the last simulated tick, inclusive
    last_tick : I64,
    ## how far ahead the sender is of their known remote inputs
    tick_advantage : I64,
    ## the sender's most recent syncTick
    sync_tick : I64,
    ## the checksum for the sender's most recent syncTick
    sync_tick_checksum : I64,
}

PeerMessage : { id : UUID, message : FrameMessage }

## a rollback frame range recorded for debugging purposes
RollbackEvent : {
    ## the syncTick we rolled back to
    sync_tick : U64,
    ## the current local tick we rolled forward to
    current_tick : U64,
}

## named arguments for starting a recording
StartRecording : {
    state : World,
    config : Config,
}

## information about the current frame required by Recording.advance
FrameContext : {
    local_input : Input,
    delta_millis : U64,
    inbox : List PeerMessage,
}

start : StartRecording -> Recording
start = |{ state, config }|
    checksum = World.checksum(state)

    initial_sync_snapshot : Snapshot
    initial_sync_snapshot = {
        tick: 0,
        remote_input: Input.blank,
        local_input: Input.blank,
        checksum,
        state,
    }

    first_received_input : ReceivedInput
    first_received_input = {
        input_tick: 0,
        received_tick: 0,
        input: Input.blank,
    }

    recording : RecordedWorld
    recording = {
        config,
        remaining_millis: 0,
        tick: 0,
        remote_tick: 0,
        sync_tick: 0,
        sync_tick_snapshot: initial_sync_snapshot,
        remote_sync_tick: 0,
        remote_sync_tick_checksum: checksum,
        remote_tick_advantage: 0,
        state: state,
        snapshots: NonEmptyList.new(initial_sync_snapshot),
        received_inputs: NonEmptyList.new(first_received_input),
        blocked: Advancing,
        rollback_log: [],
        outgoing_messages: [],
        desync: Synced,
    }

    @Recording(recording)

PublishedMessage : Result FrameMessage [Skipped, BlockedFor U64]

## ticks the game state forward 0 or more times based on deltaMillis
## returns a new game state and an optional network message to publish if the game state advanced
advance : Recording, FrameContext -> Recording
advance = |@Recording(old_world), { local_input, delta_millis, inbox }|
    rollback_done =
        old_world
        |> update_remote_inputs(inbox)
        |> update_remote_ticks(inbox)
        |> update_sync_tick
        |> drop_old_inputs
        |> rollback_if_necessary
        |> detect_desync

    new_world : RecordedWorld
    new_world =
        if time_synced(rollback_done) then
            (updated_world, ticks_ticked) =
                normal_update(rollback_done, { local_input, delta_millis })
            blocked = if ticks_ticked == 0 then Skipped else Advancing
            { updated_world & blocked }
        else
            # Block on remote updates
            blocked =
                when rollback_done.blocked is
                    BlockedFor(frames) -> BlockedFor((frames + 1))
                    Advancing | Skipped -> BlockedFor(1)

            { rollback_done & blocked }

    first_tick = rollback_done.tick + 1 |> Num.to_i64
    last_tick = new_world.tick |> Num.to_i64
    tick_advantage = Num.to_i64(new_world.tick) - Num.to_i64(new_world.remote_tick)

    outgoing_message : PublishedMessage
    outgoing_message =
        when new_world.blocked is
            # blocking on remote input
            BlockedFor(n) -> Err(BlockedFor(n))
            # not enough millis for a timestep;
            # not blocked, but didn't do anything besides accumulate millis
            Skipped -> Err(Skipped)
            # executed at least one tick
            Advancing ->
                frame_message : FrameMessage
                frame_message = {
                    first_tick,
                    last_tick,
                    tick_advantage,
                    input: local_input,
                    sync_tick: Num.to_i64(new_world.sync_tick),
                    sync_tick_checksum: new_world.sync_tick_snapshot.checksum,
                }

                Ok(frame_message)

    outgoing_messages =
        List.append(new_world.outgoing_messages, outgoing_message)

    @Recording({ new_world & outgoing_messages })

ReceivedInput : { received_tick : U64, input_tick : U64, input : Input }

## add new remote messages, and drop any older than sync ticks
update_remote_inputs : RecordedWorld, List PeerMessage -> RecordedWorld
update_remote_inputs = |world, inbox|
    received_tick = world.tick

    new_received_inputs : List ReceivedInput
    new_received_inputs =
        inbox
        |> List.map(.message)
        |> List.join_map(
            |{ first_tick, last_tick, input }|
                tick_range = List.range({ start: At(first_tick), end: At(last_tick) })
                List.map(
                    tick_range,
                    |tick|
                        input_tick = Num.to_u64(tick)
                        { received_tick, input, input_tick },
                ),
        )

    # drop the older copies of duplicate ticks
    deduplicate : List ReceivedInput -> List ReceivedInput
    deduplicate = |received|
        initial_inputs_by_tick : Dict U64 ReceivedInput
        initial_inputs_by_tick = Dict.empty({})

        received
        |> List.walk_backwards(
            initial_inputs_by_tick,
            |inputs_by_tick, rec_input|
                Dict.update(
                    inputs_by_tick,
                    rec_input.input_tick,
                    |entry|
                        when entry is
                            Err(Missing) -> Ok(rec_input)
                            Ok(current) ->
                                newer = rec_input.received_tick > current.received_tick
                                Ok((if newer then rec_input else current)),
                ),
        )
        |> Dict.values

    deduplicate_non_empty : NonEmptyList ReceivedInput -> NonEmptyList ReceivedInput
    deduplicate_non_empty = |with_duplicates|
        deduped =
            with_duplicates
            |> NonEmptyList.to_list
            |> deduplicate
            |> NonEmptyList.from_list

        when deduped is
            Err(ListWasEmpty) -> crash("empty list in received input deduplicate")
            Ok(non_empty) -> non_empty

    received_inputs =
        world.received_inputs
        |> NonEmptyList.append_all(new_received_inputs)
        |> deduplicate_non_empty
        |> NonEmptyList.sort_with(
            |left, right|
                Num.compare(left.input_tick, right.input_tick),
        )

    { world & received_inputs }

drop_old_inputs : RecordedWorld -> RecordedWorld
drop_old_inputs = |world|
    before_first_gap =
        world.received_inputs
        |> NonEmptyList.walk_until(
            |first_received| Continue(first_received.input_tick),
            |last_seen, received|
                if last_seen + 1 == received.input_tick then
                    Continue(received.input_tick)
                else
                    Break(last_seen),
        )

    before_max_rollback =
        (Num.to_i64(world.tick) - world.config.max_rollback_ticks)
        |> Num.max(0)
        |> Num.to_u64

    before_tick_advantage_limit =
        (Num.to_i64(world.tick) - world.config.tick_advantage_limit)
        |> Num.max(0)
        |> Num.to_u64

    # avoid discarding any inputs past than this minimum tick
    drop_threshold =
        [
            world.sync_tick,
            world.remote_sync_tick,
            before_first_gap,
            before_max_rollback,
            before_tick_advantage_limit,
        ]
        |> List.walk(Num.max_u64, Num.min)

    received_inputs =
        NonEmptyList.drop_non_last_if(
            world.received_inputs,
            |received|
                received.input_tick < drop_threshold,
        )

    snapshots =
        NonEmptyList.drop_non_last_if(
            world.snapshots,
            |snap|
                snap.tick < drop_threshold,
        )

    { world & received_inputs, snapshots }

update_remote_ticks : RecordedWorld, List PeerMessage -> RecordedWorld
update_remote_ticks = |world, inbox|
    maybe_latest =
        inbox
        |> List.map(.message)
        |> List.sort_with(|left, right| Num.compare(left.last_tick, right.last_tick))
        |> List.last

    when maybe_latest is
        Err(ListWasEmpty) -> world
        Ok(out_of_date) if Num.to_u64(out_of_date.last_tick) < world.remote_tick -> world
        Ok(latest_message) ->
            remote_tick = Num.to_u64(latest_message.last_tick)
            remote_tick_advantage = latest_message.tick_advantage
            remote_sync_tick = Num.to_u64(latest_message.sync_tick)
            remote_sync_tick_checksum = latest_message.sync_tick_checksum

            { world &
                remote_tick,
                remote_tick_advantage,
                remote_sync_tick,
                remote_sync_tick_checksum,
            }

## moves forward the local syncTick to one tick before the earliest misprediction,
## based on received remote inputs
update_sync_tick : RecordedWorld -> RecordedWorld
update_sync_tick = |world|
    check_up_to = Num.min(world.tick, world.remote_tick)
    check_range = (world.sync_tick + 1, check_up_to)

    before_misprediction : Result U64 [NotFound]
    before_misprediction =
        find_misprediction(world, check_range)
        |> Result.map_ok(|mispredicted_tick| mispredicted_tick - 1)

    sync_tick =
        Result.with_default(before_misprediction, check_up_to)

    # syncTick should not move backwards
    expect world.sync_tick <= sync_tick

    sync_tick_snapshot =
        when NonEmptyList.find_last(world.snapshots, |snap| snap.tick == sync_tick) is
            Ok(snap) -> snap
            Err(_) ->
                crash_info = internal_show_crash_info(world)
                crash("snapshot not found for new sync tick: ${Inspect.to_str(sync_tick)}\n${crash_info}")

    { world & sync_tick, sync_tick_snapshot }

find_misprediction : RecordedWorld, (U64, U64) -> Result U64 [NotFound]
find_misprediction = |{ snapshots, received_inputs }, (begin, end)|
    find_match : Snapshot -> Result ReceivedInput [NotFound]
    find_match = |snap|
        NonEmptyList.find_last(
            received_inputs,
            |received|
                received.input_tick == snap.tick,
        )

    misprediction : Result Snapshot [NotFound]
    misprediction =
        snapshots
        |> NonEmptyList.to_list
        |> List.keep_if(|snapshot| snapshot.tick >= begin and snapshot.tick <= end)
        |> List.find_first(
            |snapshot|
                when find_match(snapshot) is
                    Ok(match) -> match.input != snapshot.remote_input
                    _ -> Bool.false,
        )

    Result.map_ok(misprediction, |m| m.tick)

## true if we're in sync enough with remote player to continue updates
time_synced : RecordedWorld -> Bool
time_synced = |{ config, tick, remote_tick, remote_tick_advantage }|
    local_tick_advantage = Num.to_i64(tick) - Num.to_i64(remote_tick)
    tick_advantage_difference = local_tick_advantage - remote_tick_advantage
    local_tick_advantage < config.max_rollback_ticks and tick_advantage_difference <= config.tick_advantage_limit

## use as many physics ticks as the frame duration allows
normal_update : RecordedWorld, { local_input : Input, delta_millis : U64 } -> (RecordedWorld, U64)
normal_update = |initial_world, { local_input, delta_millis }|
    millis_to_use = initial_world.remaining_millis + delta_millis
    ticking_world = { initial_world & remaining_millis: millis_to_use }
    use_all_remaining_time(ticking_world, { local_input, ticks_ticked: 0 })

use_all_remaining_time : RecordedWorld, { local_input : Input, ticks_ticked : U64 } -> (RecordedWorld, U64)
use_all_remaining_time = |world, { local_input, ticks_ticked }|
    if world.remaining_millis < world.config.millis_per_tick then
        (world, ticks_ticked)
    else
        ticked_world = tick_once({ world, local_input: Fresh(local_input) })
        use_all_remaining_time(ticked_world, { local_input, ticks_ticked: ticks_ticked + 1 })

tick_once : { world : RecordedWorld, local_input : [Fresh Input, Recorded] } -> RecordedWorld
tick_once = |{ world, local_input: input_source }|
    tick = world.tick + 1
    timestamp_millis = world.tick * world.config.millis_per_tick
    remaining_millis = world.remaining_millis - world.config.millis_per_tick

    local_input : Input
    local_input =
        when input_source is
            # we're executing a new, normal game tick
            Fresh(input) -> input
            # we're re-executing a previous tick in a roll forward
            # we need to avoid changing our inputs that have been sent to other players
            Recorded ->
                when NonEmptyList.find_last(world.snapshots, |s| s.tick == tick) is
                    Ok(snap) -> snap.local_input
                    Err(NotFound) ->
                        crash_info = internal_show_crash_info(world)
                        crash("local input not found in roll forward:\n${crash_info}")

    remote_input = predict_remote_input({ world, tick })

    state = World.tick(world.state, { tick, timestamp_millis, local_input, remote_input })

    snapshots =
        checksum = World.checksum(state)

        # NOTE:
        # We need to use our previously-sent localInput from above.
        # Changing our own recorded input would break our opponent's rollbacks.
        # But we do want to overwrite the rest of the snapshot if we're rolling forward.
        new_snapshot : Snapshot
        new_snapshot = { local_input, tick, remote_input, checksum, state }

        when input_source is
            Fresh(_) -> NonEmptyList.append(world.snapshots, new_snapshot)
            Recorded ->
                NonEmptyList.map(
                    world.snapshots,
                    |snap|
                        if snap.tick != tick then snap else new_snapshot,
                )

    { world &
        state,
        remaining_millis,
        tick,
        snapshots,
    }

predict_remote_input : { world : RecordedWorld, tick : U64 } -> Input
predict_remote_input = |{ world, tick }|
    # if the specific tick we want is missing, predict the last thing they did
    predicted_input =
        world.received_inputs
        |> NonEmptyList.find_last(|received| received.input_tick <= tick)
        |> Result.map_ok(.input)

    when predicted_input is
        Err(NotFound) ->
            # we need to hold onto old snapshots long enough to prevent this
            crash_info = internal_show_crash_info(world)
            crash("no input snapshot found for tick: ${Inspect.to_str(tick)}\n${crash_info}")

        Ok(input) -> input

# ROLLBACK

## if we had a misprediction,
## rolls back and resimulates the game state with newly received remote inputs
rollback_if_necessary : RecordedWorld -> RecordedWorld
rollback_if_necessary = |world|
    # we need to roll back if both players have progressed since the last sync point
    should_rollback = world.tick > world.sync_tick and world.remote_tick > world.sync_tick

    if !should_rollback then
        world
    else
        roll_forward_range = (world.sync_tick, world.tick - 1) # inclusive

        rollback_event : RollbackEvent
        rollback_event = { sync_tick: world.sync_tick, current_tick: world.tick - 1 }

        restored_to_sync =
            { world &
                tick: world.sync_tick,
                state: world.sync_tick_snapshot.state,
                rollback_log: List.append(world.rollback_log, rollback_event),
            }

        roll_forward_from_sync_tick(restored_to_sync, { roll_forward_range })

roll_forward_from_sync_tick : RecordedWorld, { roll_forward_range : (U64, U64) } -> RecordedWorld
roll_forward_from_sync_tick = |wrong_future_world, { roll_forward_range: (begin, end) }|
    expect begin <= end

    # touch up the snapshots to have their 'predictions' match what happened
    fixed_world : RecordedWorld
    fixed_world =
        snapshots : NonEmptyList Snapshot
        snapshots = NonEmptyList.map(
            wrong_future_world.snapshots,
            |wrong_future_snap|
                recent_received =
                    NonEmptyList.find_last(
                        wrong_future_world.received_inputs,
                        |received|
                            received.input_tick <= wrong_future_snap.tick,
                    )

                when recent_received is
                    Err(NotFound) -> wrong_future_snap
                    Ok({ input: remote_input }) -> { wrong_future_snap & remote_input },
        )

        remote_tick = wrong_future_world.remote_tick
        last_snapshot = NonEmptyList.last(snapshots)
        sync_tick = Num.min(wrong_future_world.remote_tick, last_snapshot.tick)
        sync_tick_snapshot =
            when NonEmptyList.find_last(snapshots, |snap| snap.tick == sync_tick) is
                Ok(snap) -> snap
                Err(_) ->
                    crash_info = internal_show_crash_info(wrong_future_world)
                    crash("snapshot not found for new sync tick in roll forward fixup: ${Inspect.to_str(sync_tick)}\n${crash_info}")

        { wrong_future_world & snapshots, remote_tick, sync_tick, sync_tick_snapshot }

    remaining_millis = fixed_world.remaining_millis
    roll_forward_world = { fixed_world & remaining_millis: Num.max_u64 }

    # simulate every tick between syncTick and the present to catch up
    roll_forward_ticks = List.range({ start: At(begin), end: At(end) })
    rolled_forward_world =
        List.walk(
            roll_forward_ticks,
            roll_forward_world,
            |world, _tick|
                tick_once({ world, local_input: Recorded }),
        )

    { rolled_forward_world & remaining_millis }

## Updates desync status if we detect a desync at our opponent's latest sent sync tick
detect_desync : RecordedWorld -> RecordedWorld
detect_desync = |world|
    { remote_sync_tick, remote_sync_tick_checksum } = world

    local_matching_checksum : Result I64 [NotFound]
    local_matching_checksum =
        world.snapshots
        |> NonEmptyList.find_last(|snap| snap.tick == remote_sync_tick)
        |> Result.map_ok(|snap| snap.checksum)

    history = internal_writable_history(world)
    crash_info = internal_show_crash_info(world)

    report : [Desync, MissingChecksum] -> DesyncBugReport
    report = |kind| {
        kind,
        remote_sync_tick,
        remote_sync_tick_checksum,
        local_matching_checksum,
        history,
        crash_info,
    }

    when local_matching_checksum is
        Ok(local) if local == remote_sync_tick_checksum ->
            # matching checksums; this is the normal/happy path
            { world & desync: Synced }

        Ok(_noMatch) ->
            # Known wrong checksums indicate a desync,
            # which means unmanaged packet loss, a determinism bug, or cheating.
            # In a real game, you'd want to try to resolve missing inputs with request/response,
            # or end the match and kick both players to the launcher/lobby.
            desync =
                when world.desync is
                    Desynced(previous_report) -> Desynced(previous_report)
                    _other -> Desynced(report(Desync))

            { world & desync }

        Err(NotFound) ->
            # we should hold on to snapshots long enough to avoid this
            # hitting this case indicates a bug
            { world & desync: Desynced(report(MissingChecksum)) }

DesyncBugReport : {
    kind : [Desync, MissingChecksum],
    remote_sync_tick : U64,
    remote_sync_tick_checksum : I64,
    local_matching_checksum : Result I64 [NotFound],
    history : Str,
    crash_info : Str,
}

# DEBUG HELPERS

show_crash_info : Recording -> Str
show_crash_info = |@Recording(recorded_state)|
    internal_show_crash_info(recorded_state)

internal_show_crash_info : RecordedWorld -> Str
internal_show_crash_info = |world|
    received_inputs_range =
        first = NonEmptyList.first(world.received_inputs) |> .input_tick
        last = NonEmptyList.last(world.received_inputs) |> .input_tick
        (first, last)

    snapshots_range =
        first = NonEmptyList.first(world.snapshots) |> .tick
        last = NonEmptyList.last(world.snapshots) |> .tick
        (first, last)

    crash_info = {
        tick: world.tick,
        remote_tick: world.remote_tick,
        sync_tick: world.sync_tick,
        sync_tick_snapshot: world.sync_tick_snapshot,
        local_pos: world.state.local_player.pos,
        remote_pos: world.state.remote_player.pos,
        rollback_log: world.rollback_log,
        received_inputs_range,
        snapshots_range,
    }

    Inspect.to_str(crash_info)

## Creates a multi-line json log of snapshotted inputs.
## This allows creating diffable input logs from multiple clients when debugging.
writable_history : Recording -> Str
writable_history = |@Recording(recorded_state)|
    internal_writable_history(recorded_state)

internal_writable_history : RecordedWorld -> Str
internal_writable_history = |{ snapshots }|
    write_input : Input -> Str
    write_input = |input|
        up = if input.up == Down then Ok("Up") else Err(Up)
        down = if input.down == Down then Ok("Down") else Err(Up)
        left = if input.left == Down then Ok("Left") else Err(Up)
        right = if input.right == Down then Ok("Right") else Err(Up)

        [up, down, left, right]
        |> List.keep_oks(|res| res)
        |> Str.join_with(", ")
        |> |inputs| "[${inputs}]"

    input_snapshot : Snapshot -> _
    input_snapshot = |snap| {
        tick: snap.tick,
        local_input: write_input(snap.local_input),
        remote_input: write_input(snap.remote_input),
    }

    position_snapshot : Snapshot -> _
    position_snapshot = |snap| {
        tick: snap.tick,
        local_pos: Inspect.to_str(snap.state.local_player.pos),
        remote_pos: Inspect.to_str(snap.state.remote_player.pos),
    }

    to_utf8_unchecked = |bytes|
        when Str.from_utf8(bytes) is
            Ok(str) -> str
            Err(_) -> crash("toUtf8Unchecked")

    write_snapshot : Snapshot -> Str
    write_snapshot = |snap|
        input_json =
            snap
            |> input_snapshot
            |> Encode.to_bytes(Json.utf8)
            |> to_utf8_unchecked

        position_json =
            snap
            |> position_snapshot
            |> Encode.to_bytes(Json.utf8)
            |> to_utf8_unchecked

        "${input_json}\n${position_json}"

    snapshots
    |> NonEmptyList.to_list
    |> List.map(write_snapshot)
    |> Str.join_with("\n")
