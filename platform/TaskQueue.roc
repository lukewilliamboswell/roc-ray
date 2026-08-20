## A pure FIFO queue that paces deferred host work.
##
## The host accepts a bounded number of tasks that have not yet been answered --
## 32 -- and answers anything past that with a terminal `Err(Busy)`. An app that
## wants two hundred files read therefore cannot hand the platform two hundred
## tasks. It has to release a few, wait for their completions, and refill.
##
## `TaskQueue` is exactly that bookkeeping, and nothing else. It performs no
## effect and holds no host resource: it is ordinary model data that an app
## keeps beside the rest of its state, so its pacing is as testable as any other
## pure function it writes.
##
## Choose a `max_in_flight` well under the platform's 32 -- 8 to 16 is a good
## range. The cap is shared with every other task the app submits, so leaving
## room means a screenshot or a clipboard read still gets a slot, and it makes
## `Err(Busy)` a genuine surprise rather than part of the steady state.
##
## Wiring one into `update` is three moves: enqueue on demand, release on every
## step, and call `completed` while handling each message that ends one of the
## queue's tasks. A complete app reads like this.
##
##     Model : {
##         queue : TaskQueue.TaskQueue(Msg),
##         loaded : List(Str),
##     }
##
##     Msg : [
##         LoadRequested(List(Str)),
##         Loaded(Str, Try(Str, Program.SmallFileError)),
##     ]
##
##     # One task per path, each remembering the path it was for. The message
##     # has to carry whatever rebuilding the request would need.
##     load_task : Str -> Program.Task(Msg)
##     load_task = |path| Program.read_small_file(path, |result| Loaded(path, result))
##
##     update : Model, Program.Step(Msg) -> Program.Update(Model, Msg)
##     update = |model, step| {
##         # 1. Fold this step's messages into the model.
##         settled = List.fold(step.messages, model, handle)
##
##         # 2. Release whatever fits, every step. This is safe to call when
##         #    there is nothing to send and when there is no room to send it;
##         #    both answer with an empty list, so there is no state to test
##         #    first.
##         released = settled.queue.release()
##
##         Program.static({ ..settled, queue: released.queue })
##             .with_tasks(released.tasks)
##     }
##
##     handle : Model, Msg -> Model
##     handle = |model, msg|
##         match msg {
##             # 3a. Enqueue on demand. Nothing is submitted here; `release`
##             #     decides when, later in the same update.
##             LoadRequested(paths) => {
##                 ..model,
##                 queue: model.queue.enqueue_all(List.map(paths, load_task)),
##             }
##
##             # 3b. A refused task still ends -- so the slot it held is free,
##             #     and the work goes back on the queue as a *new* task.
##             Loaded(path, Err(Busy)) => {
##                 ..model,
##                 queue: model.queue.completed().enqueue(load_task(path)),
##             }
##
##             # 3c. Every other terminal result also frees a slot.
##             Loaded(_, result) => {
##                 ..model,
##                 queue: model.queue.completed(),
##                 loaded: match result {
##                     Ok(contents) => List.append(model.loaded, contents)
##                     Err(_) => model.loaded
##                 },
##             }
##         }
##
## Step 3b builds a *new* task from the path rather than putting back the one
## that failed, and it has to. A `Task` owns the typed callback that turns its
## one terminal result into a message; the platform consumed that callback when
## it delivered `Err(Busy)`, and what the app is holding now is the message that
## callback produced, not the task behind it. A `Task` is single-use by
## construction -- exactly-once delivery is what makes that true -- so the
## message must carry whatever rebuilding the request needs. That is why
## `Loaded` carries its path. `Busy` should be rare while `max_in_flight` stays
## well under the platform's cap, since pacing is what the queue is for, but it
## is worth handling: the cap is shared with every other task the app submits.
##
## `completed` is the app's promise that one released task will send no further
## messages. Call it once per message that ends one of *this queue's* tasks, and
## not for messages from tasks the app submitted outside the queue -- the queue
## cannot tell them apart, and an unmatched `completed` frees a slot that is
## still occupied. Missing one is the safer mistake: the queue drains more
## slowly, but it will never oversubscribe the host.
##
## ## Knowing which requests just went out
##
## `release` answers with `Task` values, and a `Task` says nothing about itself:
## it owns a callback, and nothing can be read back off a function. So an app
## that wants to show "these three files are being read right now" cannot get
## that from the queue directly.
##
## It does not need to. `release` is FIFO -- it returns exactly the first N
## tasks of the backlog in enqueue order -- so an app that keeps its own list of
## what each task was for, in the same order, stays in lockstep with the queue
## by construction. Pop `List.len(released.tasks)` entries off the front of that
## list and those are the requests now in flight:
##
##     Model : {
##         queue : TaskQueue.TaskQueue(Msg),
##
##         # One entry per task waiting in `queue`, in the same order. This is
##         # the whole trick: the queue holds the work, this holds its name.
##         queued : List(Str),
##         reading : List(Str),
##     }
##
##     released = model.queue.release()
##     split = List.split_at(model.queued, List.len(released.tasks))
##
##     # `split.before` names exactly the tasks in `released.tasks`, in order.
##     next = { ..model, queue: released.queue, queued: split.others, reading: List.concat(model.reading, split.before) }
##
## The two lists have to be written together to stay together. Enqueue a task
## and append its tag in the same expression; re-enqueue a `Busy` retry and
## append its tag to the back as well, since the task goes to the back. A tag
## can be anything the app can identify a request by -- a path, a lane index, a
## message constructor -- and the message that ends the task has to carry it
## back, which it must do anyway to rebuild a refused request.
import Program

