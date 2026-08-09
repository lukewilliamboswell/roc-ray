app [Model, program] { rr: platform "../../platform/main.roc" }

# A blob is refcounted, so its lifetime is the same one every other Roc value
# has: the host frees the bytes when the last handle goes. `release` existed
# because the handle used to be a bare integer nothing could track, and while it
# existed a released blob could still be sitting in someone else's model --
# exactly the use-after-free the handle's generation had to be invented to
# survive. Dropping the value is the whole API now, and there is no way left to
# invalidate a copy somebody else is holding.
import rr.File
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
render! = |_model, _frame| Ok({})

# Uncalled and top-level, so exactly one error comes out of it.
discard : File.Blob -> List(Program.Action)
discard = |blob| [blob.release()]
