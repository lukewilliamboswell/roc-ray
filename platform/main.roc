platform "roc-ray"
    requires { Model } {
        init : Task state []err,
        render : state, RocRay.PlatformState -> Task state []err,
    }
    exposes [RocRay, Keys, Mouse]
    packages {}
    imports []
    provides [forHost]

import RocRay
import Mouse
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
    initForHost : Task (Box model) {},
    renderForHost : Box model, PlatformStateFromHost -> Task (Box model) {},
}

forHost : ProgramForHost _
forHost = { initForHost, renderForHost }

initForHost : Task (Box Model) {}
initForHost =
    Task.attempt init \result ->
        when result is
            Ok m -> Task.ok (Box.box m)
            Err err ->
                Effect.log! (Inspect.toStr err) (Effect.toLogLevel LogError)
                Effect.exit!
                Task.err {}

renderForHost : Box Model, PlatformStateFromHost -> Task (Box Model) {}
renderForHost = \boxedModel, platformState ->
    model = Box.unbox boxedModel

    { timestampMillis, frameCount, keys, mouseButtons, mousePosX, mousePosY, mouseWheel } = platformState

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
    }

    Task.attempt (render model state) \result ->
        when result is
            Ok m -> Task.ok (Box.box m)
            Err err ->
                Effect.log! (Inspect.toStr err) (Effect.toLogLevel LogError)
                Effect.exit!
                Task.err {}

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
