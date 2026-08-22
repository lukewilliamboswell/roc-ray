## Work that waits, running alongside the frame loop.
##
## A task is an effectful closure handed to `Task.spawn!` from `update!` (or
## from another task). The host runs it on its own stack, on the frame thread,
## and delivers its return value on a later `Input.messages`. Effects that
## wait -- `Task.sleep!`, `Files.read_text!`, `Http.send!` -- park the task
## rather than the frame.
##
## ```roc
## update! = |model, input| {
##     if input.devices.key_pressed(KeyEnter) {
##         Task.spawn!(
##             input,
##             || {
##                 Task.sleep!(300)
##                 Woke
##             },
##         )
##     }
##     Ok(model)
## }
## ```
##
## Because a task is straight-line code, a multi-step operation is an ordinary
## function -- load, then parse, then fetch, with `?` propagating failures --
## rather than a state machine spread across message variants. A task cannot
## read or write the model, so whatever the model must learn has to be in the
## message it returns.
##
## Tasks buy overlap for waiting, not for computing. They share the frame
## thread and yield only at a waiting effect, so a long pure computation inside
## one stalls the frame exactly as it would inside `update!`.
##
## Thirty-two tasks run at once. A spawn past that is queued and started in
## submission order as a slot frees, so spawning never fails and no closure is
## dropped. At shutdown live tasks are cancelled, queued closures are dropped,
## and messages that were produced but never delivered are released.
import App
import TaskHost

Task := [].{

	## Start a task. Its message arrives on a later `Input.messages`, in the
	## order the tasks finished.
	##
	## The first argument is the `App.Input` that `update!` was handed. It is
	## never read: it is the witness that pins the closure's return type to the
	## app's own `Msg`. Without it `msg` stays free at the call site, the
	## closure compiles at whatever type its body alone implies -- often a
	## single-tag union with no discriminant -- while the host decodes the
	## result as the app's real `Msg`, producing the wrong tag or a misread
	## payload. Only the platform's entry module can name the `requires` bound
	## `Msg`, so an `App.Input` is how every other module names it. Pass the
	## input the callback already has; there is nothing to construct.
	##
	## A task closure may capture the input, so a task can spawn more tasks.
	##
	## When the task starts is the host's choice. It may run up to its first
	## waiting effect before `spawn!` returns, or in the host's turn after
	## `update!` returns; either way it has reached its first wait, or finished,
	## before `render!` of the same cycle. Its code and its synchronous effects
	## can therefore interleave with the rest of the `update!` that spawned it,
	## so do not assume an order between the two. The only order a task promises
	## is its message's: on a later cycle, after every task that finished first.
	##
	## When the same kind of work can be in flight more than once, a reply can
	## arrive after a newer one. Put a generation counter or id in the message
	## and drop replies that do not match the latest; `examples/http_fetch`
	## shows the shape.
	##
	## `input.spawn!(|| ...)` is the same effect written as a receiver.
	##
	## Legal in `update!` and in tasks; refused in `init!` and `render!`. `init!`
	## never sees the answering input, and `render!` does not change the world.
	spawn! : App.Input(msg), (() => msg) => {}
	spawn! = |input, task!| App.Input.spawn!(input, task!)

	## Start a task whose message belongs to a component, wrapped into the app's
	## own `Msg` on the way back.
	##
	## `spawn!` needs the closure to answer in the app's `Msg`, which forces a
	## component to know the type of the app that hosts it. `spawn_with!` splits
	## that in two: the closure answers in the component's own message type, and
	## the parent supplies the constructor that lifts it.
	##
	## ```roc
	## # Counter.roc -- knows nothing about the app's Msg
	## Msg : [Loaded(U64), LoadFailed]
	## load! : () => Msg
	##
	## # the app -- Msg : [CounterMsg(Counter.Msg), ...]
	## Task.spawn_with!(input, Counter.load!, |m| CounterMsg(m))
	## ```
	##
	## A bare tag name is not a function, so the wrapper is written as the lambda
	## `|m| CounterMsg(m)` rather than as `CounterMsg`.
	##
	## The wrapper runs on the task's own stack, right after the closure returns
	## and before the message is handed back, so it is ordinary pure code and not
	## a second scheduled step.
	##
	## `input.spawn_with!(task!, wrap)` is the same effect written as a receiver.
	## Everything `spawn!` says about the `App.Input` witness, about when a task's
	## message arrives, and about which callbacks may spawn applies here
	## unchanged.
	##
	## Legal in `update!` and in tasks; refused in `init!` and `render!`.
	spawn_with! : App.Input(msg), (() => a), (a -> msg) => {}
	spawn_with! = |input, task!, wrap| App.Input.spawn_with!(input, task!, wrap)

	## Wait at least `millis` without stalling the frame.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	sleep! : U64 => {}
	sleep! = |millis| TaskHost.sleep!(millis)
}
