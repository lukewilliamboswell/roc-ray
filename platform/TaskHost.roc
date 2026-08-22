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
}
