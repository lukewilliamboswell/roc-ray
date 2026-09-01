app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-31-86e69b4" }

# `update!` is effectful: host state changes are direct calls and deferred
# work goes through `Task.spawn!`. The pure-update `Transition` builder is
# gone, and this checks it stays gone rather than quietly coming back as a
# second way to describe the same work.
import rr.App
import rr.Draw

Model : {}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({}))

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| {
	_ = App.next(model)
	Ok(model)
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
