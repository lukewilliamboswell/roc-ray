# Spike: coroutine-backed tasks on zio

Branch `spike-coro`, 2026-08-22. Migration step 1 of
`COROUTINE_DESIGN_PROPOSAL.md` ("prove the loop"), Linux x64 only.

## What was built

Additive only; `Command`, `Request`, and `Transition` are untouched apart
from one new field.

* **Dependency**: `zio` v0.17.0 (`build.zig.zon`), wired into the host
  library for all four targets and into the native unit tests, with
  `task-migration=false` so the scheduler cannot move a task off the thread
  that spawned it. The host library cross-compiles for x64mac, arm64mac,
  and x64win with zio in it; only x64glibc was run.
* **Roc surface**: `platform/Task.roc` (`Task.sleep! : U64 => {}`), the
  private `platform/TaskHost.roc`, and `Transition.with_task : (() => msg)`
  / `with_tasks`. `Transition` gained a `tasks : List(() => msg)` field;
  `map_msg` maps tasks by wrapping the closure.
* **Adapters** (`main.roc` and `main-wayland.roc`): `update_for_host!`
  returns `tasks : List(AppHost.SubmittedTask(Msg))` -- each closure boxed
  as `Box(() => msg)`, which crosses the ABI as the same erased callable the
  request callbacks already use. One new provided entry point,
  `run_task_for_host! : Box(() => Msg) => Box(AppHost.RawResponse -> Box(Msg))`,
  runs the closure and hands its message back wrapped as a response mapper,
  so the host stages it as an ordinary `PendingResponse` and the existing
  `receive_responses` delivers it on `Input.messages`. No new delivery code
  on the Roc side (see "Things that bit" for why it is shaped this way).
* **Host** (`src/tasks.zig`, `src/host_native.zig`): one `zio.Runtime` with
  `executors = .exact(1)` on the frame thread, created after the window and
  torn down before it. Each submitted task is `rt.spawn`ed; the body enters
  the `task` phase, calls `run_task_for_host`, and appends the boxed result
  to a completion list in completion order. The frame loop pumps once
  before sampling input and once after spawning, stages the completion list
  into the response staging area (`RESPONSE_TASK_RESULT`), and at shutdown
  cancels every live task, runs each to its end, decrefs undelivered
  results, and deinits the runtime. `roc_task_sleep` is `zio.sleep` behind the phase guard.
* **Phase guard**: a new `task` phase; `Task.sleep!` is legal in `init!`
  (blocks, pumping the loop) and on a task (parks). The phase is saved and
  cleared across a park and restored on resume, because the frame loop sets
  phases of its own in between.
* **Example**: `examples/task_sleep` -- one task on cycle 0 that sleeps
  300 ms and answers `Woke`; the circle keeps orbiting meanwhile.
* `ROC_RAY_TRACE_TASKS=1` logs spawn/start/park/resume/finish/deliver with
  the cycle number, plus pump statistics at shutdown.

What was *not* delivered: `Task.spawn!` as a hosted effect. `update` is still
pure in this spike, so spawning is data on the `Transition`
(`with_task`), which is the shape the proposal's step 2 replaces. The type
erasure problem (section 5.4 of the proposal) is solved the same way either
way: the closure is boxed on the Roc side, carried opaquely, and only
`run_task_for_host!` names `Msg`.

## What was verified

Windowed (`examples/task_sleep/task_sleep`, vsync 60 Hz, trace on):

    [TASK 1] spawned on cycle 0
    [TASK 1] started on cycle 0
    [TASK] sleep parking 300 ms on cycle 0
    [TASK] sleep resumed on cycle 19
    [TASK 1] finished on cycle 19

Headless (`--host-headless --host-headless-frames=120`):

    [TASK 1] spawned on cycle 0
    [TASK 1] started on cycle 0
    [TASK] sleep parking 300 ms on cycle 0
    [TASK] sleep resumed on cycle 18
    [TASK 1] finished on cycle 18
    [TASK] delivering 1 result(s) as messages on cycle 18
    [TASK] 240 pumps, mean 1255408 ns; 204 idle pumps, mean 388 ns

