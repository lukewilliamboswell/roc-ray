app [Model, init!, render!] {
    rr: platform "../../platform/main.roc",
    json: "https://github.com/lukewilliamboswell/roc-json/releases/download/0.12.0/1trwx8sltQ-e9Y2rOB4LWUWLS_sFVyETK8Twl0i9qpw.tar.gz",
}

### This is an example of using RocRay's matchbox networking integration for a peer-to-peer multiplayer game.
### The Rollback module is based on pseudocode from the Guilty Gear Strive team.
### Note that this version relies on TCP for handling message ordering and packet loss.
### In a real game or polished networking library, you'd likely do many things differently.
###
### Matchbox WebRTC: https://github.com/johanhelsing/matchbox
### GGST's Rollback Pseudocode: https://gist.github.com/rcmagic/f8d76bca32b5609e85ab156db38387e9
### An explanation of fixed timestep: https://gafferongames.com/post/fix_your_timestep/

import rr.RocRay exposing [Texture, Rectangle, PlatformState]
import rr.Draw
import rr.Texture
import rr.Network

import json.Json

import Resolution exposing [width, height]
import Rollback
import Pixel
import Input
import World
import Config

Model : [Waiting WaitingModel, Connected ConnectedModel]

WaitingModel : {
    dude : Texture,
}

ConnectedModel : {
    dude : Texture,
    world : Rollback.Recording,
    timestamp_millis : U64,
}

init! : {} => Result Model _
init! = |{}|
    server_url = "${Config.base_url}/yolo?next=2"

    RocRay.set_target_fps!(120)
    RocRay.display_fps!({ fps: Visible, pos: { x: 100, y: 100 } })
    Network.configure!({ server_url })
    RocRay.init_window!(
        {
            title: "Rollback Example",
            width: Num.to_f32(width),
            height: Num.to_f32(height),
        },
    )

    dude = Texture.load!("examples/assets/sprite-dude/sheet.png")?

    waiting : WaitingModel
    waiting = { dude }

    Ok(Waiting(waiting))

render! : Model, RocRay.PlatformState => Result Model []
render! = |model, state|
    when model is
        Waiting(waiting) -> render_waiting!(waiting, state)
        Connected(connected) -> render_connected!(connected, state)

draw_connected! : ConnectedModel, PlatformState => {}
draw_connected! = |{ dude, world }, state|
    Draw.draw!(
        White,
        |{}|
            Draw.text!({ pos: { x: 10, y: 10 }, text: "Rocci the Cool Dude", size: 40, color: Navy })
            Draw.text!({ pos: { x: 10, y: 50 }, text: "Use arrow keys to walk around", size: 20, color: Green })

            current_state = Rollback.current_state(world)

            # draw local player
            local_player = current_state.local_player
            local_player_facing = World.player_facing(local_player)
            Draw.texture_rec!(
                {
                    texture: dude,
                    source: dude_sprite(local_player_facing, local_player.animation.frame),
                    pos: Pixel.to_vector2(local_player.pos),
                    tint: White,
                },
            )

            # draw remote player
            remote_player = current_state.remote_player
            remote_player_id_pos = Pixel.to_vector2(remote_player.pos)
            Draw.text!(
                {
                    pos: remote_player_id_pos,
                    text: "remote player",
                    size: 10,
                    color: Red,
                },
            )
            remote_player_facing = World.player_facing(remote_player)
            Draw.texture_rec!(
                {
                    texture: dude,
                    source: dude_sprite(remote_player_facing, remote_player.animation.frame),
                    pos: Pixel.to_vector2(remote_player.pos),
                    tint: Red,
                },
            )

            # draw ui

            when Rollback.desync_status(world) is
                Synced -> {}
                Desynced(report) ->
                    text =
                        tick = Inspect.to_str(report.remote_sync_tick)
                        when report.kind is
                            Desync -> "DESYNC DETECTED ON TICK: ${tick}"
                            MissingChecksum -> "MISSING CHECKSUM FOR TICK: ${tick}"

                    Draw.text!(
                        {
                            text,
                            pos: { x: 10, y: Num.to_f32(height) - 50 },
                            size: 16,
                            color: Red,
                        },
                    )

            display_peer_connections!(state.network.peers),
    )

