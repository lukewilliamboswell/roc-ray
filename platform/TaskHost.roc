## Internal transport for coroutine-backed tasks.
##
## This module is intentionally not exposed by the platform package.
TaskHost := [].{

	## Park the calling task for at least this many milliseconds. The host runs
	## the frame loop while it waits; inside `init!` it blocks instead.
	sleep! : U64 => {}

	## Run an erased task closure on its own coroutine. Only the adapter's
	## `run_task_for_host!` ever names the message type again.
	spawn! : Box(() => msg) => {}

	## One finished task's message, on its way back to `update!`.
	##
	## The message is wrapped in an erased thunk rather than handed over as a
	## `Box(msg)`, because a `List(Box(msg))` is rendered by `roc glue` with a
	## one-word list header while Roc releases it as a list of refcounted
	## elements -- the host then frees eight bytes off the allocation base. The
	## thunk is an ordinary `RocErasedCallable`, which crosses the boundary the
	## way every other erased callable does.
	##
	## TODO(compiler): deliver `List(Box(msg))` directly once that glue bug is
	## fixed. `docs/spike-coro-findings.md` has the reproduction.
	FinishedTask(msg) : {
		deliver : Box({} -> Box(msg)),
	}
}
