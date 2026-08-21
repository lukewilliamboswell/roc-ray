## A pure FIFO queue that paces deferred host work.
##
## The host accepts a bounded number of requests that have not yet been answered --
## 32 -- and answers anything past that with a terminal `Err(Busy)`. An app that
## wants two hundred files read therefore cannot hand the platform two hundred
## requests. It takes a ready prefix, waits for its responses, and refills.
##
## `RequestQueue` is exactly that bookkeeping, and nothing else. It performs no
## effect and holds no host resource: it is ordinary model data that an app
## keeps beside the rest of its state, so its pacing is as testable as any other
## pure function it writes.
##
## Choose a `max_in_flight` well under the platform's 32 -- 8 to 16 is a good
## range. The cap is shared with every other request the app submits, so leaving
## room means a screenshot or a clipboard read still gets a slot, and it makes
## `Err(Busy)` a genuine surprise rather than part of the steady state.
##
## Wiring one into `update` is three moves: enqueue on demand, take_ready on every
## input, and call `response_received` while handling each message that ends one of the
## queue's requests. A complete app reads like this.
##
##     Model : {
##         queue : RequestQueue.Queue(Msg),
##         loaded : List(Str),
##     }
##
##     Msg : [
##         LoadRequested(List(Str)),
##         Loaded(Str, Try(Str, App.SmallFileError)),
##     ]
##
##     # One request per path, each remembering the path it was for. The message
##     # has to carry whatever rebuilding the request would need.
##     load_request : Str -> App.Request(Msg)
##     load_request = |path| App.read_small_file(path, |result| Loaded(path, result))
##
##     update : Model, App.Input(Msg) -> App.Transition(Model, Msg)
##     update = |model, input| {
##         # 1. Fold this input's messages into the model.
##         settled = List.fold(input.messages, model, handle)
##
##         # 2. Take the ready prefix, every input. This is safe to call when
##         #    there is nothing to send and when there is no room to send it;
##         #    both answer with an empty list, so there is no state to test
##         #    first.
##         ready = settled.queue.take_ready()
##
##         App.next({ ..settled, queue: ready.queue })
##             .with_requests(ready.requests)
##     }
##
##     handle : Model, Msg -> Model
##     handle = |model, msg|
##         match msg {
##             # 3a. Enqueue on demand. Nothing is submitted here; `take_ready`
##             #     decides when, later in the same update.
##             LoadRequested(paths) => {
##                 ..model,
##                 queue: model.queue.enqueue_all(List.map(paths, load_request)),
##             }
##
##             # 3b. A refused request still ends -- so the slot it held is free,
##             #     and the work goes back on the queue as a *new* request.
##             Loaded(path, Err(Busy)) => {
##                 ..model,
##                 queue: model.queue.response_received().enqueue(load_request(path)),
##             }
##
##             # 3c. Every other terminal result also frees a slot.
##             Loaded(_, result) => {
##                 ..model,
##                 queue: model.queue.response_received(),
##                 loaded: match result {
##                     Ok(contents) => List.append(model.loaded, contents)
##                     Err(_) => model.loaded
##                 },
##             }
##         }
##
## Part 3b builds a *new* request from the path rather than putting back the one
## that failed, and it has to. A `Request` owns the typed response mapper that turns its
## one terminal result into a message; the platform consumed that mapper when
## it delivered `Err(Busy)`, and what the app is holding now is the message that
## mapper produced, not the request behind it. A `Request` is single-use by
## construction -- exactly-once delivery is what makes that true -- so the
## message must carry whatever rebuilding the request needs. That is why
## `Loaded` carries its path. `Busy` should be rare while `max_in_flight` stays
## well under the platform's cap, since pacing is what the queue is for, but it
## is worth handling: the cap is shared with every other request the app submits.
##
## `response_received` is the app's promise that one ready request will send no further
## messages. Call it once per message that ends one of *this queue's* requests, and
## not for messages from requests the app submitted outside the queue -- the queue
## cannot tell them apart, and an unmatched `response_received` frees a slot that is
## still occupied. Missing one is the safer mistake: the queue drains more
## slowly, but it will never oversubscribe the host.
##
## ## Knowing which requests just went out
##
## `take_ready` answers with `Request` values, and a `Request` says nothing about itself:
## it owns a response mapper, and nothing can be read back off a function. So an app
## that wants to show "these three files are being read right now" cannot get
## that from the queue directly.
##
## It does not need to. `take_ready` is FIFO -- it returns exactly the first N
## requests of the backlog in enqueue order -- so an app that keeps its own list of
## what each request was for, in the same order, stays in lockstep with the queue
## by construction. Pop `List.len(ready.requests)` entries off the front of that
## list and those are the requests now in flight:
##
##     Model : {
##         queue : RequestQueue.Queue(Msg),
##
##         # One entry per request waiting in `queue`, in the same order. This is
##         # the whole trick: the queue holds the work, this holds its name.
##         queued : List(Str),
##         reading : List(Str),
##     }
##
##     ready = model.queue.take_ready()
##     split = List.split_at(model.queued, List.len(ready.requests))
##
##     # `split.before` names exactly the requests in `ready.requests`, in order.
##     next = { ..model, queue: ready.queue, queued: split.others, reading: List.concat(model.reading, split.before) }
##
## The two lists have to be written together to stay together. Enqueue a request
## and append its tag in the same expression; re-enqueue a `Busy` retry and
## append its tag to the back as well, since the request goes to the back. A tag
## can be anything the app can identify a request by -- a path, a lane index, a
## message constructor -- and the message that ends the request has to carry it
## back, which it must do anyway to rebuild a refused request.
import App
import Files
import Time

