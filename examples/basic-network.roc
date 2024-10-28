app [Model, init, render] { rr: platform "../platform/main.roc" }

import rr.RocRay
import rr.Keys
import rr.Draw
import rr.Network exposing [UUID]

width = 400
height = 400

TimeStampMillis : U64

Model : {
    messageLog : List (TimeStampMillis, Network.UUID, Str),
}

init : Task Model []
init =

    RocRay.setTargetFPS! 30
    RocRay.displayFPS! { fps: Visible, pos: { x: width - 80, y: height - 20 } }
    RocRay.initWindow! { title: "Basic WebRTC Networking", width, height }

    Task.ok {
        messageLog: [],
    }

render : Model, RocRay.PlatformState -> Task Model []
render = \model, { timestampMillis, keys, network } ->

    message =
        if Keys.pressed keys KeyUp then
            "KeyUp"
        else if Keys.pressed keys KeyDown then
            "KeyDown"
        else if Keys.pressed keys KeyLeft then
            "KeyLeft"
        else if Keys.pressed keys KeyRight then
            "KeyRight"
        else
            ""

    sendTask =
        if Str.isEmpty message then
            Task.ok {}
        else
            Task.forEach network.peers.connected \peer ->
                Str.toUtf8 message |> RocRay.sendToPeer peer

    sendTask!

    messageLog =
        List.walk network.messages model.messageLog \log, { id, bytes } ->
            msgStr = bytes |> Str.fromUtf8 |> Result.withDefault "BAD UTF-8"
            msg = (timestampMillis, id, msgStr)

            List.append log msg

    Draw.draw! White \{} ->

        Draw.text! { pos: { x: 10, y: 10 }, text: "Basic Networking", size: 20, color: Navy }
        Draw.text! { pos: { x: 10, y: 30 }, text: "Use arrow keys to send a message", size: 10, color: Green }
        Draw.text! { pos: { x: 10, y: 40 }, text: "MSG LOG: $(Num.toStr (List.len model.messageLog)) messages", size: 10, color: Red }
        Draw.text! { pos: { x: 10, y: 50 }, text: "SENT MSG: $(message)", size: 10, color: Red }

        displayPeerConnections! network.peers
        displayMessages! model.messageLog

    Task.ok { model & messageLog }

displayPeerConnections :
    {
        connected : List UUID,
        disconnected : List UUID,
    }
    -> Task {} _
displayPeerConnections = \{ connected, disconnected } ->

    combined =
        List.concat
            (connected |> List.map \uuid -> "CONNECTED: $(Network.toStr uuid)")
            (disconnected |> List.map \uuid -> "DISCONNECTED: $(Network.toStr uuid)")
        |> List.append "NETWORK PEERS $(Num.toStr (List.len connected)) connected, $(Num.toStr (List.len disconnected)) disconnected"
        |> List.reverse

    List.range { start: At 0, end: Before (List.len combined) }
    |> List.map \i -> {
        pos: { x: 10, y: 70 + Num.toFrac (i * 10) },
        text: List.get combined i |> Result.withDefault "OUT OF BOUNDS",
        size: 10,
        color: Black,
    }
    |> Task.forEach Draw.text

displayMessages : List (TimeStampMillis, Network.UUID, Str) -> Task {} _
displayMessages = \messages ->

    messages
        |> List.mapWithIndex \(time, peer, str), i -> {
            pos: { x: 10, y: 100 + Num.toFrac (i * 10) },
            text: "$(Num.toStr time) $(Network.toStr peer): $(str)",
            size: 10,
            color: Black,
        }
        |> Task.forEach! Draw.text

    Task.ok {}
