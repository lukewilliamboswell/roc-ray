platform "roc-ray"
    requires { Model } { main : Program Model }
    exposes [Raylib, GUI, Action, Task, Layout]
    packages {}
    imports []
    provides [mainForHost]

import Raylib exposing [Program]

ProgramForHost : {
    init : Task (Box Model) {},
    update : Box Model -> Task (Box Model) {},
}

mainForHost : ProgramForHost
mainForHost = { init, update }

init : Task (Box Model) {}
init = main.init |> Task.map Box.box

update : Box Model -> Task (Box Model) {}
update = \boxedModel ->
    boxedModel
    |> Box.unbox
    |> main.render
    |> Task.map Box.box
