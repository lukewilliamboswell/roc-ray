app [Model, program] { rr: platform "../../platform/main.roc" }

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
init! = App.init(App.default, |_startup| Ok({}))

update : Model, Program.Step -> Try(Program.Next(Model), [Exit(I64), ..])
update = |model, _step| Ok({ model, actions: [], tasks: Program.no_tasks })

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| {
	Capture.stop!()?
	Ok({})
}
