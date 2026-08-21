app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-19-edec830" }

# Finalizing a recording is an encode and a file write. As an effect it was
# reachable from `render!`, which put both in the middle of drawing a frame, at
# a point in the draw order nothing else could observe. Starting and stopping
# are commands now, and there is no effectful form left to call.
import rr.Capture
import rr.App
import rr.Draw

Model : {}

program = { init!, update, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({}))

Msg : []

update : Model, App.Input(Msg) -> App.Transition(Model, Msg)
update = |model, _input| App.next(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| {
	Capture.stop!()?
	Ok({})
}