## Deferred requests an app makes ready for submission a few at a time.
##
## The bookkeeping is wrapped for the same reason `App.Transition`'s is: the
## fields are not reachable by field access, so a queue is read and written
## through its receivers and the pacing arithmetic lives in exactly one place.
## `queued` is the FIFO backlog, `in_flight` counts requests ready but not yet
## reported through `response_received`, and `max_in_flight` is the ceiling `take_ready`
## will not exceed.
RequestQueue := [].{
	Queue(msg) := [
		QueueState(
			{
				queued : List(App.Request(msg)),
				in_flight : U64,
				max_in_flight : U64,
			},
		),
	].{

		## An empty queue that will keep at most `max_in_flight` requests with the host.
		##
		## The platform's own cap is 32 requests in flight across the whole app; stay
		## well under it, around 8 to 16, so other work the app submits still finds
		## a free slot. A `max_in_flight` of 0 is legal and takes nothing, which
		## is a way to hold work back without draining the backlog.
		new : U64 -> Queue(msg)
		new = |max_in_flight| Queue.(QueueState({ queued: [], in_flight: 0, max_in_flight: max_in_flight }))

		## Add one request to the back of the backlog.
		##
		## Nothing is submitted here. `take_ready` decides when, and how many.
		enqueue : Queue(msg), App.Request(msg) -> Queue(msg)
		enqueue = |queue, request| {
			state = unwrap(queue)
			Queue.(QueueState({ ..state, queued: List.append(state.queued, request) }))
		}

		## Add requests to the back of the backlog, keeping their order.
		enqueue_all : Queue(msg), List(App.Request(msg)) -> Queue(msg)
		enqueue_all = |queue, requests| {
			state = unwrap(queue)
			Queue.(QueueState({ ..state, queued: List.concat(state.queued, requests) }))
		}

		## Take as many requests off the front as the in-flight budget has room for.
		##
		## Answers with the requests to submit and the queue to store back in the
		## model, which has already counted them as in flight:
		##
		##     ready = model.queue.take_ready()
		##     App.next({ ..model, queue: ready.queue }).with_requests(ready.requests)
		##
		## Call it on every update. When the backlog is empty or the budget is full
		## it answers with no requests and an unchanged queue, so there is no condition
		## to test before calling it and no input on which a drained queue stalls.
		##
		## **Readiness is FIFO, and that is a guarantee.** `ready.requests` is exactly
		## the first `List.len(ready.requests)` requests of the backlog, in the order
		## they were enqueued; the requests left behind keep their order too. Nothing is
		## reordered, skipped, or coalesced, and the count is the smaller of the
		## remaining budget and the backlog length.
		##
		## That is what makes the ready requests identifiable. A `Request` is opaque --
		## it owns a response mapper, so nothing can be read back off one -- but an app that
		## keeps its own list of what each enqueued request was *for*, in the same
		## order, can pop that many entries off the front of its own list and know
		## precisely which requests just went out. See the lockstep recipe in this
		## module's documentation.
		take_ready : Queue(msg) -> { queue : Queue(msg), requests : List(App.Request(msg)) }
		take_ready = |queue| {
			state = unwrap(queue)
			room = if state.in_flight >= state.max_in_flight 0 else state.max_in_flight - state.in_flight
			split = List.split_at(state.queued, U64.min(room, List.len(state.queued)))
			{
				queue: Queue.(QueueState({ ..state, queued: split.others, in_flight: state.in_flight + List.len(split.before) })),
				requests: split.before,
			}
		}

		## Record that one ready request has produced its terminal message.
		##
		## Call this while handling each message that ends one of this queue's
		## requests, including the `Err(Busy)` a saturated host answers with. The count
		## floors at zero, so an extra call cannot wrap it into a budget that never
		## takes again.
		response_received : Queue(msg) -> Queue(msg)
		response_received = |queue| {
			state = unwrap(queue)
			Queue.(QueueState({ ..state, in_flight: if state.in_flight == 0 0 else state.in_flight - 1 }))
		}

		## How many requests are waiting to be ready.
		queued_len : Queue(msg) -> U64
		queued_len = |queue| List.len(unwrap(queue).queued)

		## How many ready requests have not yet been reported through `response_received`.
		in_flight : Queue(msg) -> U64
		in_flight = |queue| unwrap(queue).in_flight

		## The ceiling `take_ready` will not exceed.
		max_in_flight : Queue(msg) -> U64
		max_in_flight = |queue| unwrap(queue).max_in_flight
	}
}

