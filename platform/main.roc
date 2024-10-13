platform "roc-ray"
    requires { Model } { main : Program Model }
    exposes [Raylib, GUI, Action, Task, Layout]
    packages {}
    imports []
    provides [mainForHost]

import Raylib exposing [Program]
import InternalKeyboard
import InternalMouse

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
init = main.init |> Task.map Box.box

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

    main.render model state
    |> Task.map Box.box
