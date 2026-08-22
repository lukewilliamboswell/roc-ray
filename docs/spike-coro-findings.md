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

Step 3/4 of the proposal: retire the effect worker by turning `Files.*`,
the clipboard read, and screenshots into `rt.io()` calls that park on a
task, then delete `App.Request` (step 6) and add `Http`/`Path` (step 7).
The coroutine side needs no further proving; what remains is API work.

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

## Step 2: effectful `update!`, `Task.spawn!`, no command layer

Same branch, 2026-08-22, on top of the spike. Reference compiler is still the
pinned release nightly.

## What changed

* `program = { init!, update!, render! }` with
  `update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])`.
  `update_for_host!` now returns only the boxed model; the host reads
  `payload_ok()` as a `RocBox` and nothing else.
* `Task.spawn! : (() => msg) => {}` is a hosted effect. `TaskHost.spawn! :
  Box(() => msg) => {}` is polymorphic in `msg`; the pinned compiler accepts
  a type variable in a hosted signature and `roc glue` lowers the boxed
  closure to `RocErasedCallable`, the same type the spike's
  `SubmittedTask.run` had. `Transition.with_task` and `spawnAll` are gone;
  `Tasks.spawnCurrent` takes one closure from the hosted call.
* `App.request! : Request(msg) => {}` is a hosted effect
  (`AppHost.submit_request! : SubmittedRequest(msg) => {}`). The request
  record is owned by the call: its callback moves into the pending table or
  a terminal `Busy` envelope, its path string is released by the host. The
  per-input budgets that used to be locals of one list dispatch
  (`synchronous_tasks`, `roc_string_bytes`, `headless_reads`) are host state
  reset at the top of each cycle, and the staging area is published to the
  hosted call through `active_request_staging` for the life of the loop.
  The old `submitRequests(list)` is kept for the host unit tests and now
  loops over the single-request path.
* `Request(msg)` moved into `AppHost` (`App.Request` is an alias) to break
  the `App -> AppTransport -> App` import cycle that `App.request!` would
  otherwise create. `App.map_request` replaces `Transition.map_msg` for
  components that own requests.
* Deleted: `App.Command` (29 variants), `App.Transition` and its receivers,
  `App.next`/`from_parts`/`map`/`map2`, `command_description`,
  `CommandApply.roc`, `AppTransport.validate_commands`, the command-coverage
  lint in `ci/tidy.zig`, `docs/command-coverage.md`, and every pure command
  constructor (`Window.set_clipboard_text`, `Audio.Sound.play`, ...).
* Added direct effects: `Window.set_clipboard_text!`, `suggest_size!`,
  `suggest_min_size!`, `set_target_fps!`; `Mouse.set_cursor!`,
  `set_cursor_mode!`, `set_source!`; `Keys.set_exit_key!`; `Capture.start!`,
  `Capture.stop!` (the compile_fail fixture that checked `Capture.stop!`
  did *not* exist is replaced by `transition_removed.roc`, which checks
  `App.next` does not).
* Phase guard: `apply` → `update`. `during_update = {startup, update,
  task}` for host-state changes; `during_load` is the same set, so loaders
  (textures, fonts, shaders, sounds, tilemaps, render textures) are now
  legal from `update!` and tasks; `during_spawn = {update, task}` for
  `Task.spawn!` and `App.request!`; `during_startup` shrank to the
  `App.Startup` capabilities. Rejection hints were rewritten per set.

## What was verified (release nightly on PATH)

* `scripts/all_tests.py` (all 20 examples): **All tests passed** -- fmt,
  check, test, build, headless runs, CLI args probe, model allocation probe
  (88 bytes/frame, in place), package interop, Wayland bundle build.
  `cave_climb`'s build is skipped by the script itself as "unusually slow",
  which predates this work.
* `zig build test -Droc-tests=false`: 168/168, privacy fixtures all
  verified, lint and tidy clean. `zig build` for all four targets.
  `scripts/roc_platform_abi.py --check`: verified.
* `examples/task_sleep` via `Task.spawn!` from inside `update!`,
  `ROC_RAY_TRACE_TASKS=1 ./main --host-headless --host-headless-frames=120`:

      [TASK 1] spawned on cycle 0
      [TASK 1] started on cycle 0
      [TASK] sleep parking 300 ms on cycle 0
      [TASK] sleep resumed on cycle 18
      [TASK 1] finished on cycle 18
      [TASK] delivering 1 result(s) as messages on cycle 18
      [TASK] 240 pumps, mean 1252342 ns; 204 idle pumps, mean 311 ns

