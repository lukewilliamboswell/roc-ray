platform "roc-ray"
    requires { Model } {
        init! : {} => Result Model [],
        render! : Model, RocRay.PlatformState => Result Model [],
    }
    exposes [
        RocRay,
        Camera,
        Draw,
        Keys,
        Mouse,
        Music,
        Network,
        RenderTexture,
        Sound,
        Texture,
    ]
    packages {}
    imports []
    provides [initForHost!, renderForHost!]

import RocRay
import Mouse
import InternalKeyboard
import InternalMouse
import Effect
import Network

PlatformStateFromHost : {
    frameCount : U64,
    keys : List U8,
    mouseButtons : List U8,
    timestampMillis : U64,
    mousePosX : F32,
    mousePosY : F32,
    mouseWheel : F32,
    peers : PeerState,
    messages : List Effect.PeerMessage,
}

PeerState : {
    connected : List Effect.RawUUID,
    disconnected : List Effect.RawUUID,
}

initForHost! : I32 => Box Model
initForHost! = \_x ->
    init! {}
    |> \result ->
        when result is
            Ok m -> Box.box m
            Err err ->
                Effect.log! (Inspect.toStr err) (Effect.toLogLevel LogError)
                Effect.exit! {}
                crash "unreachable"

renderForHost! : Box Model, PlatformStateFromHost => Box Model
renderForHost! = \boxedModel, platformState ->
    model = Box.unbox boxedModel

    { timestampMillis, messages, frameCount, keys, peers, mouseButtons, mousePosX, mousePosY, mouseWheel } = platformState

    state : RocRay.PlatformState
    state = {
        timestampMillis,
        frameCount,
        keys: InternalKeyboard.pack keys,
        mouse: {
            position: { x: mousePosX, y: mousePosY },
            buttons: mouseButtonsForApp { mouseButtons },
            wheel: mouseWheel,
        },
        network: {
            peers: {
                connected: peers.connected |> List.map Network.fromU64Pair,
                disconnected: peers.disconnected |> List.map Network.fromU64Pair,
            },
            messages: messages |> List.map \{ id, bytes } -> { id: Network.fromU64Pair id, bytes },
        },
    }

    render! model state
    |> \result ->
        when result is
            Ok m -> Box.box m
            Err err ->
                Effect.log! (Inspect.toStr err) (Effect.toLogLevel LogError)
                Effect.exit! {}
                crash "unreachable"

mouseButtonsForApp : { mouseButtons : List U8 } -> Mouse.Buttons
mouseButtonsForApp = \{ mouseButtons } ->
    buttonsToStates : Dict InternalMouse.MouseButton Mouse.ButtonState
    buttonsToStates =
        mouseButtons
        |> List.map InternalMouse.mouseButtonStateFromU8
        |> List.mapWithIndex \s, i -> (InternalMouse.mouseButtonFromU64 i, s)
        |> Dict.fromList

    stateOf : InternalMouse.MouseButton -> Mouse.ButtonState
    stateOf = \button ->
        Dict.get buttonsToStates button
        |> Result.withDefault Up

    {
        left: stateOf MouseButtonLeft,
        right: stateOf MouseButtonRight,
        middle: stateOf MouseButtonMiddle,
        side: stateOf MouseButtonSide,
        extra: stateOf MouseButtonExtra,
        forward: stateOf MouseButtonForward,
        back: stateOf MouseButtonBack,
    }
