## Run an external program and read back what it produced.
##
## This is the escape hatch to tools this platform will never vendor: `ffmpeg`
## to mux a recording into an MP4, `magick` to convert a sprite sheet, a solver
## or a data preprocessor that already knows a format the app does not.
##
## A command is built and then run:
##
## ```roc
## encode! : Str => Msg
## encode! = |input| {
##     cmd = Cmd.new("ffmpeg")
##         .with_args(["-y", "-i", input, "out.mp4"])
##         .with_timeout_ms(120_000)
##
##     match Cmd.run!(cmd) {
##         Ok(output) if output.exit_code == 0 => Encoded("out.mp4")
##         Ok(output) => EncodeRefused(Str.from_utf8_lossy(output.stderr))
##         Err(err) => EncodeFailed(err)
##     }
## }
## ```
##
## `run!` waits, so it belongs inside `Task.spawn!`, where the frame loop keeps
## drawing while the child runs. It is legal in `init!`, where it blocks
## startup, and in tasks, where it parks the task; it is refused in `update!`
## and `render!`.
##
## A non-zero exit code is not an error. It arrives as `Ok(output)` carrying
## that code, because a program's exit status is one of the things it is trying
## to tell the caller: `grep` says "no match" with `1`, `ffmpeg` says "bad
## arguments" with `1`, and a test runner says how many tests failed. Only a
## run that produced no exit status at all -- no such program, no permission to
## start it, the deadline expired, more output than the app allowed -- is an
## `Err`. That is the same rule `Http` follows for a 404.
##
## No shell is involved. `program` is the executable and `args` are handed to
## it one by one, so nothing here splits on spaces, expands `*`, follows a
## pipe, or reads a redirect. A command line that needs any of that names a
## shell as the program and passes the line as one argument.
##
## Authority: running a program grants that program this process's own
## authority. The child inherits the user account, the working directory, and
## (unless `with_clear_envs` says otherwise) the environment; nothing here
## restricts which executable may be named or what it may then do. `Cmd` is
## unrestricted in exactly the way `Files` is -- an app that can read
## `/etc/hosts` can run `/bin/sh` -- and it is deliberately more than that,
## because a program the app starts is not bound by any of this platform's
## rules. The one output root this platform enforces belongs to `Capture`, and
## a subprocess trivially defeats it. Depend on `Cmd` when the app is trusted
## with the machine it runs on, and not otherwise.
##
## What the child does not inherit is its streams. Standard input is closed, so
## a program that would have prompted reads end of stream instead of competing
## with the application for the terminal, and both output streams are captured
## rather than passed through, so a chatty tool cannot write over an app that
## is using `Stdout` itself.
##
## Shutdown kills a running child. Shutdown cancels every live task, and a
## task parked in `run!` is interrupted through this facility's own mechanism:
## the host terminates the child it started, the parked task resumes on the
## cancelled path, and nothing is left running behind the app. A child that has
## already replaced itself with something detached is outside that guarantee,
## exactly as forced process termination is.
import CmdHost

