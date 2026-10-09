app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-10-09-258ab27" }

import rr.App
import rr.Files
import rr.Task
import rr.Permission

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
init! = App.init(App.default.with_title("file write").with_permission(Directory("probe_out", ReadWrite)), |_io| Ok({ checked: Bool.False }))

## A correct run scores every bit. Any property that does not hold subtracts
## its own bit, so the exit code says which half of the probe went wrong.
expected_score : U64
expected_score = 255

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
expect 1 + 2 + 4 + 8 + 16 + 32 + 64 + 128 == expected_score

## Write, read back, compare. Runs on a task, where every call parks.
check! : App.Io => Msg
check! = |io| {
	out =
		match io.files().open_dir!("probe_out") {
			Ok(dir) => dir
			Err(_) => return Checked(0)
		}
	wrote_text = out.write_text!("text.txt", probe_text) == Ok({})
	read_text_back = out.read_text!("text.txt") == Ok(probe_text)

	wrote_bytes = out.write_bytes!("blob.bin", probe_bytes) == Ok({})
	read_bytes_back = out.read_bytes!("blob.bin") == Ok(probe_bytes)

	# A second write replaces the file rather than appending to it or leaving
	# the tail of the longer contents in place.
	replaced =
		out.write_bytes!("blob.bin", [1, 2, 3]) == Ok({})
			and out.read_bytes!("blob.bin") == Ok([1, 2, 3])

	# Missing parent directories are created, so a first save does not need a
	# separate step to make its directory.
	made_parents =
		out.write_text!("nested/deep/save.json", "{}") == Ok({})
			and out.read_text!("nested/deep/save.json") == Ok("{}")

	# A path whose parent is a file cannot be created, and says so with the
	# named error rather than by pretending to succeed.
	refused = out.write_text!("text.txt/nope.txt", "x") == Err(NotFound)

	# A path that would leave the handle is refused before anything is
	# written. Its shape is the problem, not a missing grant, so the answer
	# is `PathInvalid` rather than `PermissionDenied`.
	escaped = out.write_text!("../escaped.txt", "x") == Err(PathInvalid)

	Checked(
		score(wrote_text, 1)
			+ score(read_text_back, 2)
			+ score(wrote_bytes, 4)
			+ score(read_bytes_back, 8)
			+ score(replaced, 16)
			+ score(made_parents, 32)
			+ score(refused, 64)
			+ score(escaped, 128),
	)
}

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, io| {
	if input.time.cycle_count == 0 {
		Task.spawn!(input, || check!(io))
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

render! : Model, _ => Try({}, [Exit(I64)])
render! = |_model, _frame| Ok({})
