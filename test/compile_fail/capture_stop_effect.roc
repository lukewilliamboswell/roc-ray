app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-12-606470f" }

# Finalizing a recording is an encode and a file write. As an effect it was
# reachable from `render!`, which put both in the middle of drawing a frame, at
# a point in the draw order nothing else could observe. Starting and stopping
# are actions now, and there is no effectful form left to call.
import rr.Capture
import rr.App
import rr.Draw
import rr.Program

Model : {}

program = { init!, update, render! }

init! : App.Init(Model, [])
init! = App.init(App.static_config(App.default), |_startup| Ok({}))

Msg : []

update : Model, Program.Step(Msg) -> Program.Update(Model, Msg)
update = |model, _step| Program.static(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| {
	Capture.stop!()?
	Ok({})
}
