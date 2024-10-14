platform "roc-ray"
    requires { Model } { main : Program Model _ }
    exposes [Raylib, GUI, Action, Task, Layout]
    packages {}
    imports []
    provides [mainForHost]

import Raylib exposing [Program]
import InternalKeyboard
import InternalMouse
import Effect

PlatformStateFromHost : {
    nanosTimestampUtc : I128,
    frameCount : U64,
    keysDownU64 : List U64,
    mouseDownU64 : List U64,
    mousePosX : F32,
    mousePosY : F32,
}

ProgramForHost : {
    init : Task (Box Model) {},
    update : Box Model, PlatformStateFromHost -> Task (Box Model) {},
}

mainForHost : ProgramForHost
mainForHost = { init, update }

init : Task (Box Model) {}
init =
    Task.attempt main.init \result ->
        when result is
            Ok m -> Task.ok (Box.box m)
            Err err ->
                Effect.log! (Inspect.toStr err) (Effect.toLogLevel LogError)
                Effect.exit!
                Task.err {}

update : Box Model, PlatformStateFromHost -> Task (Box Model) {}
update = \boxedModel, platformState ->

    model = Box.unbox boxedModel

    { nanosTimestampUtc, frameCount, keysDownU64, mouseDownU64, mousePosX, mousePosY } = platformState

    keyboardButtons = keysDownU64 |> List.map InternalKeyboard.keyFromU64 |> Set.fromList
    mouseButtons = mouseDownU64 |> List.map InternalMouse.mouseButtonFromU64 |> Set.fromList

    state : Raylib.PlatformState
    state = {
        nanosTimestampUtc,
        frameCount,
        keyboardButtons,
        mouseButtons,
        mousePos: {
            x: mousePosX,
            y: mousePosY,
        },
    }

    Task.attempt (main.render model state) \result ->
        when result is
            Ok m -> Task.ok (Box.box m)
            Err err ->
                Effect.log! (Inspect.toStr err) (Effect.toLogLevel LogError)
                Effect.exit!
                Task.err {}
