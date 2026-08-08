app [Model, program] { rr: platform "../../platform/main.roc" }

# A blob handle is a scalar the host validates, so an app that could name the
# transport module could hand-assemble one and ask the host to read whatever it
# resolved to. It cannot: `FileHost` is not exposed, and `File.Blob` can only be
# built from a `FileHost.Blob` nobody outside the platform can construct.
import rr.App
import rr.Draw
import rr.FileHost
import rr.Program

Model : {}

program = { init!, update, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({}))

update : Model, Program.Step -> Try(Program.Next(Model), [Exit(I64), ..])
update = |model, _step| Ok({ model, actions: [], tasks: [] })

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
