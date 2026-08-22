app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Task

## Does every task message survive the trip back into `update!`?
##
## A headless run only asserts an exit code, so an example whose messages never
## arrive still passes the suite. This probe asserts on the messages themselves:
## it spawns one task per `Msg` variant, plus one that parks first, and exits
## non-zero unless every one of them comes back with the right tag *and* the
## right payload.
##
## The `Msg` layouts below are the ones that used to fail. `Task.spawn!` without
## its `App.Input` witness leaves `msg` free at the call site, so each closure
## compiles at the single-tag type its own body implies while the host decodes
## the result as this `Msg` -- wrong tag, misread payload, or an abort in
## `roc_dealloc` when the misread variant holds a `Str` or a `List`. Deliberately
## no payload-less variant: a zero-sized one has nothing in it to corrupt.
Model : { received : U64, count : U64 }

## Every variant carries a payload, and one nests a union inside a union.
Msg : [Num(U64), Text(Str), Bytes(List(U8)), Nested(Try(Str, [Bad]))]

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default.with_title("task delivery"), |_startup| Ok({ received: 0, count: 0 }))

## What each spawned task is expected to answer, and the distinct power of two
## that stands for it. Six tasks, so a correct run sums to 63 with a count of 6;
## any wrong tag or payload scores 0 and any duplicate perturbs the sum.
expected_total : U64
expected_total = 63

expected_count : U64
expected_count = 6

## The oracle. No catch-all: every branch compares the payload it was promised,
## so a message that arrives under the wrong tag scores nothing.
score : Msg -> U64
score = |msg|
	match msg {
		Num(n) =>
			if n == 77 {
				1
			} else if n == 1234 {
				32
			} else {
				0
			}

		Text(text) => if text == "the quick brown fox" 2 else 0
		Bytes(bytes) => if bytes == [1, 2, 3, 4, 5, 6, 7, 8] 4 else 0
		Nested(Ok(text)) => if text == "nested ok" 8 else 0
		Nested(Err(Bad)) => 16
	}

expect score(Num(77)) == 1
expect score(Num(1234)) == 32
expect score(Num(0)) == 0
expect score(Text("the quick brown fox")) == 2
expect score(Text("other")) == 0
expect score(Bytes([1, 2, 3, 4, 5, 6, 7, 8])) == 4
expect score(Bytes([1, 2, 3])) == 0
expect score(Nested(Ok("nested ok"))) == 8
expect score(Nested(Ok("other"))) == 0
expect score(Nested(Err(Bad))) == 16
expect 1 + 32 + 2 + 4 + 8 + 16 == expected_total

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	if input.time.cycle_count == 0 {
		Task.spawn!(input, || Num(77))
		Task.spawn!(input, || Text("the quick brown fox"))
		Task.spawn!(input, || Bytes([1, 2, 3, 4, 5, 6, 7, 8]))
		Task.spawn!(input, || Nested(Ok("nested ok")))
		Task.spawn!(input, || Nested(Err(Bad)))
		Task.spawn!(
			input,
			|| {
				Task.sleep!(50)
				Num(1234)
			},
		)
	}

	received = List.fold(input.messages, model.received, |total, msg| total + score(msg))
	count = model.count + List.len(input.messages)

	if count >= expected_count {
		if count == expected_count and received == expected_total {
			Err(Exit(0))
		} else {
			Err(Exit(3))
		}
	} else if input.time.cycle_count > 120 {
		Err(Exit(4))
	} else {
		Ok({ received, count })
	}
}

render! : Model, _ => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