* Sync effects from `update!`: a scratch app calling
  `Window.set_target_fps!(30)`, `Window.set_clipboard_text!(...)`, and
  `Keys.set_exit_key!(NoExitKey)` on cycle 0 and exiting on cycle 2 ran
  headless with exit 0. `input_inspector` and `responsive_ui` do the same
  in the suite.
* Phase guard from `render!`: the same app with `Window.set_target_fps!(30)`
  in `render!` stops with

      roc-ray: Window.set_target_fps! is only valid during init! or update!
      or a task, but it was called during render!. It changes host state
      rather than drawing: call it from init!, update!, or a task, not from
      render!.

## Things that bit

* `?` inside `update!` with a different error union than the body's
  `Err(Exit(0))` is refused ("error types from all `?` operators and the
  function body must be compatible"), even with an open `..` on the
  annotation. `generated_assets` maps its upload errors to a `crash`
  instead, which is what the platform did for a malformed upload before.
* The locally built *debug* `roc` on `PATH` is the same commit as the
  pinned release and passes the scripts' version check, but it trips the
  SpecConstr record-update invariant on `live_plot`, `snake`, and
  `top_down` after the port (record spreads inside the now-effectful
  `update!`). The release binary builds all three. Put the release nightly
  first on `PATH` when running `scripts/all_tests.py`.
* Else-less `if` statements in effectful code (`if cond { effect!() }`)
  are accepted, which keeps `update!` bodies short.
* Components lose `map_msg`: a child's `Task.spawn!` closure must return
  the parent's `Msg`. `App.map_request` covers requests; the
  `Task.spawn_with!` helper the proposal suggests is not written.

## Step 4: waiting effects, and the delivery defect that stops step 6

Same branch, 2026-08-22, on top of step 2. Reference compiler is the pinned
release nightly.

### What landed

`Files.read_text!`, `Files.read_bytes!`, `Files.list!`,
`Window.read_clipboard!`, and `Capture.screenshot!` exist as ordinary
effects. The three file effects and the screenshot are `wait` effects
(`during_wait` = init | task): their Zig implementation goes through
`rt.io()`, so on a task the coroutine parks on the event loop and the frame
loop keeps running, and in `init!` the same call parks the frame loop's own
task and pumps until the answer is in. `Window.read_clipboard!` is a plain
state read -- raylib only answers on the window's thread and the read is a
pointer copy -- so it is `during_update` and never parks.

Measured, from a scratch app:

* `Files.read_text!("README.md")` in `init!` produced 10860 bytes, matching
  `wc -c`. `Files.read_bytes!("src/roc_platform_abi.zig")` produced 430055
  bytes with no payload copy: the buffer the read filled moves into a
  seamless `List(U8)`. A missing path produced `NotFound`.
  `Files.list!("examples")` produced 23 entries.
* `Files.read_text!` from `update!`:

      roc-ray: Files.read_text! is only valid during init! or a task, but
      it was called during update!. It waits: call it inside Task.spawn!,
      where it parks the task, or in init!, where it blocks.

* `Capture.screenshot!("probe.png")` inside `Task.spawn!`, windowed: the
  task parked, the frame loop kept going, `Ok({})` came back, and
  `probe.png` is a 3459-byte 800x600 8-bit RGBA PNG. The readback still
  happens at end-of-frame inside the drawing scope; the encode and the write
  run on `rt.spawnBlocking`, which parks the task again rather than spending
  the encode on the frame thread.

Preserved: the 16 MiB per-file ceiling, the 64 KiB ceiling on a read
delivered as a `Str`, UTF-8 validation before a `Str` is built, the
live-byte-list reservation, and the zero-copy `List(U8)`. Dropped: the
per-input headless read budgets, which bounded one dispatch over a request
list and have no meaning for a read that spans cycles.

### What did not land, and why

**No example is ported to `Task.spawn!`, and step 6 is not started.** A
task's message does not survive delivery: it reaches `update!` with the
wrong tag and a misread payload. So does a `Request`'s. This is not a step-4
regression -- it is already true at the tip of step 2 -- and it makes the
point of steps 4 and 6 unreachable until it is fixed.

Bisected with `examples/async_read`, which reads a small file as a `Str` and
a large one as bytes and shows both:

| Tree | `read_text` result | `read_bytes` result |
|---|---|---|
| `main` (0551b28), requests returned as data from a pure `update` | `"10583 bytes copied into a Str"` | `"419691 ordinary bytes held by Roc ARC"` |
| `spike-coro` (ca6c32a), `App.request!` as a hosted effect | `"reading..."` -- never delivered | `"429308 ordinary bytes held by Roc ARC"` |

Both messages arrive on `spike-coro` -- `List.len(input.messages) == 2` --
but both take the `BytesReadFinished` branch. Submitting only the text read
still produces a `BytesReadFinished`, carrying a `List(U8)` of 21720 bytes
for a 10860-byte file: the tag is not written, and the payload is read
through the wrong variant's layout.

`Task.spawn!` fails the same way, and worse. With `Msg : [Other(U64)]` and
`Task.spawn!(|| Other(77))`, the box the host receives has refcount 1 and a
payload that was never written -- the same uninitialised bytes on every run.
The spike missed this because `examples/task_sleep` has `Msg : [Woke]`,
which is zero-sized: there is nothing in it to corrupt.
`scripts/all_tests.py` missed it because a headless run only asserts the
exit code, so an example whose messages never arrive still passes.

The common factor is step 2's move of submission into **hosted signatures
that carry a type variable** -- `AppHost.submit_request! : SubmittedRequest(msg) => {}`
and `TaskHost.spawn! : Box(() => msg) => {}`. On `main` the erased response
mapper was built and consumed inside `update_for_host!`, where `Msg` is
concrete, and it worked. Disassembling `run_task_for_host` shows the erased
call going through the dynamic path -- `roc_boxy_init_embedded`,
`roc_boxy_register_proc`, `roc_boxy_call_erased` -- rather than a
monomorphised call, and emitting two `decref`s of the same argument box.

Shapes tried that do **not** fix it, so nobody repeats them:

* `run_task_for_host! : Box(() => Msg) => Box(Msg)` -- the "direct shape"
  the step-1 `TODO(compiler)` note suggested. The release compiler builds
  it; the message is still wrong.
* Returning `Box(msg)` from the erased closure rather than `msg` by value.
* Giving the erased closure an argument (`(U64) => ...`), and making it pure
  (`(U64) -> ...`).
* Boxing the closure at the app's own call site instead of inside
  `Task.spawn!`.
* Delivering the message through a second hosted effect
  (`TaskHost.deliver! : Box(msg) => {}`) so that nothing is returned across
  the `provides` boundary.
* Calling `callable_fn_ptr` from Zig directly, with the documented
  erased-callable ABI, instead of going through `run_task_for_host!`.
* Let-binding `AppTransport.normalize`'s result before the hosted call.

One separate glue bug found on the way: `roc glue` renders `List(Box(msg))`
as `RocListWith(RocBox, false)` -- a one-word list header -- while Roc's own
code releases it as a list of refcounted elements, with a two-word header.
The host then frees eight bytes off the allocation base, which faults inside
the allocator. Building the list as `RocList(RocBox)` and handing back the
`false`-typed struct avoids it, but the generated type is wrong either way.

### Recommended next step

Fix delivery before anything else in the migration. Until it is fixed,
`App.request!` is quietly broken on `spike-coro` for every app whose `Msg`
has more than one shape, and `Task.spawn!` cannot carry a message at all.
Two directions:

1. Reduce it to a `test/` case in the roc repo -- a hosted signature with a
   type variable, an erased callable built on one side of it and called on
   the other -- and fix it upstream. That is the direction that keeps the
   design in section 3.
2. If it cannot be fixed soon, keep `msg` out of hosted signatures entirely:
   make `update_for_host!`, where `Msg` is concrete, the only place an
   erased callable is built or called, which is what `main` does today. That
   costs `App.request!` and `Task.spawn!` their effect form and pushes the
   design back toward returning deferred work as data.

Step 4's effects are independent of this and are already useful from
`init!`: an app can read its config, its atlas, and its level manifest at
startup with no first-frame state machine.
