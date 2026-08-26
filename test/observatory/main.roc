app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-26-b29bef3" }

import rr.App
import rr.Files
import rr.Trace
import rr.Task

## End-to-end probe for Observatory's primitive annotations and cycle summary.
Model : { cycles : U64 }

Msg : [TaskDone(Str)]

program = { init!, update!, render! }

init! : App.Init(Model, Msg)
init! = App.init(App.default.with_title("Observatory probe"), |_startup| {
	_init_sentinel = Files.write_text!("observatory-init-ran", "init")
	Trace.mark!("probe init")
	startup_zone = Trace.begin!("probe startup wait")
	Task.sleep!(2)
	Trace.end!(startup_zone)
	Ok({ cycles: 0 })
})

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	zone = Trace.begin!("probe update")
	Trace.sample_i64!("probe items", 7, Count)
	Trace.sample_f64!("load ratio", 0.5, Ratio)
	Trace.end!(zone)
	if input.time.cycle_count == 0 {
		Task.spawn!(
			input,
			|| {
				task_zone = Trace.begin!("probe task wait")
				Task.sleep!(2)
				Trace.mark!("probe task annotation")
				Trace.end!(task_zone)
				TaskDone("TASK_PAYLOAD_SECRET_178 INPUT_PAYLOAD_SECRET_178 FILE_PAYLOAD_SECRET_178 HTTP_PAYLOAD_SECRET_178 SQLITE_PAYLOAD_SECRET_178 CMD_PAYLOAD_SECRET_178 0x7fffdeadbeef178")
			},
		)
		Task.spawn!(
			input,
			|| {
				outer = Trace.begin!("cancel outer")
				inner = Trace.begin!("cancel inner")
				Task.sleep!(60_000)
				Trace.end!(inner)
				Trace.end!(outer)
				TaskDone("cancelled task must never deliver")
			},
		)
	}
	done = List.any(input.messages, |msg| match msg { TaskDone(_) => Bool.True })
	if input.time.cycle_count >= 2 and done {
		Err(Exit(0))
	} else {
		Ok({ cycles: model.cycles + 1 })
	}
}

render! : Model, _ => Try({}, [Exit(I64), ..])
render! = |_model, _frame| {
	Trace.mark!("probe render")
	Ok({})
}