## Open the private wrapper. Module-internal, so the bookkeeping stays reachable
## only through the receivers above.
unwrap : Queue(msg) -> { queued : List(App.Request(msg)), in_flight : U64, max_in_flight : U64 }
unwrap = |queue|
	match queue {
		QueueState(state) => state
	}

## Requests distinguishable by description, so the tests can assert on FIFO order.
##
## `App.request_description` is how a test looks at a request at all: a `Request` owns a
## response mapper, and equality cannot inspect a function.
numbered_task : U64 -> App.Request(Str)
numbered_task = |millis| Time.delay(millis, |_| "elapsed")

descriptions : List(App.Request(Str)) -> List(App.RequestDescription)
descriptions = |requests| List.map(requests, App.request_description)

## A queue holding one request per entry of `millis`, with none ready yet.
filled : U64, List(U64) -> Queue(Str)
filled = |max_in_flight, millis|
	Queue.new(max_in_flight).enqueue_all(List.map(millis, numbered_task))

expect Queue.new(8).queued_len() == 0
expect Queue.new(8).in_flight() == 0
expect Queue.new(8).max_in_flight() == 8

## Enqueueing submits nothing on its own.
expect Queue.new(2).enqueue(numbered_task(1)).queued_len() == 1
expect Queue.new(2).enqueue(numbered_task(1)).in_flight() == 0
expect filled(2, [1, 2, 3, 4, 5]).queued_len() == 5

## `enqueue_all` keeps the order it was given, and appends behind what is
## already waiting.
expect descriptions(Queue.new(9).enqueue_all([numbered_task(1), numbered_task(2)]).enqueue(numbered_task(3)).take_ready().requests)
	== [Delay({ millis: 1 }), Delay({ millis: 2 }), Delay({ millis: 3 })]

## A take_ready is capped by the budget, and takes from the front.
expect descriptions(filled(3, [1, 2, 3, 4, 5]).take_ready().requests) == [Delay({ millis: 1 }), Delay({ millis: 2 }), Delay({ millis: 3 })]
expect filled(3, [1, 2, 3, 4, 5]).take_ready().queue.queued_len() == 2
expect filled(3, [1, 2, 3, 4, 5]).take_ready().queue.in_flight() == 3

## The rest waits, in order, until a slot frees. A `Request` owns a response mapper, so
## these count what came back rather than comparing it.
expect List.is_empty(filled(3, [1, 2, 3, 4, 5]).take_ready().queue.take_ready().requests)
expect descriptions(filled(3, [1, 2, 3, 4, 5]).take_ready().queue.response_received().take_ready().requests) == [Delay({ millis: 4 })]
expect descriptions(filled(3, [1, 2, 3, 4, 5]).take_ready().queue.response_received().response_received().take_ready().requests)
	== [Delay({ millis: 4 }), Delay({ millis: 5 })]

