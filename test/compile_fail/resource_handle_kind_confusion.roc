app [Model, program] {
	rr: platform "../../platform/main.roc",
	roc: "nightly-2026-09-10-a670e34",
}

# The shared handle representation must not let one resource kind stand in for
# another.
import rr.App
import rr.Draw
import rr.Font
import rr.Texture

Model : {}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|io| {
		use_font_handle(Texture.stub.handle)
		Ok({})
	},
)

use_font_handle : Font.FontHandle -> {}
use_font_handle = |_handle| {}

Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64), ..])
update! = |model, _input, _io| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
