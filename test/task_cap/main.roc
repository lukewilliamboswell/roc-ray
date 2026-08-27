app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Task

## Spawn far more tasks than the host runs at once, and check it starts every
## one of them.
##
## The host runs 32 tasks at once and queues the rest, so this asks for a
## hundred in a single `update!`. Two things have to hold. The cap must queue
## rather than refuse -- `Task.spawn!` has no error to report, so a dropped
## closure would simply never answer. And the phase guard must survive the
## burst: spawning hands control to the executor, a started task sets its own
## phase and clears it when it parks, so without the frame's phase being
## restored around each spawn the fourteenth one in this loop is rejected as
## "called outside any app callback".
Model : { seen : U64, sum : U64 }

Msg : [Done(U64)]

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default.with_title("task cap"), |_startup| Ok({ seen: 0, sum: 0 }))

## Comfortably past the host's 32 live tasks.
wanted : U64
wanted = 100

## Every id exactly once, so the arrivals sum to a number no dropped, repeated
## or reordered task can reach.
expected_sum : U64
expected_sum = wanted * (wanted + 1) / 2

expect expected_sum == 5050

ids : List(U64)
ids = build_ids([], 1)

build_ids : List(U64), U64 -> List(U64)
build_ids = |acc, n| if n > wanted acc else build_ids(List.append(acc, n), n + 1)

expect List.len(ids) == wanted
expect List.fold(ids, 0, |acc, n| acc + n) == expected_sum

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	if input.time.cycle_count == 0 {
		for id in ids {
			# Each task parks, so the queue drains over several cycles rather
			# than the whole hundred running to completion inside one spawn.
			Task.spawn!(
				input,
				|| {
					Task.sleep!(10)
					Done(id)
				},
			)
		}
	}

	seen = model.seen + List.len(input.messages)
	sum = List.fold(
		input.messages,
		model.sum,
		|acc, message| match message {
			Done(id) => acc + id
		},
	)

	if seen >= wanted {
		if seen == wanted and sum == expected_sum {
			Err(Exit(0))
		} else {
			Err(Exit(3))
		}
	} else if input.time.cycle_count > 300 {
		Err(Exit(4))
	} else {
		Ok({ seen, sum })
	}
}

render! : Model, _ => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
