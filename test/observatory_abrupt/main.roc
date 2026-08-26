app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-26-b29bef3" }

import rr.App
import rr.Trace

## Long-running headless fixture terminated by the host test to verify that a
## real process kill leaves a committed, explicitly unclean SQLite prefix.
Model : U64
Msg : [Unused]

program = { init!, update!, render! }

init! : App.Init(Model, Msg)
init! = App.init(App.default.with_title("Observatory abrupt probe"), |_startup| Ok(0))

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| {
	Trace.sample_i64!("abrupt cycles", 1, Count)
	Ok(model + 1)
}

render! : Model, _ => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
