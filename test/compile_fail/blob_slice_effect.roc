app [Model, program] { rr: platform "../../platform/main.roc" }

# Copying bytes out of a blob is a `Program.read_blob_slice` task. As an effect it could
# only be reached from `render!`, so an app that wanted a string from a blob
# copied and UTF-8-scanned the same range on every frame that drew it -- for a
# value that changed once. There is no effectful form left to call.
import rr.File
import rr.App
import rr.Draw
import rr.Program

Model : {}

program = { init!, update, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({}))

Msg : []

update : Model, Program.Step(Msg) -> Try(Program.Next(Model, Msg), [Exit(I64), ..])
update = |model, _step| Ok({ model, actions: [], tasks: [] })

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})

preview! : File.Blob => Try(Str, [NotUtf8, TooLarge, OutOfBounds, Released])
preview! = |blob| blob.slice_to_str!({ offset: 0, count: 16 })
