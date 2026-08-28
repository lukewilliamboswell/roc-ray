## Work that waits without blocking the frame loop.
##
## Spawn tasks from `update!` or another task. Waiting effects park the task;
## its single return value arrives on a later `Input.messages`. Tasks run
## serially on the frame thread, so pure computation still blocks frames.
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
## Thirty-two tasks run at once. A spawn past that is queued and started in
## submission order as a slot frees, so spawning never fails and no closure is
## dropped. At shutdown live tasks are cancelled, queued closures are dropped,
## and messages that were produced but never delivered are released.
import App
import Host

Task := [].{

	## Start a task. Its message arrives on a later `Input.messages`, in the
	## order the tasks finished.
	##
	## Pass the current `App.Input` as the first argument. It pins the closure's
	## return type to the app's `Msg`; it is not otherwise read.
	##
	## A task closure may capture the input, so a task can spawn more tasks.
	##
	## The task may start before `spawn!` returns or after `update!`; it reaches
	## its first wait or finishes before that cycle's `render!`. Do not assume
	## ordering between its synchronous work and the spawning `update!`.
	## Messages are delivered in task-completion order.
	##
	## When the same kind of work can be in flight more than once, a reply can
	## arrive after a newer one. Put a generation counter or id in the message
	## and drop replies that do not match the latest; `examples/http_fetch`
	## shows the shape.
	##
	## This is the only way to start a task. `Input` is a pure value declared in
	## the `roc-ray-types` package and has no effectful receivers, so there is no
	## `input.spawn!` form.
	##
	## Legal in `update!` and in tasks; refused in `init!` and `render!`. `init!`
	## never sees the answering input, and `render!` does not change the world.
	spawn! : App.Input(msg), (() => msg) => {}
	spawn! = |_input, task!| Host.task_spawn!(Box.box(task!))

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
	## Everything `spawn!` says about the `App.Input` witness, about when a task's
	## message arrives, and about which callbacks may spawn applies here
	## unchanged.
	##
	## Legal in `update!` and in tasks; refused in `init!` and `render!`.
	spawn_with! : App.Input(msg), (() => a), (a -> msg) => {}
	spawn_with! = |input, task!, wrap| Task.spawn!(input, || wrap(task!()))

	## Wait at least `millis` without stalling the frame.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	sleep! : U64 => {}
	sleep! = |millis| Host.task_sleep!(millis)
}
