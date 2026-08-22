## Internal subprocess transport and hosted effects.
##
## This module is intentionally not exposed by the platform package. Public
## applications use `Cmd`, which maps these flat primitive codes onto tag
## unions and hides the numbering.
##
## `run!` waits, so it carries the `during_wait` phase set in
## `src/host_native.zig`: on a task the host parks the coroutine while the
## child runs on zio's blocking pool and the frame loop keeps drawing, and in
## `init!` the same call blocks while the loop is pumped.
##
## No tag union crosses this boundary, so the two shapes `Cmd` states as
## unions are flattened here. `working_dir` is a plain `Str` in which the empty
## string means the child inherits this process's working directory: no
## operating system names a directory with the empty string, so nothing is
## ambiguous. The outcome is an `err` code beside a whole `Output`, because one
## of the failures -- the deadline expiring -- still has captured bytes worth
## handing back.
##
## Both byte lists are ordinary copies rather than transfers of the host's own
## allocation. A run produces two payloads and the delivery heap hands over
## one allocation per slot, and both are bounded by limits the app stated, so a
## copy is the simpler correct answer here; `FilesHost.read_bytes!` takes the
## transfer path because a single unbounded file read is what that path is for.
CmdHost := [].{

	## One environment variable, as the child will see it.
	EnvPair : {
		name : Str,
		value : Str,
	}

	## A command, already defaulted and validated by `Cmd`.
	##
	## `program` is `argv[0]`; it is looked up on this process's `PATH` when it
	## contains no path separator, and used as a path when it does. `args` are
	## the arguments after it, passed to the child exactly as given: no shell
	## reads them, so nothing is split, globbed, or expanded.
	##
	## `timeout_ms`, `stdout_limit_bytes` and `stderr_limit_bytes` are always
	## set -- `Cmd` has no way to build a command without them -- and the host
	## clamps each limit to its own ceiling.
	RunArgs : {
		program : Str,
		args : List(Str),
		envs : List(EnvPair),
		clear_envs : Bool,
		working_dir : Str,
		timeout_ms : U64,
		stdout_limit_bytes : U64,
		stderr_limit_bytes : U64,
	}

	## A finished child, or the reason there is none.
	##
	## `err` is `0` when the child ran to its own end, whatever it exited with:
	## a non-zero `exit_code` is data, not an error. When `err` is the deadline
	## code, `stdout` and `stderr` hold what the child had written before it
	## was killed and `exit_code` is `-1`. Every other code leaves all three
	## empty or zero.
	RunResult : {
		err : U8,
		exit_code : I64,
		stdout : List(U8),
		stderr : List(U8),
	}

	## Start one child process and wait for it to finish.
	run! : RunArgs => RunResult
}