render_waiting! : WaitingModel, PlatformState => Result Model []
render_waiting! = |waiting, state|
    inbox : List Rollback.PeerMessage
    inbox = decode_frame_messages(state.network.messages)

    join_message = List.last(inbox)

    when join_message is
        Ok(_message) ->
            waiting_to_connected!(waiting, state)

        Err(ListWasEmpty) ->
            send_host_waiting!(state.network)
            draw_waiting!(waiting)
            Ok(Waiting(waiting))

        Err(Leftover(_)) | Err(TooShort) ->
            RocRay.log!("decode error", LogError)
            send_host_waiting!(state.network)
            draw_waiting!(waiting)
            Ok(Waiting(waiting))

waiting_to_connected! : WaitingModel, PlatformState => Result Model []
waiting_to_connected! = |waiting, state|
    world : Rollback.Recording
    world = Rollback.start(
        {
            config: Config.rollback,
            state: World.initial,
        },
    )

    connected : ConnectedModel
    connected = {
        world,
        dude: waiting.dude,
        timestamp_millis: state.timestamp.render_start,
    }

    draw_connected!(connected, state)

    Ok(Connected(connected))

draw_waiting! : WaitingModel => {}
draw_waiting! = |waiting|
    Draw.draw!(
        Silver,
        |{}|
            Draw.text!({ pos: { x: 10, y: 10 }, text: "Rocci the Cool Dude", size: 40, color: Navy })
            Draw.text!({ pos: { x: 10, y: 50 }, text: "Use arrow keys to walk around", size: 20, color: Green })

            local_player = World.player_start
            player_facing = World.player_facing(local_player)
            Draw.texture_rec!(
                {
                    texture: waiting.dude,
                    source: dude_sprite(player_facing, local_player.animation.frame),
                    pos: Pixel.to_vector2(local_player.pos),
                    tint: Silver,
                },
            ),
    )

render_connected! : ConnectedModel, PlatformState => Result Model []
render_connected! = |old_model, state|
    timestamp_millis = state.timestamp.render_start
    network = state.network

    delta_millis = timestamp_millis - old_model.timestamp_millis

    inbox : List Rollback.PeerMessage
    inbox = decode_frame_messages(network.messages)

    local_input = Input.read(state.keys)

    world = Rollback.advance(old_model.world, { local_input, delta_millis, inbox })

    model = { old_model & world, timestamp_millis }

    messages = Rollback.recent_messages(world)
    send_frame_messages!(messages, network)

    draw_connected!(model, state)

    when Rollback.block_status(world) is
        Advancing -> {}
        Skipped -> {}
        BlockedFor(blocked_frames) if blocked_frames < 50 ->
            {}

        BlockedFor(blocked_frames) if blocked_frames < 500 ->
            RocRay.log!("Blocked for ${Inspect.to_str(blocked_frames)} frames", LogWarning)

        BlockedFor(_blockedFrames) ->
            crash_info = Rollback.show_crash_info(world)
            history = Rollback.writable_history(world)
            crash("blocked world:\n${crash_info}\n${history}")

    Ok(Connected(model))

dude_sprite : World.Facing, U8 -> Rectangle
dude_sprite = |sequence, frame|
    when sequence is
        Up -> sprite64x64source({ row: 8, col: frame % 9 })
        Down -> sprite64x64source({ row: 10, col: frame % 9 })
        Left -> sprite64x64source({ row: 9, col: frame % 9 })
        Right -> sprite64x64source({ row: 11, col: frame % 9 })