## A backlog shorter than the budget takes all of it and no more.
expect descriptions(filled(8, [1, 2]).take_ready().requests) == [Delay({ millis: 1 }), Delay({ millis: 2 })]
expect filled(8, [1, 2]).take_ready().queue.in_flight() == 2
expect filled(8, [1, 2]).take_ready().queue.queued_len() == 0

## Releasing an empty queue is the idle case, and it is safe on every input.
expect List.is_empty(Queue.new(8).take_ready().requests)
expect Queue.new(8).take_ready().queue.in_flight() == 0
expect List.is_empty(filled(8, [1, 2]).take_ready().queue.take_ready().queue.take_ready().requests)

## A zero budget holds everything back without losing it.
expect List.is_empty(filled(0, [1, 2, 3]).take_ready().requests)
expect filled(0, [1, 2, 3]).take_ready().queue.queued_len() == 3

## Completions free slots one at a time, and floor at zero rather than wrapping
## into a budget that would never take_ready again.
expect Queue.new(4).response_received().in_flight() == 0
expect Queue.new(4).response_received().response_received().in_flight() == 0
expect filled(2, [1, 2, 3, 4]).take_ready().queue.response_received().in_flight() == 1
expect filled(2, [1, 2, 3, 4]).take_ready().queue.response_received().response_received().response_received().in_flight() == 0
expect descriptions(filled(2, [1, 2, 3, 4]).take_ready().queue.response_received().response_received().response_received().take_ready().requests)
	== [Delay({ millis: 3 }), Delay({ millis: 4 })]

## A `Busy` retry goes to the back as a freshly built request, because the failed
## one's response mapper was consumed by the delivery that reported the failure.
expect descriptions(filled(1, [1, 2]).take_ready().queue.response_received().enqueue(numbered_task(1)).take_ready().requests)
	== [Delay({ millis: 2 })]
expect descriptions(filled(1, [1, 2]).take_ready().queue.response_received().enqueue(numbered_task(1)).take_ready().queue.response_received().take_ready().requests)
	== [Delay({ millis: 1 })]

## Draining the whole backlog a budget at a time preserves FIFO order overall.
drained : List(App.RequestDescription)
drained = drain(filled(2, [1, 2, 3, 4, 5]), [])