## Deferred work an app is releasing to the host a few at a time.
##
## The bookkeeping is wrapped for the same reason `Program.Update`'s is: the
## fields are not reachable by field access, so a queue is read and written
## through its receivers and the pacing arithmetic lives in exactly one place.
## `pending` is the FIFO backlog, `in_flight` counts tasks released but not yet
## reported through `completed`, and `max_in_flight` is the ceiling `release`
## will not exceed.
TaskQueue(msg) := [
	Queue(
		{
			pending : List(Program.Task(msg)),
			in_flight : U64,
			max_in_flight : U64,
		},
	),
].{

	## An empty queue that will keep at most `max_in_flight` tasks with the host.
	##
	## The platform's own cap is 32 tasks in flight across the whole app; stay
	## well under it, around 8 to 16, so other work the app submits still finds
	## a free slot. A `max_in_flight` of 0 is legal and releases nothing, which
	## is a way to hold work back without draining the backlog.
	new : U64 -> TaskQueue(msg)
	new = |max_in_flight| TaskQueue.(Queue({ pending: [], in_flight: 0, max_in_flight: max_in_flight }))

	## Add one task to the back of the backlog.
	##
	## Nothing is submitted here. `release` decides when, and how many.
	enqueue : TaskQueue(msg), Program.Task(msg) -> TaskQueue(msg)
	enqueue = |queue, task| {
		state = unwrap(queue)
		TaskQueue.(Queue({ ..state, pending: List.append(state.pending, task) }))
	}

	## Add tasks to the back of the backlog, keeping their order.
	enqueue_all : TaskQueue(msg), List(Program.Task(msg)) -> TaskQueue(msg)
	enqueue_all = |queue, tasks| {
		state = unwrap(queue)
		TaskQueue.(Queue({ ..state, pending: List.concat(state.pending, tasks) }))
	}

	## Take as many tasks off the front as the in-flight budget has room for.
	##
	## Answers with the tasks to submit and the queue to store back in the
	## model, which has already counted them as in flight:
	##
	##     released = model.queue.release()
	##     Program.static({ ..model, queue: released.queue }).with_tasks(released.tasks)
	##
	## Call it on every update. When the backlog is empty or the budget is full
	## it answers with no tasks and an unchanged queue, so there is no condition
	## to test before calling it and no step on which a drained queue stalls.
	##
	## **Release is FIFO, and that is a guarantee.** `released.tasks` is exactly
	## the first `List.len(released.tasks)` tasks of the backlog, in the order
	## they were enqueued; the tasks left behind keep their order too. Nothing is
	## reordered, skipped, or coalesced, and the count is the smaller of the
	## remaining budget and the backlog length.
	##
	## That is what makes the released tasks identifiable. A `Task` is opaque --
	## it owns a callback, so nothing can be read back off one -- but an app that
	## keeps its own list of what each enqueued task was *for*, in the same
	## order, can pop that many entries off the front of its own list and know
	## precisely which requests just went out. See the lockstep recipe in this
	## module's documentation.
	release : TaskQueue(msg) -> { queue : TaskQueue(msg), tasks : List(Program.Task(msg)) }
	release = |queue| {
		state = unwrap(queue)
		room = if state.in_flight >= state.max_in_flight 0 else state.max_in_flight - state.in_flight
		split = List.split_at(state.pending, U64.min(room, List.len(state.pending)))
		{
			queue: TaskQueue.(Queue({ ..state, pending: split.others, in_flight: state.in_flight + List.len(split.before) })),
			tasks: split.before,
		}
	}

	## Record that one released task has produced its terminal message.
	##
	## Call this while handling each message that ends one of this queue's
	## tasks, including the `Err(Busy)` a saturated host answers with. The count
	## floors at zero, so an extra call cannot wrap it into a budget that never
	## releases again.
	completed : TaskQueue(msg) -> TaskQueue(msg)
	completed = |queue| {
		state = unwrap(queue)
		TaskQueue.(Queue({ ..state, in_flight: if state.in_flight == 0 0 else state.in_flight - 1 }))
	}

	## How many tasks are waiting to be released.
	pending_len : TaskQueue(msg) -> U64
	pending_len = |queue| List.len(unwrap(queue).pending)

	## How many released tasks have not yet been reported through `completed`.
	in_flight : TaskQueue(msg) -> U64
	in_flight = |queue| unwrap(queue).in_flight

	## The ceiling `release` will not exceed.
	max_in_flight : TaskQueue(msg) -> U64
	max_in_flight = |queue| unwrap(queue).max_in_flight
}

