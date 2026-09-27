app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-09-27-a3ce7f1" }

import rr.App
import rr.Files
import rr.Task

## Designation: the user choosing a file is the grant.
##
## Run headless with a `--host-drops` script dropping `dropped.txt` on cycle
## 2, and with `named.txt` as the last argument. The app declares no
## permission at all, and must be able to read both -- and nothing else:
##
## - a path it makes up is refused;
## - the drop, held and offered again on a later cycle, is refused;
## - a string that is not one of its arguments is refused.
##
## Exits 0 when every check passes, 3 when one fails, 4 on timeout.
Model : { held : Str, dropped : [Waiting, Read(Str)], named : [Waiting, Read(Str)], refusals : Bool }

Msg : [DroppedRead(Try(Str, Files.ReadTextError)), NamedRead(Try(Str, Files.ReadTextError))]

program = { init!, update!, render! }

init! : App.Init(Model, [NoArgument])
init! = App.init(
	App.default,
	|_io| Ok({ held: "", dropped: Waiting, named: Waiting, refusals: Bool.True }),
)

refused : Try(a, [PermissionDenied]) -> Bool
refused = |result|
	match result {
		Err(PermissionDenied) => Bool.True
		Ok(_) => Bool.False
	}

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, io| {
	files = io.files()
	var $held = model.held
	var $refusals = model.refusals
	for drop in input.dropped {
		match files.accept_drop!(drop.path) {
			Ok(item) => {
				Task.spawn!(input, || DroppedRead(item.read_text!()))
				$held = drop.path
			}
			Err(PermissionDenied) => {
				$refusals = Bool.False
			}
		}
	}
	if input.time.cycle_count == 0 {
		args = io.args!()
		named = List.last(args) ?? ""
		match files.from_arg!(named) {
			Ok(item) => Task.spawn!(input, || NamedRead(item.read_text!()))
			Err(PermissionDenied) => {
				$refusals = Bool.False
			}
		}
		$refusals = $refusals and refused(files.from_arg!("not-one-of-the-arguments.txt")) and refused(files.accept_drop!("/etc/passwd"))
	}
	# A drop is only acceptable in the update that received it.
	if input.time.cycle_count == 4 and $held != "" {
		$refusals = $refusals and refused(files.accept_drop!($held))
	}

	next = List.fold(
		input.messages,
		{ ..model, held: $held, refusals: $refusals },
		|state, message|
			match message {
				DroppedRead(Ok(text)) => { ..state, dropped: Read(text) }
				NamedRead(Ok(text)) => { ..state, named: Read(text) }
				DroppedRead(Err(_)) => { ..state, dropped: Read("") }
				NamedRead(Err(_)) => { ..state, named: Read("") }
			},
	)
	match (next.dropped, next.named) {
		(Read(dropped), Read(named)) if input.time.cycle_count > 4 =>
			if dropped == "dropped contents" and named == "named contents" and next.refusals {
				Err(Exit(0))
			} else {
				Err(Exit(3))
			}
		_ => if input.time.cycle_count > 120 Err(Exit(4)) else Ok(next)
	}
}

render! : Model, _ => Try({}, [Exit(I64)])
render! = |_model, _frame| Ok({})
