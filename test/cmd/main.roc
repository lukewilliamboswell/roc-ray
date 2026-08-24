app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Cmd
import rr.Files
import rr.Task

## Does `Cmd.run!` start a real program, read it back, bound it, and park?
##
## A headless run only asserts an exit code, so a `run!` that started nothing,
## captured nothing, ignored its deadline, or blocked the frame loop would pass
## every other stage of the suite. This probe runs six commands and exits
## non-zero unless every property below holds.
##
## It picks its shell from the machine it is on: `/bin/sh` where that exists,
## and `cmd.exe` otherwise, which is what makes the same probe meaningful on
## the Windows job. Nothing it runs writes to the filesystem or reaches the
## network, so it leaves nothing behind.
##
## Exit codes: 0 every property held, 3 one did not, 4 the task never answered.
Model : { started_cycle : U64 }

Msg : [Checked(U64)]

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default.with_title("cmd"), |_startup| Ok({ started_cycle: 0 }))

## A correct run scores every bit. Any property that does not hold subtracts
## its own bit, so the exit code's companion -- the score -- says which one.
expected_score : U64
expected_score = 127

expect 1 + 2 + 4 + 8 + 16 + 32 + 64 == expected_score

## What the probe's command prints, and expects to read back.
probe_text : Str
probe_text = "roc-ray-cmd-probe"

## How long the parked command is given before the host must kill it.
##
## Short enough that the whole probe fits inside `deadline_cycles`, long enough
## that several frames must be drawn while the task sits in it.
timeout_ms : U64
timeout_ms = 300

## Frames that must go by while the task is parked. A `run!` that blocked the
## frame loop instead of parking its task could not manage them.
min_parked_cycles : U64
min_parked_cycles = 3

## Cycles the whole probe is given before it is judged to have hung.
deadline_cycles : U64
deadline_cycles = 400

score : Bool, U64 -> U64
score = |held, bit| if held bit else 0

expect score(Bool.True, 4) == 4
expect score(Bool.False, 4) == 0

## Run every command and score what came back. Runs on a task, where `run!`
## parks rather than blocking.
check! : () => Msg
check! = || {
	# Which shell this machine has. `/bin/sh` is on every POSIX target and on
	# none of the Windows ones, so one stat decides it without the platform
	# having to name the operating system.
	posix =
		match Files.metadata!("/bin/sh") {
			Ok(_) => Bool.True
			Err(_) => Bool.False
		}

	shell = if posix "/bin/sh" else "cmd.exe"
	echo_args = if posix ["-c", "printf ${probe_text}"] else ["/c", "echo", probe_text]
	exit_args = if posix ["-c", "exit 3"] else ["/c", "exit", "3"]
	sleep_args = if posix ["-c", "sleep 30"] else ["/c", "ping", "-n", "30", "127.0.0.1"]

	# A program runs, and what it wrote comes back. `echo` adds a line ending
	# on Windows, so this asks whether the text is in the output rather than
	# whether it is the whole of it.
	echoed =
		match Cmd.run!(Cmd.new(shell).with_args(echo_args)) {
			Ok(output) =>
				output.exit_code == 0 and Str.contains(Str.from_utf8_lossy(output.stdout), probe_text)

			Err(_) => Bool.False
		}

	# A program that is not there is named, rather than reported as a generic
	# failure or as a child that exited non-zero.
	missing = Cmd.run!(Cmd.new("roc-ray-definitely-not-a-program")) == Err(CommandNotFound)

	# More output than the command allowed is refused outright: no truncated
	# prefix, and no `Ok`.
	bounded =
		Cmd.run!(Cmd.new(shell).with_args(echo_args).with_stdout_limit(2))
			== Err(StdoutLimitExceeded)

	# A non-zero exit status is data. It arrives as `Ok`, carrying the code.
	exited =
		match Cmd.run!(Cmd.new(shell).with_args(exit_args)) {
			Ok(output) => output.exit_code == 3
			Err(_) => Bool.False
		}

	# The deadline expires and the host kills the child, rather than waiting
	# out the thirty seconds the command asked for.
	timed_out =
		match Cmd.run!(Cmd.new(shell).with_args(sleep_args).with_timeout_ms(timeout_ms)) {
			Err(Timeout(_)) => Bool.True
			Ok(_) => Bool.False
			Err(_) => Bool.False
		}

	# A working directory that is not there is refused, and is not confused
	# with the program being missing.
	no_such_dir =
		Cmd.run!(Cmd.new(shell).with_args(exit_args).with_working_dir("roc-ray-no-such-dir"))
			== Err(SpawnFailed)

	Checked(
		score(echoed, 1)
			+ score(missing, 2)
			+ score(bounded, 4)
			+ score(exited, 8)
			+ score(timed_out, 16)
			+ score(no_such_dir, 32),
	)
}

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	cycle = input.time.cycle_count
	if cycle == 0 {
		Task.spawn!(input, check!)
	}

	match List.first(input.messages) {
		Ok(Checked(total)) => {
			# The last bit is not the task's to score: it is the frame loop's.
			# A `run!` that blocked would have finished on the cycle it started
			# on, because no frame could have been drawn in between.
			parked = score(cycle >= model.started_cycle + min_parked_cycles, 64)
			if total + parked == expected_score {
				Err(Exit(0))
			} else {
				# `--host-headless` prints nothing, so the exit code is all
				# there is: 3 means a property did not hold, 4 means the task
				# never answered at all.
				Err(Exit(3))
			}
		}

		Err(_) =>
			if cycle > deadline_cycles {
				Err(Exit(4))
			} else {
				Ok(model)
			}
		}
}

render! : Model, _ => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