## Open the private wrapper. Module-internal, so the bookkeeping stays reachable
## only through the receivers above.
unwrap : TaskQueue(msg) -> { pending : List(Program.Task(msg)), in_flight : U64, max_in_flight : U64 }
unwrap = |queue|
	match queue {
		Queue(state) => state
	}

## Tasks distinguishable by shape, so the tests can assert on FIFO order.
##
## `Program.task_shape` is how a test looks at a task at all: a `Task` owns a
## callback, and equality cannot inspect a function.
numbered_task : U64 -> Program.Task(Str)
numbered_task = |millis| Program.delay(millis, |_| "elapsed")

shapes : List(Program.Task(Str)) -> List(Program.TaskShape)
shapes = |tasks| List.map(tasks, Program.task_shape)

## A queue holding one task per entry of `millis`, with none released yet.
filled : U64, List(U64) -> TaskQueue(Str)
filled = |max_in_flight, millis|
	TaskQueue.new(max_in_flight).enqueue_all(List.map(millis, numbered_task))

expect TaskQueue.new(8).pending_len() == 0
expect TaskQueue.new(8).in_flight() == 0
expect TaskQueue.new(8).max_in_flight() == 8

## Enqueueing submits nothing on its own.
expect TaskQueue.new(2).enqueue(numbered_task(1)).pending_len() == 1
expect TaskQueue.new(2).enqueue(numbered_task(1)).in_flight() == 0
expect filled(2, [1, 2, 3, 4, 5]).pending_len() == 5

## `enqueue_all` keeps the order it was given, and appends behind what is
## already waiting.
expect shapes(TaskQueue.new(9).enqueue_all([numbered_task(1), numbered_task(2)]).enqueue(numbered_task(3)).release().tasks)
	== [Delay({ millis: 1 }), Delay({ millis: 2 }), Delay({ millis: 3 })]

## A release is capped by the budget, and takes from the front.
expect shapes(filled(3, [1, 2, 3, 4, 5]).release().tasks) == [Delay({ millis: 1 }), Delay({ millis: 2 }), Delay({ millis: 3 })]
expect filled(3, [1, 2, 3, 4, 5]).release().queue.pending_len() == 2
expect filled(3, [1, 2, 3, 4, 5]).release().queue.in_flight() == 3