drain : Queue(Str), List(App.RequestDescription) -> List(App.RequestDescription)
drain = |queue, seen| {
	ready = queue.take_ready()
	if List.is_empty(ready.requests) {
		seen
	} else {
		drain(
			List.fold(ready.requests, ready.queue, |acc, _request| acc.response_received()),
			List.concat(seen, descriptions(ready.requests)),
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

# --- Readiness is FIFO, and an app can rely on it ----------------------------

## Nine requests, distinguishable by description, ready three at a time.
nine : Queue(Str)
nine = filled(3, [1, 2, 3, 4, 5, 6, 7, 8, 9])

## A take_ready is a prefix of the backlog, in enqueue order -- not a subset of it
## and not a reordering of one. This is the guarantee `take_ready` states.
expect descriptions(nine.take_ready().requests) == [Delay({ millis: 1 }), Delay({ millis: 2 }), Delay({ millis: 3 })]

## And what stays behind is the rest of the backlog, still in order. A take_ready
## that reordered the remainder would leave the app's parallel list aligned with
## nothing.
expect descriptions(nine.take_ready().queue.response_received().response_received().response_received().take_ready().requests)
	== [Delay({ millis: 4 }), Delay({ millis: 5 }), Delay({ millis: 6 })]

## The count is the smaller of the remaining budget and the backlog length, so
## the prefix an app pops off its own list is `List.len(ready.requests)` and
## never the budget.
expect List.len(filled(3, [1, 2]).take_ready().requests) == 2
expect List.len(filled(3, [1, 2, 3, 4]).take_ready().requests) == 3
expect List.len(filled(3, []).take_ready().requests) == 0
expect List.len(nine.take_ready().queue.take_ready().requests) == 0

## A partial response takes exactly the freed slots, still from the front.
expect descriptions(nine.take_ready().queue.response_received().take_ready().requests) == [Delay({ millis: 4 })]

## The lockstep recipe from this module's documentation, run for real: the app
## keeps a parallel list of tags and pops `List.len(ready.requests)` from the
## front of it. `Lockstep.tags` are the requests it believes are in flight;
## `Lockstep.observed` is what the queue actually ready, by description. If the two
## ever disagreed, the tags would be naming the wrong requests.
Lockstep : {
	queue : Queue(Str),
	queued : List(U64),
	tags : List(U64),
	observed : List(App.RequestDescription),
}

## Start a lockstep with one request per entry of `millis`, tagged by that entry.
## Enqueueing the request and appending its tag happen together, which is the
## discipline the recipe asks for.
lockstep_of : U64, List(U64) -> Lockstep
lockstep_of = |max_in_flight, millis| {
	queue: filled(max_in_flight, millis),
	queued: millis,
	tags: [],
	observed: [],
}

## One cycle: take_ready whatever fits, and move that many tags across with it.
lockstep_take_ready : Lockstep -> Lockstep
lockstep_take_ready = |state| {
	ready = state.queue.take_ready()
	split = List.split_at(state.queued, List.len(ready.requests))
	{
		queue: ready.queue,
		queued: split.others,
		tags: List.concat(state.tags, split.before),
		observed: List.concat(state.observed, descriptions(ready.requests)),
	}
}

## Report a response for every ready request, freeing its slot.
lockstep_settle : Lockstep -> Lockstep
lockstep_settle = |state| {
	..state,
	queue: List.fold(state.tags, state.queue, |queue, _tag| queue.response_received()),
}

## Drain a lockstep to the end, releasing and settling one cycle at a time.
lockstep_drain : Lockstep -> Lockstep
lockstep_drain = |state| {
	next = lockstep_take_ready(state)
	if List.len(next.tags) == List.len(state.tags) {
		next
	} else {
		lockstep_drain(lockstep_settle(next))
	}
}

## The tags a cycle pops name exactly the requests it ready, in order.
expect lockstep_take_ready(lockstep_of(3, [1, 2, 3, 4, 5, 6, 7, 8, 9])).tags == [1, 2, 3]
expect lockstep_take_ready(lockstep_of(3, [1, 2, 3, 4, 5, 6, 7, 8, 9])).observed
	== [Delay({ millis: 1 }), Delay({ millis: 2 }), Delay({ millis: 3 })]

## What is left of the app's list still lines up with what is left of the queue.
expect lockstep_take_ready(lockstep_of(3, [1, 2, 3, 4, 5, 6, 7, 8, 9])).queued == [4, 5, 6, 7, 8, 9]

## Across a whole drain, in several budget-sized rounds, the tags the app
## believes are in flight are exactly the requests the queue ready -- every
## time, in the same order. That is the guarantee, checked rather than asserted.
expect {
	drained_state = lockstep_drain(lockstep_of(3, [1, 2, 3, 4, 5, 6, 7, 8, 9]))
	List.map(drained_state.tags, |tag| Delay({ millis: tag })) == drained_state.observed
		and drained_state.tags == [1, 2, 3, 4, 5, 6, 7, 8, 9]
			and List.is_empty(drained_state.queued)
}

## A budget of one makes every round a single request, and the alignment holds
## there too -- the case where an off-by-one would be loudest.
expect {
	single = lockstep_drain(lockstep_of(1, [7, 8, 9]))
	List.map(single.tags, |tag| Delay({ millis: tag })) == single.observed and single.tags == [7, 8, 9]
}

## A backlog shorter than the budget is ready whole, and nothing is left over
## for the app's list to be out of input with.
expect {
	short = lockstep_take_ready(lockstep_of(8, [4, 5]))
	short.tags == [4, 5] and List.is_empty(short.queued)
}

## Releasing an empty queue moves no tags, so a cycle with nothing to send
## cannot advance the app's list past the queue's.
expect List.is_empty(lockstep_take_ready(lockstep_of(8, [])).tags)
expect lockstep_take_ready(lockstep_take_ready(lockstep_of(3, [1, 2, 3, 4]))).tags == [1, 2, 3]
