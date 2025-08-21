app [Model, init!, render!] { rr: platform "../platform/main.roc" }

import rr.RocRay
import rr.Keys
import rr.Draw
import rr.Network exposing [UUID]

width = 400
height = 400

TimeStampMillis : U64

Model : {
    message_log : List (TimeStampMillis, Network.UUID, Str),
}

init! : {} => Result Model []
init! = |{}|

    RocRay.set_target_fps!(30)

    RocRay.display_fps!({ fps: Visible, pos: { x: width - 80, y: height - 20 } })

    Network.configure!({ server_url: "ws://localhost:3536/yolo?next=2" })

    RocRay.init_window!({ title: "Basic WebRTC Networking", width, height })

    Ok(
        {
            message_log: [],
        },
    )

render! : Model, RocRay.PlatformState => Result Model []
render! = |model, { timestamp, keys, network }|

    message =
        if Keys.pressed(keys, KeyUp) then
            "KeyUp"
        else if Keys.pressed(keys, KeyDown) then
            "KeyDown"
        else if Keys.pressed(keys, KeyLeft) then
            "KeyLeft"
        else if Keys.pressed(keys, KeyRight) then
            "KeyRight"
        else
            ""

    if !(Str.is_empty(message)) then
        List.for_each!(
            network.peers.connected,
            |peer|
                Str.to_utf8(message) |> RocRay.send_to_peer!(peer),
        )
    else
        {}

    message_log =
        List.walk(
            network.messages,
            model.message_log,
            |log, { id, bytes }|
                msg_str = bytes |> Str.from_utf8 |> Result.with_default("BAD UTF-8")
                msg = (timestamp.render_start, id, msg_str)

                List.append(log, msg),
        )

    Draw.draw!(
        White,
        |{}|

            Draw.text!({ pos: { x: 10, y: 10 }, text: "Basic Networking", size: 20, color: Navy })
            Draw.text!({ pos: { x: 10, y: 30 }, text: "Use arrow keys to send a message", size: 10, color: Green })
            Draw.text!({ pos: { x: 10, y: 40 }, text: "MSG LOG: ${Num.to_str(List.len(model.message_log))} messages", size: 10, color: Red })
            Draw.text!({ pos: { x: 10, y: 50 }, text: "SENT MSG: ${message}", size: 10, color: Red })

            display_peer_connections!(network.peers)
            display_messages!(model.message_log),
    )

    Ok({ model & message_log })

display_peer_connections! : { connected : List UUID, disconnected : List UUID } => {}
display_peer_connections! = |{ connected, disconnected }|

    combined =
        List.concat(
            (connected |> List.map(|uuid| "CONNECTED: ${Network.to_str(uuid)}")),
            (disconnected |> List.map(|uuid| "DISCONNECTED: ${Network.to_str(uuid)}")),
        )
        |> List.append("NETWORK PEERS ${Num.to_str(List.len(connected))} connected, ${Num.to_str(List.len(disconnected))} disconnected")
        |> List.reverse

    List.range({ start: At(0), end: Before(List.len(combined)) })
    |> List.map(
        |i| {
            pos: { x: 10, y: 70 + Num.to_frac((i * 10)) },
            text: List.get(combined, i) |> Result.with_default("OUT OF BOUNDS"),
            size: 10,
            color: Black,
        },
    )
    |> List.for_each!(Draw.text!)

display_messages! : List (TimeStampMillis, Network.UUID, Str) => {}
display_messages! = |messages|

    messages
    |> List.map_with_index(
        |(time, peer, str), i| {
            pos: { x: 10, y: 100 + Num.to_frac((i * 10)) },
            text: "${Num.to_str(time)} ${Network.to_str(peer)}: ${str}",
            size: 10,
            color: Black,
        },
    )
    |> List.for_each!(Draw.text!)