Cmd := {

	## The executable to run, as `argv[0]`.
	program : Str,

	## The arguments after `argv[0]`, passed through unchanged.
	args : List(Str),

	## Environment variables to set for the child, on top of the inherited
	## environment unless `clear_envs` is `Bool.True`.
	envs : List({ name : Str, value : Str }),

	## Whether to drop the inherited environment before applying `envs`.
	clear_envs : Bool,

	## The directory to run in, or this process's own.
	working_dir : [Inherit, Set(Str)],

	## How long the host will wait for the child before killing it.
	timeout_ms : U64,

	## The most standard output the host will capture.
	stdout_limit_bytes : U64,

	## The most standard error the host will capture.
	stderr_limit_bytes : U64,
}.{

	## What a child produced: its exit status and both captured streams.
	##
	## `exit_code` is the status the operating system reported. On a child
	## killed by a signal it is the negated signal number, so a segmentation
	## fault is `-11` rather than being confused with an ordinary exit; a
	## child killed at the deadline reports `-1`.
	##
	## `stdout` and `stderr` are captured separately and neither is
	## interleaved into the other, so a program that writes progress to one
	## and data to the other stays readable. Both are ordinary Roc byte lists.
	Output : {
		exit_code : I64,
		stdout : List(U8),
		stderr : List(U8),
	}

	## The same, decoded as text by `run_utf8!`.
	Utf8Output : {
		exit_code : I64,
		stdout : Str,
		stderr : Str,
	}

	## Why the command produced no exit status.
	##
	## A non-zero exit status is not one of these; it is an `Ok`.
	##
	## `CommandNotFound` is no such executable on `PATH` or at that path, and
	## `PermissionDenied` is one that is there and may not be started.
	## `SpawnFailed` is every other refusal to start the child or to run it to
	## its end, including a working directory that is not there and an
	## environment name this operating system cannot represent -- one that is
	## empty, or contains `=` or a NUL.
	##
	## `Timeout` carries what the child had written before the
	## deadline killed it, because a program that hangs after printing why is
	## the ordinary case. `StdoutLimitExceeded` and `StderrLimitExceeded` are
	## refusals rather than truncations: half a stream decodes into wrong data
	## rather than into an error, so nothing is handed back.
	##
	## `Busy` is the host already running as many children as it will run at
	## once; nothing was started, and the same command run later can succeed.
	## `Unavailable` is the app shutting down while the child was running.
	CmdErr : [
		CommandNotFound,
		PermissionDenied,
		SpawnFailed,
		Busy,
		Unavailable,
		Timeout(Output),
		StdoutLimitExceeded,
		StderrLimitExceeded,
	]

	## Thirty seconds.
	##
	## Long enough for a real encode of a short clip, short enough that a task
	## parked on a program that will never answer is eventually collected. A
	## command that genuinely takes longer says so with `with_timeout_ms`.
	default_timeout_ms : U64
	default_timeout_ms = 30_000

	## Eight megabytes, applied to each captured stream on its own.
	##
	## The same figure `Http` caps a response body at, for the same reason: it
	## holds a large text or JSON payload and not an accidental video.
	default_output_limit_bytes : U64
	default_output_limit_bytes = 8 * 1024 * 1024

	## A command to run `program` with no arguments.
	##
	## Every bound is set here, so there is no way to build a command without
	## a deadline or without output limits. `program` is looked up on this
	## process's `PATH` when it contains no path separator, and used as a path
	## when it does.
	new : Str -> Cmd
	new = |program| {
		program: program,
		args: [],
		envs: [],
		clear_envs: Bool.False,
		working_dir: Inherit,
		timeout_ms: default_timeout_ms,
		stdout_limit_bytes: default_output_limit_bytes,
		stderr_limit_bytes: default_output_limit_bytes,
	}

	## Append one argument, exactly as the child will see it.
	with_arg : Cmd, Str -> Cmd
	with_arg = |cmd, argument| { ..cmd, args: List.append(cmd.args, argument) }

	## Append several arguments, in order.
	with_args : Cmd, List(Str) -> Cmd
	with_args = |cmd, arguments| { ..cmd, args: List.concat(cmd.args, arguments) }

	## Set one environment variable for the child.
	##
	## A name that is empty, or that contains `=` or a NUL, cannot be set on
	## any operating system this platform runs on, and fails the run with
	## `SpawnFailed` rather than being dropped silently.
	with_env : Cmd, Str, Str -> Cmd
	with_env = |cmd, name, value| { ..cmd, envs: List.append(cmd.envs, { name: name, value: value }) }

	## Set several environment variables for the child.
	with_envs : Cmd, List({ name : Str, value : Str }) -> Cmd
	with_envs = |cmd, variables| { ..cmd, envs: List.concat(cmd.envs, variables) }

	## Whether to drop this process's environment before applying `with_env`.
	##
	## `Bool.True` gives the child only what the command names, which is what
	## a reproducible invocation of a tool wants. It does not remove the
	## child's other inheritances: the working directory, the user account and
	## the open standard streams are unchanged.
	with_clear_envs : Cmd, Bool -> Cmd
	with_clear_envs = |cmd, clear| { ..cmd, clear_envs: clear }

	## Run the child in this directory instead of this process's own.
	##
	## Only the child moves; nothing changes the working directory of the
	## application itself, so a path this app uses afterwards still resolves
	## the way every other path in it does. A relative `program` is still
	## resolved against this process's directory, not against this one.
	with_working_dir : Cmd, Str -> Cmd
	with_working_dir = |cmd, dir| { ..cmd, working_dir: Set(dir) }

	## How long to wait for the child before killing it.
	##
	## The deadline covers the whole run, and `0` is normalized to `1`: there
	## is no way to ask for no deadline, because a task parked forever on a
	## program that never exits is a leak the app cannot see.
	with_timeout_ms : Cmd, U64 -> Cmd
	with_timeout_ms = |cmd, millis| {
		..cmd,
		timeout_ms: if millis == 0 {
			1
		} else {
			millis
		},
	}

	## The most standard output to capture, in bytes.
	##
	## A child that writes more fails the run with `StdoutLimitExceeded`
	## rather than handing back a prefix. The host clamps this to sixty-four
	## megabytes, so asking for more than it will hold gets that figure and
	## the refusal arrives there instead.
	with_stdout_limit : Cmd, U64 -> Cmd
	with_stdout_limit = |cmd, limit_bytes| { ..cmd, stdout_limit_bytes: limit_bytes }

	## The most standard error to capture, in bytes. `StderrLimitExceeded`
	## otherwise, on the same terms as `with_stdout_limit`.
	with_stderr_limit : Cmd, U64 -> Cmd
	with_stderr_limit = |cmd, limit_bytes| { ..cmd, stderr_limit_bytes: limit_bytes }

	## Run the command and wait for the child to finish.
	##
	## At most eight children run at once. The slot is taken before anything
	## is started and released when the child has been reaped, so a `Busy`
	## means precisely that no process was created. Bounding what is started
	## is what keeps a task per child from becoming a process per task.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	##
	## ```roc
	## update! = |model, input| {
	##     if input.devices.key_pressed(KeyE) {
	##         Task.spawn!(
	##             input,
	##             || match Cmd.run!(Cmd.new("git").with_args(["rev-parse", "HEAD"])) {
	##                 Ok(output) => Revision(Str.from_utf8_lossy(output.stdout))
	##                 Err(err) => RevisionFailed(err)
	##             },
	##         )
	##     }
	##     Ok(model)
	## }
	## ```
	run! : Cmd => Try(Output, CmdErr)
	run! = |cmd| {
		result = CmdHost.run!({
			program: cmd.program,
			args: cmd.args,
			envs: cmd.envs,
			clear_envs: cmd.clear_envs,
			working_dir: match cmd.working_dir {
				Inherit => ""
				Set(dir) => dir
			},
			timeout_ms: cmd.timeout_ms,
			stdout_limit_bytes: cmd.stdout_limit_bytes,
			stderr_limit_bytes: cmd.stderr_limit_bytes,
		})

		output = { exit_code: result.exit_code, stdout: result.stdout, stderr: result.stderr }
		if result.err == 0 {
			Ok(output)
		} else if result.err == run_err_timed_out {
			Err(Timeout(output))
		} else {
			Err(run_error(result.err))
		}
	}

	## Run the command and read both streams as text.
	##
	## The decoding is lossy: bytes that are not valid UTF-8 become the
	## replacement character rather than failing the run, because a tool that
	## puts one stray byte in a progress line has still told the app what it
	## needed to know. Use `run!` when a stream has to survive exactly.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	run_utf8! : Cmd => Try(Utf8Output, CmdErr)
	run_utf8! = |cmd|
		match run!(cmd) {
			Ok(output) =>
				Ok({
					exit_code: output.exit_code,
					stdout: Str.from_utf8_lossy(output.stdout),
					stderr: Str.from_utf8_lossy(output.stderr),
				})

			Err(err) => Err(err)
		}
}

