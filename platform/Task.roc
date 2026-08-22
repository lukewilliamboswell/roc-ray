## Deferred work that runs alongside the frame loop.
##
## A task is an effectful closure handed to `Task.spawn!` from `update!` (or
## from another task). The host runs it on its own coroutine stack, on the
## frame thread, and delivers its return value on a later `Input.messages`.
## Effects that wait -- `Task.sleep!` -- park the task rather than the frame.
##
##     update! = |model, input| {
##         if input.devices.key_pressed(KeyEnter) {
##             Task.spawn!(|| {
##                 Task.sleep!(300)
##                 Woke
##             })
##         }
##         Ok(model)
##     }
##
## A task shares the frame thread, so a long pure computation inside one
## stalls the frame just as it would inside `update!`.
import TaskHost

Task := [].{

	## Start a task. Its message arrives on a later `Input.messages`, in the
	## order tasks complete.
	##
	## Valid during `update!` and inside a task. Calling it from `init!` or
	## `render!` is a programmer error and stops the app.
	spawn! : (() => msg) => {}
	spawn! = |task!| TaskHost.spawn!(Box.box(task!))

	## Wait at least `millis` without stalling the frame.
	##
	## Valid inside a task, where it parks the coroutine, and inside `init!`,
	## where it blocks. Calling it from `update!` or `render!` is a programmer
	## error and stops the app.
	sleep! : U64 => {}
	sleep! = |millis| TaskHost.sleep!(millis)
}
