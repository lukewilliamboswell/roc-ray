platform "roc-ray"
    requires { Model } { main : Program Model }
    exposes [Raylib, GUI, Action, Task, Layout]
    packages {}
    imports []
    provides [mainForHost]

import Raylib exposing [Program]
import InternalKeyboard

ProgramForHost : {
    init : Task (Box Model) {},
    update : Box Model, List U64 -> Task (Box Model) {},
}

mainForHost : ProgramForHost
mainForHost = { init, update }

init : Task (Box Model) {}
init = main.init |> Task.map Box.box

update : Box Model, List U64 -> Task (Box Model) {}
update = \boxedModel, keysDownU64 ->

    keysDown = keysDownU64 |> List.map InternalKeyboard.keyFromU64 |> Set.fromList
    model = Box.unbox boxedModel

    main.render model keysDown
    |> Task.map Box.box
