platform "roc-ray"
    requires { Model } { main : Program Model }
    exposes [Core, GUI, Action, Task, Drawable, Shape2D, Layout]
    packages {}
    imports [Core.{Program}, Task.{ Task }]
    provides [mainForHost]

ProgramForHost : {
    init : Task (Box Model) [],
    update : Box Model -> Task (Box Model) [],
}

mainForHost : ProgramForHost
mainForHost = { init, update }

init : Task (Box Model) []
init = main.init |> Task.map Box.box

update : Box Model -> Task (Box Model) []
update = \boxedModel ->
    boxedModel
    |> Box.unbox
    |> main.render
    |> Task.map Box.box
