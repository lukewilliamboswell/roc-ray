## Deferred work that runs alongside the frame loop.
##
## A task is an effectful closure handed to `Task.spawn!` from `update!` (or
## from another task). The host runs it on its own coroutine stack, on the
## frame thread, and delivers its return value on a later `Input.messages`.
## Effects that wait -- `Task.sleep!`, `Files.read_text!`, `Http.send!` --
## park the task rather than the frame.
##
##     update! = |model, input| {
##         if input.devices.key_pressed(KeyEnter) {
##             Task.spawn!(
##                 input,
##                 || {
##                     Task.sleep!(300)
##                     Woke
##                 },
##             )
##         }
##         Ok(model)
##     }
##
## A task shares the frame thread, so a long pure computation inside one
## stalls the frame just as it would inside `update!`.
import App
import TaskHost

Task := [].{

	## Start a task. Its message arrives on a later `Input.messages`, in the
	## order tasks complete.
	##
	## The first argument is the `App.Input` that `update!` was handed. It is
	## never read: it is a *witness* that pins the closure's return type to the
	## app's own `Msg`. Without it `msg` stays free at the call site, the
	## closure compiles at whatever type its body alone implies -- often a
	## single-tag union with no discriminant -- and the host decodes the result
	## as the app's real `Msg`, producing the wrong tag or a misread payload.
	## Only `main.roc` can name the `requires` bound `Msg`, so an `App.Input`
	## is how every other module names it.
	##
	## A task closure may capture the input, so a task can spawn more tasks.
	##
	## `input.spawn!(|| ...)` is the same effect written as a receiver.
	##
	## Valid during `update!` and inside a task. Calling it from `init!` or
	## `render!` is a programmer error and stops the app.
	spawn! : App.Input(msg), (() => msg) => {}
	spawn! = |input, task!| App.Input.spawn!(input, task!)

	## Wait at least `millis` without stalling the frame.
	##
	## Valid inside a task, where it parks the coroutine, and inside `init!`,
	## where it blocks. Calling it from `update!` or `render!` is a programmer
	## error and stops the app.
	sleep! : U64 => {}
	sleep! = |millis| TaskHost.sleep!(millis)
}
