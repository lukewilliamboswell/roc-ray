platform "roc-ray"
    requires { Model } { main : Program Model _ }
    exposes [RocRay]
    packages {}
    imports []
    provides [forHost]

import RocRay exposing [Program]
import RocRay.Mouse as Mouse
import RocRay.Keys as Keys
import InternalKeyboard
import InternalMouse
import Effect

PlatformStateFromHost : {
    frameCount : U64,
    keys : List U8,
    mouseButtons : List U8,
    timestampMillis : U64,
    mousePosX : F32,
    mousePosY : F32,
    mouseWheel : F32,
}

ProgramForHost model : {
    init : Task (Box model) {},
    render : Box model, PlatformStateFromHost -> Task (Box model) {},
}

forHost : ProgramForHost _
forHost = { init, render }

init : Task (Box Model) {}
init =
    Task.attempt main.init \result ->
        when result is
            Ok m -> Task.ok (Box.box m)
            Err err ->
                Effect.log! (Inspect.toStr err) (Effect.toLogLevel LogError)
                Effect.exit!
                Task.err {}

render : Box Model, PlatformStateFromHost -> Task (Box Model) {}
render = \boxedModel, platformState ->
    model = Box.unbox boxedModel

    { timestampMillis, frameCount, keys, mouseButtons, mousePosX, mousePosY, mouseWheel } = platformState

    state : RocRay.PlatformState
    state = {
        timestampMillis,
        frameCount,
        keys: keysForApp { keys },
        mouse: {
            position: { x: mousePosX, y: mousePosY },
            buttons: mouseButtonsForApp { mouseButtons },
            wheel: mouseWheel,
        },
    }

    Task.attempt (main.render model state) \result ->
        when result is
            Ok m -> Task.ok (Box.box m)
            Err err ->
                Effect.log! (Inspect.toStr err) (Effect.toLogLevel LogError)
                Effect.exit!
                Task.err {}

keysForApp : { keys : List U8 } -> Keys.Keys
keysForApp = \{ keys } ->
    keys
    |> List.map InternalKeyboard.keyStateFromU8
    |> List.mapWithIndex \s, i -> (InternalKeyboard.keyFromU64 i, s)
    |> List.keepOks \(recognized, s) ->
        Result.map recognized \key -> (key, s)
    |> Dict.fromList

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