# get the pixel coordinates of a 64x64 sprite in the spritesheet
sprite64x64source : { row : U8, col : U8 } -> Rectangle
sprite64x64source = |{ row, col }| {
    x: 64 * (Num.to_f32(col)),
    y: 64 * (Num.to_f32(row)),
    width: 64,
    height: 64,
}

display_peer_connections! : RocRay.NetworkPeers => {}
display_peer_connections! = |{ connected, disconnected }|
    combined =
        List.concat(
            (connected |> List.map(|uuid| "CONNECTED: ${Network.to_str(uuid)}")),
            (disconnected |> List.map(|uuid| "DISCONNECTED: ${Network.to_str(uuid)}")),
        )
        |> List.append("NETWORK PEERS ${Num.to_str(List.len(connected))} connected, ${Num.to_str(List.len(disconnected))} disconnected")

    List.range({ start: At(0), end: Before(List.len(combined)) })
    |> List.map(
        |i| {
            pos: { x: 10, y: (Num.to_f32(height)) - 10 - (Num.to_frac((i * 10))) },
            text: List.get(combined, i) |> Result.with_default("OUT OF BOUNDS"),
            size: 10,
            color: Black,
        },
    )
    |> for_each!(Draw.text!)

send_host_waiting! : RocRay.NetworkState => {}
send_host_waiting! = |network|
    waiting_message : Rollback.FrameMessage
    waiting_message =
        sync_tick_checksum = World.positions_checksum(
            {
                local_player_pos: World.player_start.pos,
                remote_player_pos: World.player_start.pos,
            },
        )

        {
            first_tick: 0,
            last_tick: 0,
            tick_advantage: 0,
            input: Input.blank,
            sync_tick: 0,
            sync_tick_checksum,
        }

    send_frame_messages!([waiting_message], network)

send_frame_messages! : List Rollback.FrameMessage, RocRay.NetworkState => {}
send_frame_messages! = |messages, network|
    json_messages = List.map(messages, world_to_network)
    bytes = Encode.to_bytes(json_messages, Json.utf8)
    for_each!(network.peers.connected, |peer| RocRay.send_to_peer!(bytes, peer))

decode_frame_messages : List RocRay.NetworkMessage -> List Rollback.PeerMessage
decode_frame_messages = |messages|
    List.join_map(
        messages,
        |network_msg|
            decode_result : Result (List FrameMessageJson) _
            decode_result = Decode.from_bytes(network_msg.bytes, Json.utf8)

            when decode_result is
                Ok(json_array) ->
                    List.map(
                        json_array,
                        |json|
                            { id: network_msg.id, message: network_to_world(json) },
                    )

                Err(e) ->
                    crash_info = Inspect.to_str(
                        {
                            decode_error: e,
                            network_message: Str.from_utf8(network_msg.bytes),
                        },
                    )
                    crash("decode error: ${crash_info}"),
    )

FrameMessageJson : {
    first_tick : I64,
    last_tick : I64,
    tick_advantage : I64,
    input_byte : I64,
    sync_tick : I64,
    sync_tick_checksum : I64,
}

network_to_world : FrameMessageJson -> Rollback.FrameMessage
network_to_world = |json| {
    input: json.input_byte |> Num.to_u8 |> Input.from_byte,
    first_tick: json.first_tick,
    last_tick: json.last_tick,
    tick_advantage: json.tick_advantage,
    sync_tick: json.sync_tick,
    sync_tick_checksum: json.sync_tick_checksum,
}

world_to_network : Rollback.FrameMessage -> FrameMessageJson
world_to_network = |message| {
    input_byte: message.input |> Input.to_byte |> Num.to_i64,
    first_tick: message.first_tick,
    last_tick: message.last_tick,
    tick_advantage: message.tick_advantage,
    sync_tick: message.sync_tick,
    sync_tick_checksum: message.sync_tick_checksum,
}

# TODO REPLACE WITH BUILTIN
for_each! : List a, (a => {}) => {}
for_each! = |l, f!|
    when l is
        [] -> {}
        [x, .. as xs] ->
            f!(x)
            for_each!(xs, f!)
