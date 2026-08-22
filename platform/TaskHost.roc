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
	## `Box(msg)`, and the reason is a defect in `roc glue` rather than
	## something this platform prefers. Glue decides a list's
	## element-refcountedness from `layoutContainsRefcounted`, which reports
	## `false` for `box_of_zst` -- the layout every `Box(a)` gets while `a` is
	## still a platform's `requires`-bound rigid. A `List(Box(msg))` field is
	## therefore rendered as `RocListWith(RocBox, false)`, whose header is one
	## pointer word. Every Roc backend widens that same decision with
	## `layoutContainsRcErasedBox` before it allocates or frees such a list, so
	## the allocation really carries the two-word refcounted prefix: the host
	## then computes `elements_ptr - 8` where the allocation began at
	## `elements_ptr - 16` and frees eight bytes past the base. The generated
	## release policy compounds it -- an erased box gets no element policy, so
	## the list would be released spine-only and every boxed message would leak.
	##
	## An `erased_callable` *is* reported refcounted, so the thunk is rendered
	## as `RocList(RocErasedCallable)` with the two-word header and a real
	## element policy, and crosses the boundary the way every other erased
	## callable does. The cost is one extra box and one extra call per message.
	##
	## Verified on `nightly-2026-08-21-90da19f`, in the emitted glue and in a
	## standalone platform whose host records every allocation base.
	## `docs/spike-coro-findings.md` has the reproduction; in the compiler the
	## decision is `is_type_refcounted` in `src/glue/src/ZigGlue.roc` reading
	## `abi.contains_refcounted`, which `src/glue/glue.zig` sets from
	## `store.layoutContainsRefcounted`, against the `layoutContainsRcErasedBox`
	## widening each backend applies.
	##
	## TODO(compiler): deliver `List(Box(msg))` directly once glue widens
	## `is_type_refcounted` the way the backends do, and emits a `decrefBox`
	## element policy for an erased box.
	FinishedTask(msg) : {
		deliver : Box({} -> Box(msg)),
	}
}
