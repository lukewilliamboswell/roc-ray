## Internal transport for coroutine-backed tasks.
##
## This module is intentionally not exposed by the platform package. `Task` is
## the public wrapper; `run_task_for_host!` in `main.roc` is the only other
## place a task's message type is named.
TaskHost := [].{

	## Park the calling task for at least this many milliseconds. The host runs
	## the frame loop while it waits; inside `init!` it blocks instead.
	sleep! : U64 => {}

	## Run an erased task closure on its own coroutine. Only the adapter's
	## `run_task_for_host!` ever names the message type again.
	spawn! : Box(() => msg) => {}

	## One finished task's message, on its way back to `update!`.
	##
	## The message travels in an erased thunk rather than a `Box(msg)` to work
	## around a defect in `roc glue`. Glue renders a `List(Box(msg))` field with
	## a one-word list header, because `layoutContainsRefcounted` reports
	## `false` for the `box_of_zst` layout a `Box(a)` gets while `a` is a
	## platform's `requires`-bound rigid. Every backend widens the same decision
	## with `layoutContainsRcErasedBox` before allocating or freeing such a
	## list, so the allocation really carries the two-word refcounted prefix and
	## the host frees eight bytes past its base. The generated release policy
	## gives an erased box no element policy either, so the boxed messages would
	## leak. An `erased_callable` is reported refcounted, so a thunk crosses
	## correctly, for one extra box and one extra call per message.
	##
	## In the compiler the decision is `is_type_refcounted` in
	## `src/glue/src/ZigGlue.roc`, reading the `abi.contains_refcounted` that
	## `src/glue/glue.zig` sets from `store.layoutContainsRefcounted`.
	##
	## TODO(compiler): deliver `List(Box(msg))` directly once glue widens
	## `is_type_refcounted` the way the backends do, and emits a `decrefBox`
	## element policy for an erased box.
	FinishedTask(msg) : {
		deliver : Box({} -> Box(msg)),
	}
}
