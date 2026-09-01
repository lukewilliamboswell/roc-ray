app [Model, program] {
	rr: platform "../../platform/main.roc",
	rrt: "../../types/main.roc",
	roc: "nightly-2026-08-23-fb208ba",
}

# The shared handle representation must not let one resource kind stand in for
# another.
import rr.App
import rr.Draw
import rrt.Font
import rrt.Handle
import rrt.Texture

Model : {}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|_startup| {
		use_font_handle(Texture.stub.handle)
		Ok({})
	},
)

use_font_handle : Handle([FontResource]) -> {}
use_font_handle = |_handle| {}

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
