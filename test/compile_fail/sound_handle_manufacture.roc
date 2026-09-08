app [Model, program] {
	rr: platform "../../platform/main.roc",
	roc: "nightly-2026-09-07-14d9829",
}

# A sound remains opaque even though its representation is now a direct handle.
import rr.App
import rr.Draw
import rr.Audio

Model : {
	sound : Audio.Sound,
}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|_startup| {
		handle = Box.box(0)
		Ok({ sound: Audio.Sound.(handle) })
	},
)

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
