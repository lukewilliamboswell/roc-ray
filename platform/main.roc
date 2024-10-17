platform "roc-ray"
    requires { Model } { main : Program Model _ }
    exposes [RocRay]
    packages {}
    imports []
    provides [forHost]

import RocRay exposing [Program]
import RocRay.Mouse as Mouse
import InternalKeyboard
import InternalMouse
import Effect

PlatformStateFromHost : {
    timestampMillis : U64,
    frameCount : U64,
    keysDownU64 : List U64,
    mouseDownBool : List Bool,
    mousePressedBool : List Bool,
    mouseReleasedBool : List Bool,
    mouseUpBool : List Bool,
    mousePosX : F32,
    mousePosY : F32,
}

ProgramForHost : {
    init : Task (Box Model) {},
    render : Box Model, PlatformStateFromHost -> Task (Box Model) {},
}

forHost : ProgramForHost
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

    { timestampMillis, frameCount, keysDownU64, mouseDownBool, mousePressedBool, mouseUpBool, mouseReleasedBool, mousePosX, mousePosY } = platformState

    mouseFlagsToSet : List Bool -> Set InternalMouse.MouseButton
    mouseFlagsToSet = \flags ->
        flags
        |> List.mapWithIndex \flagged, i -> (flagged, i)
        |> List.keepOks \(flagged, i) ->
            if flagged then Ok (InternalMouse.mouseButtonFromU64 i) else Err Other
        |> Set.fromList

    mouseButtonSets = {
        down: mouseFlagsToSet mouseDownBool,
        up: mouseFlagsToSet mouseUpBool,
        pressed: mouseFlagsToSet mousePressedBool,
        released: mouseFlagsToSet mouseReleasedBool,
    }

    mouseButtons : Mouse.Buttons
    mouseButtons =
        stateOf = \button ->
            if Set.contains mouseButtonSets.pressed button then
                Pressed
            else if Set.contains mouseButtonSets.released button then
                Released
            else if Set.contains mouseButtonSets.down button then
                Down
            else
                Up

        {
            left: stateOf MouseButtonLeft,
            right: stateOf MouseButtonRight,
            middle: stateOf MouseButtonMiddle,
            side: stateOf MouseButtonSide,
            extra: stateOf MouseButtonExtra,
            forward: stateOf MouseButtonForward,
            back: stateOf MouseButtonBack,
        }

    keyboardButtons =
        keysDownU64 |> List.map InternalKeyboard.keyFromU64 |> Set.fromList

    state : RocRay.PlatformState
    state = {
        timestampMillis,
        frameCount,
        keyboardButtons,
        mouse: {
            position: { x: mousePosX, y: mousePosY },
            buttons: mouseButtons,
        },
    }

    Task.attempt (main.render model state) \result ->
        when result is
            Ok m -> Task.ok (Box.box m)
            Err err ->
                Effect.log! (Inspect.toStr err) (Effect.toLogLevel LogError)
                Effect.exit!
                Task.err {}