## The rest waits, in order, until a slot frees. A `Task` owns a callback, so
## these count what came back rather than comparing it.
expect List.is_empty(filled(3, [1, 2, 3, 4, 5]).release().queue.release().tasks)
expect shapes(filled(3, [1, 2, 3, 4, 5]).release().queue.completed().release().tasks) == [Delay({ millis: 4 })]
expect shapes(filled(3, [1, 2, 3, 4, 5]).release().queue.completed().completed().release().tasks)
	== [Delay({ millis: 4 }), Delay({ millis: 5 })]

## A backlog shorter than the budget releases all of it and no more.
expect shapes(filled(8, [1, 2]).release().tasks) == [Delay({ millis: 1 }), Delay({ millis: 2 })]
expect filled(8, [1, 2]).release().queue.in_flight() == 2
expect filled(8, [1, 2]).release().queue.pending_len() == 0

## Releasing an empty queue is the idle case, and it is safe on every step.
expect List.is_empty(TaskQueue.new(8).release().tasks)
expect TaskQueue.new(8).release().queue.in_flight() == 0
expect List.is_empty(filled(8, [1, 2]).release().queue.release().queue.release().tasks)

## A zero budget holds everything back without losing it.
expect List.is_empty(filled(0, [1, 2, 3]).release().tasks)
expect filled(0, [1, 2, 3]).release().queue.pending_len() == 3

## Completions free slots one at a time, and floor at zero rather than wrapping
## into a budget that would never release again.
expect TaskQueue.new(4).completed().in_flight() == 0
expect TaskQueue.new(4).completed().completed().in_flight() == 0
expect filled(2, [1, 2, 3, 4]).release().queue.completed().in_flight() == 1
expect filled(2, [1, 2, 3, 4]).release().queue.completed().completed().completed().in_flight() == 0
expect shapes(filled(2, [1, 2, 3, 4]).release().queue.completed().completed().completed().release().tasks)
	== [Delay({ millis: 3 }), Delay({ millis: 4 })]

## A `Busy` retry goes to the back as a freshly built task, because the failed
## one's callback was consumed by the delivery that reported the failure.
expect shapes(filled(1, [1, 2]).release().queue.completed().enqueue(numbered_task(1)).release().tasks)
	== [Delay({ millis: 2 })]
expect shapes(filled(1, [1, 2]).release().queue.completed().enqueue(numbered_task(1)).release().queue.completed().release().tasks)
	== [Delay({ millis: 1 })]

## Draining the whole backlog a budget at a time preserves FIFO order overall.
drained : List(Program.TaskShape)
drained = drain(filled(2, [1, 2, 3, 4, 5]), [])

drain : TaskQueue(Str), List(Program.TaskShape) -> List(Program.TaskShape)
drain = |queue, seen| {
	released = queue.release()
	if List.is_empty(released.tasks) {
		seen
	} else {
		drain(
			List.fold(released.tasks, released.queue, |acc, _task| acc.completed()),
			List.concat(seen, shapes(released.tasks)),
		)
	}
}

expect drained == [
	Delay({ millis: 1 }),
	Delay({ millis: 2 }),
	Delay({ millis: 3 }),
	Delay({ millis: 4 }),
	Delay({ millis: 5 }),
]

# --- Release is FIFO, and an app can rely on it ------------------------------

## Nine tasks, distinguishable by shape, released three at a time.
nine : TaskQueue(Str)
nine = filled(3, [1, 2, 3, 4, 5, 6, 7, 8, 9])

## A release is a prefix of the backlog, in enqueue order -- not a subset of it
## and not a reordering of one. This is the guarantee `release` states.
expect shapes(nine.release().tasks) == [Delay({ millis: 1 }), Delay({ millis: 2 }), Delay({ millis: 3 })]

## And what stays behind is the rest of the backlog, still in order. A release
## that reordered the remainder would leave the app's parallel list aligned with
## nothing.
expect shapes(nine.release().queue.completed().completed().completed().release().tasks)
	== [Delay({ millis: 4 }), Delay({ millis: 5 }), Delay({ millis: 6 })]

## The count is the smaller of the remaining budget and the backlog length, so
## the prefix an app pops off its own list is `List.len(released.tasks)` and
## never the budget.
expect List.len(filled(3, [1, 2]).release().tasks) == 2
expect List.len(filled(3, [1, 2, 3, 4]).release().tasks) == 3
expect List.len(filled(3, []).release().tasks) == 0
expect List.len(nine.release().queue.release().tasks) == 0