The frame loop advanced 18 cycles while the task was parked, and the
message arrived 300 ms / 18 cycles later. (18 vs 19: the windowed run's
first frame is longer than 16.7 ms.)

Also verified: `zig build` (four targets), `zig build lint`, `roc check`
on the platform and the example, `roc test` on the example (492 expects),
the native unit tests (168/168), and `scripts/all_tests.py --only
task_sleep,async_read,hello_world,pong` -- see the end of this document for
that run's result.

## The pump question: `zio.yield()` is enough

The proposal flagged that `zio.yield()` has a fast path that returns
without polling the event loop when nothing is ready and the tick budget is
unspent, so a once-per-frame yield might never observe a timer. Measured:

* Windowed: a bare `zio.yield()` per frame woke the 300 ms sleep on cycle
  19. A frame is ~16 ms, far past zio's 100 µs tick target, so every yield
  takes the slow path and polls.
* Headless with no pacing and `ROC_RAY_SPIKE_YIELD_ONLY=1` (bare yield,
  frames taking ~7 µs each): the sleep woke on cycle 43289, i.e. after
  ~300 ms of spinning. The fast path only skips the poll *within* a 100 µs
  tick, so timers are observed at worst ~100 µs late. That is a frame-loop
  pump with no special API.

So the frame loop pumps with `zio.yield()`. The headless loop additionally
paces itself with `zio.sleep(16.67 ms)` while a task is live, because task
timers are wall-clock and a headless run otherwise finishes 120 cycles in
a millisecond. That is the one place headless determinism and real-time
timers pull against each other; the trade is documented in the code.

Pump cost with no task live: **~0.3-0.4 µs per call** (204 idle pumps,
mean 388 ns), two calls per frame. With a task parked it is the same order.

## Link stubs

`roc build` on x64glibc links against generated glibc stubs
(`platform/targets/x64glibc/libc_stub.s`). zio added exactly one missing
symbol: `raise` (from its blocking-task cancellation path). Added to the
x64 and arm64 stub files. Everything else zio needs on Linux --
`mmap`/`mprotect`/`munmap`, `sigaction`/`sigaltstack`-adjacent calls,
`eventfd`, `timerfd_*`, `io_uring_*` via raw syscalls, `pthread_*` -- was
already present or is a direct syscall. Cost: one stub.

## Stack growth and overflow

A probe task recursing 40 million levels non-tail (`1 + deep(n - 1)`):

    Coroutine stack overflow!
      Fault address:    0x7ebb0d800ff8
      Stack base:       0x7ebb0d6c0000
      Stack size:       8196 KB
      Committed:        6911 KB
      Guard page fault: false

zio's SIGSEGV handler grew the stack on demand from 256 KB to the 8 MB
cap, then reported the overflow by name and aborted. It coexists with the
host: no interference with raylib, Roc, or the host's own signal use was
observed. Not yet done: naming the task (a label) in that report.

## Phase guard

A probe calling `Task.sleep!(1)` inside `render!`:

    panic: roc-ray: Task.sleep! is only valid during init! or a task,
    but it was called during render!.

Exactly the message and behaviour the proposal's section 7 asks for.

## Shutdown

Headless run that ends while a task is still parked (`ROC_RAY_SPIKE_YIELD_ONLY=1`,
120 cycles in ~3 ms):

    [TASK] sleep parking 300 ms on cycle 0
    [TASK 1] cancelling at shutdown
    [TASK] sleep resumed on cycle 119
    [TASK 1] finished on cycle 119
    roc-ray: 1 task(s) abandoned at shutdown

`JoinHandle.cancel()` made the sleep return `error.Canceled`; the hosted
effect returned normally, the Roc closure ran to its end, its undelivered
result was decref'd as an erased callable, and `Runtime.deinit`'s "no live
tasks" assertion held. No leak reported by the tracking allocator.

## Things that bit