## The deadline expired and the host killed the child. Mirrored in
## `src/cmd_effect.zig`.
run_err_timed_out : U8
run_err_timed_out = 5

## The host would not start another child. Mirrored in `src/cmd_effect.zig`,
## and numbered as `Files` numbers its own `Busy`, so a code never means two
## things across this boundary.
run_err_busy : U8
run_err_busy = 3

## Decode the host's run-error code.
##
## `Timeout` is absent because it carries a payload only `run!` holds;
## `run!` names it before asking here. Anything unrecognized is `SpawnFailed`,
## the code for a child that could not be started for a reason with no better
## name.
run_error : U8 -> Cmd.CmdErr
run_error = |code|
	if code == 1 {
		CommandNotFound
	} else if code == run_err_busy {
		Busy
	} else if code == 4 {
		Unavailable
	} else if code == 6 {
		StdoutLimitExceeded
	} else if code == 7 {
		StderrLimitExceeded
	} else if code == 8 {
		PermissionDenied
	} else {
		SpawnFailed
	}

expect run_error(1) == CommandNotFound
expect run_error(2) == SpawnFailed
expect run_error(3) == Busy
expect run_error(4) == Unavailable
expect run_error(6) == StdoutLimitExceeded
expect run_error(7) == StderrLimitExceeded
expect run_error(8) == PermissionDenied
expect run_error(99) == SpawnFailed

expect Cmd.new("ls").program == "ls"
expect Cmd.new("ls").args == []
expect Cmd.new("ls").timeout_ms == Cmd.default_timeout_ms
expect Cmd.new("ls").stdout_limit_bytes == Cmd.default_output_limit_bytes
expect Cmd.new("ls").stderr_limit_bytes == Cmd.default_output_limit_bytes
expect Cmd.new("ls").clear_envs == Bool.False
expect Cmd.new("ls").with_arg("-l").with_arg("/tmp").args == ["-l", "/tmp"]
expect Cmd.new("ls").with_args(["-l", "/tmp"]).args == ["-l", "/tmp"]
expect Cmd.new("ls").with_env("TZ", "UTC").envs == [{ name: "TZ", value: "UTC" }]
expect Cmd.new("ls").with_clear_envs(Bool.True).clear_envs == Bool.True
expect Cmd.new("ls").with_working_dir("/tmp").working_dir == Set("/tmp")

## A zero deadline is normalized rather than accepted, so no command can be
## built that waits forever.
expect Cmd.new("sleep").with_timeout_ms(0).timeout_ms == 1
expect Cmd.new("sleep").with_timeout_ms(500).timeout_ms == 500
expect Cmd.new("ls").with_stdout_limit(64).stdout_limit_bytes == 64
expect Cmd.new("ls").with_stderr_limit(64).stderr_limit_bytes == 64