## A partial completion releases exactly the freed slots, still from the front.
expect shapes(nine.release().queue.completed().release().tasks) == [Delay({ millis: 4 })]

## The lockstep recipe from this module's documentation, run for real: the app
## keeps a parallel list of tags and pops `List.len(released.tasks)` from the
## front of it. `Lockstep.tags` are the requests it believes are in flight;
## `Lockstep.observed` is what the queue actually released, by shape. If the two
## ever disagreed, the tags would be naming the wrong requests.
Lockstep : {
	queue : TaskQueue(Str),
	queued : List(U64),
	tags : List(U64),
	observed : List(Program.TaskShape),
}

## Start a lockstep with one task per entry of `millis`, tagged by that entry.
## Enqueueing the task and appending its tag happen together, which is the
## discipline the recipe asks for.
lockstep_of : U64, List(U64) -> Lockstep
lockstep_of = |max_in_flight, millis| {
	queue: filled(max_in_flight, millis),
	queued: millis,
	tags: [],
	observed: [],
}

## One cycle: release whatever fits, and move that many tags across with it.
lockstep_release : Lockstep -> Lockstep
lockstep_release = |state| {
	released = state.queue.release()
	split = List.split_at(state.queued, List.len(released.tasks))
	{
		queue: released.queue,
		queued: split.others,
		tags: List.concat(state.tags, split.before),
		observed: List.concat(state.observed, shapes(released.tasks)),
	}
}

## Report every released task as completed, freeing its slot.
lockstep_settle : Lockstep -> Lockstep
lockstep_settle = |state| {
	..state,
	queue: List.fold(state.tags, state.queue, |queue, _tag| queue.completed()),
}

## Drain a lockstep to the end, releasing and settling one cycle at a time.
lockstep_drain : Lockstep -> Lockstep
lockstep_drain = |state| {
	next = lockstep_release(state)
	if List.len(next.tags) == List.len(state.tags) {
		next
	} else {
		lockstep_drain(lockstep_settle(next))
	}
}

## The tags a cycle pops name exactly the tasks it released, in order.
expect lockstep_release(lockstep_of(3, [1, 2, 3, 4, 5, 6, 7, 8, 9])).tags == [1, 2, 3]
expect lockstep_release(lockstep_of(3, [1, 2, 3, 4, 5, 6, 7, 8, 9])).observed
	== [Delay({ millis: 1 }), Delay({ millis: 2 }), Delay({ millis: 3 })]

## What is left of the app's list still lines up with what is left of the queue.
expect lockstep_release(lockstep_of(3, [1, 2, 3, 4, 5, 6, 7, 8, 9])).queued == [4, 5, 6, 7, 8, 9]

## Across a whole drain, in several budget-sized rounds, the tags the app
## believes are in flight are exactly the tasks the queue released -- every
## time, in the same order. That is the guarantee, checked rather than asserted.
expect {
	drained_state = lockstep_drain(lockstep_of(3, [1, 2, 3, 4, 5, 6, 7, 8, 9]))
	List.map(drained_state.tags, |tag| Delay({ millis: tag })) == drained_state.observed
		and drained_state.tags == [1, 2, 3, 4, 5, 6, 7, 8, 9]
			and List.is_empty(drained_state.queued)
}

## A budget of one makes every round a single task, and the alignment holds
## there too -- the case where an off-by-one would be loudest.
expect {
	single = lockstep_drain(lockstep_of(1, [7, 8, 9]))
	List.map(single.tags, |tag| Delay({ millis: tag })) == single.observed and single.tags == [7, 8, 9]
}

## A backlog shorter than the budget is released whole, and nothing is left over
## for the app's list to be out of step with.
expect {
	short = lockstep_release(lockstep_of(8, [4, 5]))
	short.tags == [4, 5] and List.is_empty(short.queued)
}

## Releasing an empty queue moves no tags, so a cycle with nothing to send
## cannot advance the app's list past the queue's.
expect List.is_empty(lockstep_release(lockstep_of(8, [])).tags)
expect lockstep_release(lockstep_release(lockstep_of(3, [1, 2, 3, 4]))).tags == [1, 2, 3]
