## Deferred work that runs alongside the frame loop.
##
## A task is an effectful closure returned from `update` with
## `Transition.with_task`. The host runs it on its own coroutine stack, on the
## frame thread, and delivers its return value on a later `Input.messages`.
## Effects that wait -- `Task.sleep!` -- park the task rather than the frame.
##
## Spike surface (see COROUTINE_DESIGN_PROPOSAL.md): only `sleep!` waits today.
import TaskHost

Task := [].{

	## Wait at least `millis` without stalling the frame.
	##
	## Valid inside a task, where it parks the coroutine, and inside `init!`,
	## where it blocks. Calling it from `update` or `render!` is a programmer
	## error and stops the app.
	sleep! : U64 => {}
	sleep! = |millis| TaskHost.sleep!(millis)
}
