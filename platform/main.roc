platform "roc-ray"
    requires { Model } {
        init! : {} => Result Model []_,
        render! : Model, RocRay.PlatformState => Result Model []_,
    }
    exposes [
        RocRay,
        Camera,
        Draw,
        Font,
        Keys,
        Mouse,
        Music,
        Network,
        RenderTexture,
        Sound,
        Texture,
        Time,
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

initForHost! : I32 => Result (Box Model) Str
initForHost! = \_x ->
    init! {}
    |> Result.map Box.box
    |> Result.mapErr Inspect.toStr

renderForHost! : Box Model, Effect.PlatformStateFromHost => Result (Box Model) Str
renderForHost! = \boxedModel, { frameCount, keys, mouseButtons, timestamp, mousePosX, mousePosY, mouseWheel, peers, messages } ->
    model = Box.unbox boxedModel

    state : RocRay.PlatformState
    state = {
        frameCount,
        keys: InternalKeyboard.pack keys,
        timestamp,
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
    |> Result.map Box.box
    |> Result.mapErr Inspect.toStr

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
