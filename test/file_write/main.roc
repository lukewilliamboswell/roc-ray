app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Files
import rr.Task

## Does a file written by `Files.write_*` come back byte for byte?
##
## A headless run only asserts an exit code, so a write that silently wrote
## nothing -- or wrote to somewhere else, or appended instead of replacing --
## would still pass every other stage of the suite. This probe writes, reads
## the same path back, and compares, and it exits non-zero unless every one of
## the seven properties below holds.
##
## It runs from a scratch directory and only ever touches paths under
## `probe_out/`, so it leaves nothing behind in the tree.
Model : { checked : Bool }

Msg : [Checked(U64)]

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default.with_title("file write"), |_startup| Ok({ checked: Bool.False }))

## A correct run scores every bit. Any property that does not hold subtracts
## its own bit, so the exit code says which half of the probe went wrong.
expected_score : U64
expected_score = 127

## The text written, read back, and compared. Multi-line and non-ASCII on
## purpose: a write that went through a C string would truncate at the NUL a
## `Str` does not have, and a length-confused one would drop the tail.
probe_text : Str
probe_text = "roc-ray file write probe\nsecond line\n\u(e9)\u(2713)\n"

## Long enough not to fit in a small-string optimization, and replaced later by
## something shorter -- a whole-file write has to shrink the file, not leave
## the tail of the previous contents behind.
probe_bytes : List(U8)
probe_bytes = List.repeat(0xa5, 5000)

score : Bool, U64 -> U64
score = |held, bit| if held bit else 0

expect score(Bool.True, 4) == 4
expect score(Bool.False, 4) == 0
expect 1 + 2 + 4 + 8 + 16 + 32 + 64 == expected_score

## Write, read back, compare. Runs on a task, where every call parks.
check! : () => Msg
check! = || {
	wrote_text = Files.write_text!("probe_out/text.txt", probe_text) == Ok({})
	read_text_back = Files.read_text!("probe_out/text.txt") == Ok(probe_text)

	wrote_bytes = Files.write_bytes!("probe_out/blob.bin", probe_bytes) == Ok({})
	read_bytes_back = Files.read_bytes!("probe_out/blob.bin") == Ok(probe_bytes)

	# A second write replaces the file rather than appending to it or leaving
	# the tail of the longer contents in place.
	replaced =
		Files.write_bytes!("probe_out/blob.bin", [1, 2, 3]) == Ok({})
			and Files.read_bytes!("probe_out/blob.bin") == Ok([1, 2, 3])

	# Missing parent directories are created, so a first save does not need a
	# separate step to make its directory.
	made_parents =
		Files.write_text!("probe_out/nested/deep/save.json", "{}") == Ok({})
			and Files.read_text!("probe_out/nested/deep/save.json") == Ok("{}")

	# A path whose parent is a file cannot be created, and says so with the
	# named error rather than by pretending to succeed.
	refused = Files.write_text!("probe_out/text.txt/nope.txt", "x") == Err(NotFound)

	Checked(
		score(wrote_text, 1)
			+ score(read_text_back, 2)
			+ score(wrote_bytes, 4)
			+ score(read_bytes_back, 8)
			+ score(replaced, 16)
			+ score(made_parents, 32)
			+ score(refused, 64),
	)
}

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	if input.time.cycle_count == 0 {
		Task.spawn!(input, check!)
	}

	match List.first(input.messages) {
		Ok(Checked(total)) =>
			if total == expected_score {
				Err(Exit(0))
			} else {
				# A property did not hold. `--host-headless` prints nothing, so
				# the exit code is all there is: 3 means the write path is
				# wrong, 4 means the task never answered at all.
				Err(Exit(3))
			}

		Err(_) =>
			if input.time.cycle_count > 120 {
				Err(Exit(4))
			} else {
				Ok(model)
			}
		}
}

render! : Model, _ => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
