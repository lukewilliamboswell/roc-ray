app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-09-27-a3ce7f1" }

import rr.App
import rr.Task

## What the window's close button and the exit key do, under each
## `CloseRequest`.
##
## The driver scripts the close button with `--host-close` and keys with
## `--host-keys`, and picks the mode with an argument the config reads. The
## app prints `cycle N` for every cycle `update!` sees, `key S` for a scripted
## S, and `text N` for N typed codepoints, so the driver can tell where a run
## ended and what reached it.
##
## - `--mode=exit`, with `--host-close=3`: the default. The host ends the app
##   before cycle 3's `update!`, so the app never sees a request. A task it
##   started is cancelled rather than waited for. Reaching cycle 3, or seeing
##   a request, exits 3.
## - `--mode=deliver`, with `--host-close=3,5`: the window stays open. The
##   first request is noted and ignored, and the app carries on. The second
##   starts a save on a task, and the app exits 0 when the save's message
##   arrives -- provided each request was reported on exactly its own cycle.
##   A wrong report exits 3; a save that never answers exits 4.
## - `--mode=deliver` with `--host-keys=2:ESCAPE~` and no close request: the
##   exit key still ends the app directly, before cycle 2's `update!`, even
##   though the close button is delivered.
Model : { mode : Str, requests : List(U64), saving : Bool }

Msg : [Saved(U64), Forever]

program = { init!, update!, render! }

mode_of : List(Str) -> Str
mode_of = |args| {
	var $found = ""
	for arg in args {
		if Str.starts_with(arg, "--mode=") {
			$found = Str.drop_prefix(arg, "--mode=")
		}
	}
	$found
}

config : List(Str) -> App.Config
config = |args|
	if mode_of(args) == "deliver" {
		App.default.with_title("close request").with_close_request(Deliver)
	} else {
		App.default.with_title("close request")
	}

init! : App.Init(Model, [])
init! = App.init_for_args(config, |io| Ok({ mode: mode_of(io.args!()), requests: [], saving: Bool.False }))

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, io| {
	cycle = input.time.cycle_count
	out = io.stdout()
	_ = out.line!("cycle ${U64.to_str(cycle)}")
	if input.devices.key_pressed(KeyS) {
		_ = out.line!("key S")
	}
	typed = List.len(input.devices.text_input)
	if typed > 0 {
		_ = out.line!("text ${U64.to_str(typed)}")
	}
	requests = if input.window.close_requested model.requests.append(cycle) else model.requests
	if model.mode == "exit" {
		if cycle == 0 {
			# Never answers: the host must cancel it at shutdown, not wait.
			Task.spawn!(input, || {
				Task.sleep!(60_000)
				Forever
			})
		}
		if cycle >= 3 or input.window.close_requested {
			Err(Exit(3))
		} else {
			Ok(model)
		}
	} else {
		saved = input.messages.any(|message| message == Saved(5))
		if saved {
			# Each request on its own cycle, once, and the app kept running
			# between them.
			Err(Exit(if requests == [3, 5] and cycle > 5 0 else 3))
		} else if input.window.close_requested and requests == [3, 5] {
			# Parks, so the message arrives on a later cycle, with the window
			# still open.
			Task.spawn!(input, || {
				Task.sleep!(50)
				Saved(cycle)
			})
			Ok({ ..model, requests: requests, saving: Bool.True })
		} else if cycle > 150 {
			Err(Exit(4))
		} else {
			Ok({ ..model, requests: requests })
		}
	}
}

render! : Model, _ => Try({}, [Exit(I64)])
render! = |_model, _frame| Ok({})
