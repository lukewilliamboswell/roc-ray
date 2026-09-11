app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-09-07-14d9829" }

# `App.Input` is a pure platform value, so it has
# no effectful receivers. `Task.spawn!(input, || ...)` is the only way to start
# a task, and this checks that the receiver form stays gone rather than coming
# back as a second spelling of the same effect.
import rr.App
import rr.Draw

Model : {}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |io| Ok({}))

Msg : [Woke]

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64), ..])
update! = |model, input, io| {
	input.spawn!(|| Woke)
	Ok(model)
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