* **Unboxing a `Box(Msg)` from a list crashes the compiler when `Msg : []`.**
  The first delivery design handed the host a `List(Box(msg))` of finished
  results and unboxed them in the adapter. Every app whose message type is
  the empty union (`hello_world`, `pong`, the CLI and allocation probes)
  then failed `roc build` with "postcheck invariant violated: known
  constructor match had no matching branch" in SpecConstr, while apps with
  a real `Msg` built fine. Bisected to the unbox itself: `for`/`List.map`/a
  helper in another module all fail; `Box.unbox(deliver(raw))` in the
  existing `AppTransport.receive_response` does not. Workaround: return the
  message from `run_task_for_host!` already wrapped as
  `Box(RawResponse -> Box(Msg))` and deliver it through the response path.
  Worth an upstream issue with `test/` reproduction. **Checked against the
  pinned release nightly** (`~/roc_nightly-linux_x86_64-2026-08-21-90da19f`):
  the release binary builds the direct form; only the locally built debug
  `roc` aborts. The invariant is a debug-only postcheck assertion, so the
  workaround is kept with a `TODO(compiler)` and the direct form can return
  once upstream confirms the assertion is over-strict (rather than masking a
  miscompile).
* **Record update spreads crash the compiler** (same story: debug-only
  postcheck invariant; release nightly builds them; `TODO(compiler)` left
  on the receivers). `Transition.(Transition({
  ..fields, commands: ... }))` in `App.roc` type-checks but `roc build`
  panics in `SpecConstr` ("record update base type differed from its result
  type"). Writing the record out field by field avoids it. Worth an
  upstream issue.
* **`scripts/roc_platform_abi.py` cannot run on this machine**: the local
  `roc` is a debug build whose exit-time leak check aborts `roc glue`
  (pre-existing; the unmodified platform fails the same way). The generated
  file is complete before the abort, so the ABI was regenerated by running
  `roc glue` by hand and copying the output. `--check` therefore could not
  be run either.
* **`scripts/bundle.sh` bundles only `git ls-files platform/*.roc`**, so
  new platform modules must be tracked before `all_tests.py` can see them.
  Until they were, every example failed to check with "Task.roc:
  FileNotFound" from the served bundle.
* `zig fetch --save` on 0.16 vendors the package into `zig-pkg/`; see the
  note at the end for what was done with it.
* The memory note's `--headless` flags are stale: the host takes
  `--host-headless` and `--host-headless-frames=N`.

## zio API friction

* Nothing blocked. `Runtime.init` / `spawn` / `yield` / `sleep` /
  `JoinHandle.cancel` / `deinit` did what their doc comments say.
* `JoinHandle.cancel()` joins synchronously, which from the main task means
  "run the loop until this task finishes" -- convenient for drain, but a
  task that never parks would hang shutdown. A deadline needs
  `withTimeout` or a manual pump loop; not done in the spike.
* `std.posix.getenv` is gone in 0.16 (the host's own `hostGetEnv` was used).
* Spawning needs an allocator per runtime; the host's Roc allocator was
  used, so task bookkeeping shows up under the alloc meter. Probably fine.

## Recommended next step

Step 2 of the proposal: make `update!` effectful, expose `Task.spawn!` as a
hosted effect (the host already holds closures opaquely and the phase
guard already has a `task` phase), and move the synchronous commands to
direct calls. After that, retire the effect worker by turning `Files.*`
into `rt.io()` calls that park (step 3/4). The coroutine side needs no
further proving; what remains is API work.

## Regression results (final tree)

* `scripts/all_tests.py --only task_sleep,async_read,hello_world,pong`:
  **All tests passed** -- fmt, check, test, build, headless run (3 frames),
  CLI argument probe, model allocation probe, package interop, and the
  Wayland bundle build of `task_sleep`.
* `zig build test -Droc-tests=false`: **168/168** native tests passed;
  tidy and lints pass after removing one dead alias.
* `zig build`: all four host targets compile with zio in them.
* `zig-pkg/`: Zig 0.16's `zig fetch --save` vendors the dependency there,
  and a plain `zig build` refetches it when the directory is absent
  (verified by moving it aside), so it is gitignored rather than committed.
