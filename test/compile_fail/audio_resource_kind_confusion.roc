app [Model, program] {
	rr: platform "../../platform/main.roc",
	roc: "nightly-2026-09-07-14d9829",
}

# The shared handle representation must not let one resource kind stand in for
# another.
import rr.App
import rr.Draw
import rr.Audio

Model : {}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|io| {
		use_sound(Audio.Music.stub)
		Ok({})
	},
)

use_sound : Audio.Sound -> {}
use_sound = |_sound| {}

Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64), ..])
update! = |model, _input, _io| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
