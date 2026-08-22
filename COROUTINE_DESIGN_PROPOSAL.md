# Effectful update and coroutine-backed tasks for roc-ray

Status: proposal, 2026-08-22. **Steps 1, 2, 4, 6, and the HTTP client half
of step 7 are implemented on branch `spike-coro`** -- see "Spike status"
below and `docs/spike-coro-findings.md` for the measurements. `App.Request`,
`RequestQueue`, and the effect worker are deleted; deferred work is a task.
Steps 3 and 5 are what is left: `Task.spawn!` is done, so step 3 is only its
remaining `Task.spawn_with!` convenience, and step 5 is CI on the other three
targets.

**The delivery defect is fixed, and it was not a compiler bug.** An earlier
version of this document blamed native codegen for a task's message arriving
with the wrong tag. The cause was a hole in the API: `Task.spawn!` and
`App.request!` both generalized `msg`, so the closure at the call site
compiled at its own inferred type while `run_task_for_host!` decoded the
result as the app's real `Msg`. `Task.spawn!` now takes an `App.Input(msg)`
witness that pins the two together. See "Root cause: the `msg` type hole" in
`docs/spike-coro-findings.md`; the sections there that call it a compiler bug
carry a retraction.

## Spike status (2026-08-22, branch `spike-coro`)

Built, additively, without touching `Command`/`Request`: zio v0.17.0 as
the host runtime (one executor, frame thread, migration compiled out);
`Task.sleep!`; `Transition.with_task(|| ...)`; `run_task_for_host!`; a
`task` phase in the guard; `examples/task_sleep`. Reference compiler is
the pinned release nightly (`~/roc_nightly-linux_x86_64-2026-08-21-90da19f`).

What the spike settled:

| Question | Answer |
|---|---|
| Can a Roc call park mid-effect on a coroutine and resume frames later? | Yes. `Task.sleep!(300)` on cycle 0 resumed on cycle 18 headless / 19 windowed, message delivered the same cycle. The critical assumption in section 9 holds. |
| Is `zio.yield()` a sufficient per-frame pump? | Yes. Its fast path only skips the poll inside a 100 µs tick; a yield-only loop spinning at 7 µs/frame still observed the timer within ~300 ms. No special pump API needed. |
| Pump cost when idle | ~0.3-0.45 µs per call, two per frame. |
| Link-stub cost on the `roc build` path | One symbol: `raise`. |
| Stack growth / overflow | zio grows 256 KB → 8 MB on demand; a 40M-deep recursion dies with a named "Coroutine stack overflow!" report. No interference with raylib or the host. |
| Phase guard | `Task.sleep!` in `render!` → clean panic naming effect, phase, and fix. |
| Shutdown with a parked task | `cancel()` → the sleep returns `Canceled` → the closure runs to its end → result dropped → `Runtime.deinit` asserts clean. Tracking allocator reports no leak. |
| Type erasure for `Task.spawn!` | Works as section 5.4 describes: the closure is boxed on the Roc side, held opaquely, only `run_task_for_host!` names `Msg`. Section 5.4 was incomplete on one point: the *public* signature has to pin `msg` with an `App.Input(msg)` witness, or the call site compiles the closure at its own inferred type. |
| Cross-compilation with zio in the host | All four targets build; only x64glibc was run. |
| Headless runs | Task timers are wall-clock, so the headless loop paces to real-time 60 Hz while a task is live. Documented trade. |

Compiler notes (pinned release nightly builds everything; only a local
*debug* build of the same commit trips two postcheck invariants -- unboxing
a `Box(Msg)` taken from a list when `Msg : []`, and `{ ..record, f: x }`
spreads). The spike keeps shapes that satisfy both, with `TODO(compiler)`
markers; they can be simplified whenever convenient since the release
compiler is the reference.

### Step 2 status (2026-08-22)

`update!` is effectful and the command layer is gone:

* `update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])`; exit is
  `Err(Exit(code))`, matching `render!`. `update_for_host!` returns only the
  boxed model.
* `Task.spawn! : (() => msg) => {}` is a hosted effect (`roc_task_spawn`).
  The closure is boxed in `Task.roc`; the hosted signature is polymorphic in
  `msg`, which the pinned compiler accepts and `roc glue` erases to the same
  `RocErasedCallable` the spike used. `Transition.with_task` is gone.
  *(Superseded: the public signature is now
  `App.Input(msg), (() => msg) => {}` -- see the banner at the top.)*
* `App.request! : Request(msg) => {}` is a hosted effect
  (`roc_app_submit_request`) so requests survive without `Transition`. The
  `Request(msg)` union moved to `AppHost` so `AppTransport` can name it
  without importing `App`; `App.Request` is an alias. `App.map_request`
  replaces `Transition.map_msg` for components that own requests.
  *(Superseded: step 6 deleted all of it.)*
* Deleted: `App.Command`, `App.Transition` and every receiver, `App.next`,
  `from_parts`, `map`, `map2`, `command_description`, `CommandApply.roc`,
  the command-coverage lint and `docs/command-coverage.md`, the
  prevalidation in `AppTransport`.
* Direct effects added where the commands used to point: `Window.set_clipboard_text!`,
  `Window.suggest_size!`, `Window.suggest_min_size!`, `Window.set_target_fps!`,
  `Mouse.set_cursor!`, `Mouse.set_cursor_mode!`, `Mouse.set_source!`,
  `Keys.set_exit_key!`, `Capture.start!`, `Capture.stop!`. Audio and Assets
  already had their `!` forms; their pure command constructors are gone.
* Phase guard: `apply` is renamed `update`; `during_update = {startup,
  update, task}` for state changes, `during_load` (same set) for loaders --
  textures, fonts, shaders, sounds, tilemaps can now be loaded from
  `update!` or a task, not only `init!`; `during_spawn = {update, task}` for
  `Task.spawn!` and `App.request!`; `during_startup` is now only the
  `App.Startup` capabilities. Every rejection message names the fix.
* Every example, `test/cli_args`, `test/model_inplace`,
  `test/package_interop`, `test/asset_store_compile`, and the `compile_fail`
  fixtures are ported. Pure cores stayed pure: the games return the sounds
  they want as `List(Audio.Playback)` (or a small `Cue` union) and `update!`
  plays them, so their `expect`s are unchanged.
* The per-input request budgets (synchronous clipboard reads, headless read
  counts) became host state reset each cycle, since requests now arrive one
  at a time while `update!` runs instead of as one list afterwards.

Section 4.4's `map_msg` regression is real: a child component's tasks must
produce the parent's `Msg`. `App.map_request` covered the request half and is
gone with it, so a component that starts deferred work now takes a
`to_parent : ChildMsg -> msg` as 4.4 describes. The `Task.spawn_with!` helper
suggested there is not written yet.

### Step 7 status: the HTTP client (2026-08-22)

`Http` is implemented and issue #151 is answered. `Http.send!` is a hosted
effect over `std.http.Client` given `rt.io()`, so it parks the calling
coroutine and the frame loop keeps drawing. From Roc it is a plain
synchronous call, exactly like basic-cli's -- which is the point: the task
model, not a callback API, is what pays the 200 ms.

The API mirrors basic-cli over the shared `roc-lang/http` `Request` and
`Response` types (`send!`, `send_json!`, `get_utf8!`, `get!`,
`decode_json_response`, `with_json_body`, `TransportErr`) and adds `Config`
and `send_with!` from basic-webserver's hardened shape, because a dashboard
polling a remote endpoint needs a deadline and a response cap. `Url` is
vendored from basic-cli; the shared package has no URL type.

Measured on this branch, headless at 60 Hz:

| Question | Answer |
|---|---|
| Does a fetch keep the frame moving? | Yes. A localhost GET spawned on cycle 0 finished on cycle 1; `https://www.roc-lang.org/` (25 kB) finished on cycle 9, ~150 ms, with the ring in `examples/http_fetch` turning throughout. |
| Does the phase guard reach it? | Yes. `Http.send!` from `update!` aborts with "It waits: call it inside `Task.spawn!` ... or in `init!`, where it blocks." From `init!` it blocks and succeeds. |
| Does TLS work? | On Linux, yes, against a real `https://` host with the system store. macOS and Windows are unverified -- `Bundle.rescan` has paths for both, but no CI makes an HTTPS request there yet. |
| Are the limits real? | Yes, and exact. A 56-byte body passes at `max_response_bytes: 56` and fails at 55; a 3 s route under a 300 ms deadline fails as `Timeout` on cycle 18. |
| New link stubs for `roc build`? | None. `socket`, `connect`, `send`, `recv` and `getaddrinfo` are already in both glibc stubs from the `link_libc` work, and a stub-linked binary completed a real TLS fetch. |

Two things it cost, both recorded in `docs/http.md`:

* `zio.withTimeout` does not work for this. It converts a cancellation into
  `error.Timeout` only when the wrapped call can return `error.Canceled`, and
  `std.http`'s error sets have no such error -- a cancelled read surfaces as
  `error.ReadFailed`, and a timed-out fetch was reported as `NetworkError`.
  Arming `zio.AutoCancel` by hand, and asking the timer rather than the error
  value, fixes it. Any future waiting effect built on `std` will hit this.
* A Debug host archive grew 50.8 MB -> 88.1 MB, because `std.crypto`'s TLS
  comes with it, four targets over. That pushed a locally bundled platform
  past roc's default 100 MB transitive-dependency budget and broke *every*
  app's build until the harness raised it. A `ReleaseFast` host, which is
  what a release ships, is 9.9 MB.

Still open from step 7: `Files.write_*!` and `Path`.


This document proposes replacing the pure `update` / `Transition` /
`Command` / `Request` design with an effectful `update!` plus stackful
coroutines for deferred work. Synchronous effects become ordinary function
calls. Deferred work is an ordinary effectful closure, `Task.spawn!`, run on
its own coroutine stack on the frame thread and reported back as a message.
Where effects are *allowed* is enforced by a runtime phase guard in the host
rather than by the type system. The one-Roc-thread guarantee the host relies
on today is kept.

It is motivated by Romain Lepert's review of the Transition API, stated
fairly first.

## 1. The critique

Paraphrasing Romain: the app author wants to *do* things. Every effect is
forced through an enum -- `Command` for synchronous effects, `Request` for IO
-- so that `update` can stay pure. For a click handler that means three
different shapes for three things the user thinks of as the same act:

```roc
# message          OnClick(|_| Increment)
# command          OnClick(|_| SetClipboardText(text))
# request          OnClick(|_| Fetch({ ... }, |response| ...callback...))
```

versus what he would rather write:

```roc
create_user! : Form => Msg
create_user! = |form| {
    response = Http.fetch!({ method: "POST", body: form })
    if response.status >= 400 UserCreationFailed else UserCreated(response.body)
}
```

His questions: where are the ordinary `Http`/`Path`-style modules? What do
descriptions buy that justifies the ceremony? He accepts there may be
platform-side benefits (introspection, testability) but does not see them
outweighing the cost to the app author.

Our assessment, which this proposal acts on:

* He is right about `Command`. Twenty-nine variants describing "call this
  host function" is a second copy of the hosted-effect list with nothing
  gained except that `update` stays pure -- and purity of `update` was
  buying us `roc test` on app logic and nothing else. We do not value that
  enough to keep the enum; it goes (section 8).
* He is half right about `Request`. The argument for it was never purity; it
  was that **the frame thread must not block**, and a synchronous `fetch!`
  in `update` stalls rendering. That justifies *deferral*, not
  *description*. Coroutines give deferral without description.
* The testing story the enums promised was only half delivered anyway: a
  `Transition` cannot be compared with `==`, so `request_description` had to
  be bolted on. A representation that needs a second representation to be
  testable is not earning its keep.

## 2. What exists today

The host cycle (`platform/main.roc:update_for_host!`, `src/host_native.zig`):

```
loop:
  responses  = drain worker completions            # host
  messages   = run each response's callback         # Roc, frame thread
  input      = { devices, window, time, messages, capture }
  transition = update(model, input)                 # Roc, pure
  apply commands in order                           # host
  submit requests → worker thread / timer / frame   # host
  render!(model, frame)                             # Roc, effectful
```

`App.Command` is a closed union of 29 synchronous effects. `App.Request(msg)`
is a closed union of six shapes (`ReadText`, `ReadBytes`, `Delay`,
`Screenshot`, `ReadClipboard`, `ListDirectory`), each with arguments and a
`Try(..) -> msg` callback. Adding a request kind touches the union, the
description union, `request_description`, `AppTransport` normalization,
`AppHost.SubmittedRequest`, the host's request kinds, and the generated ABI.
Adding a command touches the union, `CommandApply`, `command_description`,
and the coverage lint. The host accepts at most 32 requests in flight and
answers the rest with `Err(Busy)`; `RequestQueue.roc` exists to let apps pace
themselves under that cap.

The host already has one worker thread (the *effect worker* in
`host_native.zig`) with submission/result rings, and its contract is the one
that matters: *the worker accepts and returns plain Zig values; it must not
call Roc.*

Roc compiles to a plain C-ABI library. There is no runtime, no scheduler, no
thread-local interpreter state: a call into Roc is a function call whose
entire state lives on the native stack and in refcounted heap cells the host
allocated. That property is what makes coroutines possible at all.

## 3. The proposal

```roc
program = { init!, update!, render! }

init!   : App.Init(Model, err)
update! : Model, App.Input(Msg) => Try(Model, [Exit(I64)])
render! : Model, Draw.Frame     => Try({}, [Exit(I64), ..])
```

* **`update!` is effectful.** Synchronous host effects -- clipboard, cursor,
  audio, window hints, exit -- are called directly. `Command`, `Transition`,
  `with_command`, `command_description`, `CommandApply`, and the coverage
  lint are deleted. `Exit` is returned, matching `render!`.
* **Deferred work is a task.** `Task.spawn! : ({} => Msg) => {}` hands the
  host an effectful closure. The host runs it on its own coroutine stack, on
  the frame thread only. Hosted effects that must wait (file read, sleep,
  HTTP) park the coroutine on the event loop or a blocking-pool worker,
  and resume on a later frame. When the closure returns, its `Msg` is delivered through
  `Input.messages`, exactly as a `Request` callback result is today.
  `Request`, `RequestDescription`, the transport envelopes, and
  `RequestQueue`'s pacing role are deleted.
* **A runtime phase guard** decides which effects are legal where. The host
  always knows whether it is in `Init`, `Update`, `Render`, or a `Task`;
  every hosted effect is tagged with the phases it may run in, and a call
  from the wrong phase crashes with a message naming the effect, the phase,
  and the fix. Weaker than a type error, but it catches the mistake the
  first time the code runs rather than never.
* **No Roc value ever crosses a thread.** Workers see bytes.

## 4. The application developer's view

### 4.1 Before and after

`examples/async_read` today:

```roc
update : Model, App.Input(Msg) -> App.Transition(Model, Msg)
update = |model, input| {
    resolved = List.fold(input.messages, model, apply_message)
    reads = if input.time.cycle_count == 0 [
        Files.read_text(small_path, |result| SmallReadFinished(result)),
        Files.read_bytes(large_path, |result| BytesReadFinished(result)),
    ] else []
    App.next(resolved)
        .with_commands(if input.devices.key_pressed(KeyEscape) [App.exit(0)] else [])
        .with_requests(reads)
}
```

After:

```roc
update! : Model, App.Input(Msg) => Try(Model, [Exit(I64)])
update! = |model, input| {
    if input.devices.key_pressed(KeyEscape) return Err(Exit(0))
    if input.time.cycle_count == 0 {
        Task.spawn!(|{}| SmallReadFinished(Files.read_text!(small_path)))
        Task.spawn!(|{}| BytesReadFinished(Files.read_bytes!(large_path)))
    }
    Ok(List.fold(input.messages, model, apply_message))
}
```

Synchronous effects lose all ceremony:

```roc
# today
App.next(model).with_command(SetClipboardText(model.score_text))
# after
Window.set_clipboard!(model.score_text)
```

And multi-step work, which today is a state machine spread over `Msg`,
`update`, and `RequestQueue`, is a function:

```roc
load_level! : Str => Msg
load_level! = |dir| {
    manifest = Files.read_text!("${dir}/level.json") ? |e| LevelFailed(ManifestUnreadable(e))
    spec = Level.parse(manifest) ? |e| LevelFailed(ManifestInvalid(e))
    tiles = Files.read_bytes!("${dir}/${spec.tiles}") ? |e| LevelFailed(AssetUnreadable(spec.tiles, e))
    LevelLoaded({ spec, tiles })
}

update! = |model, input| {
    if input.devices.key_pressed(KeyEnter) Task.spawn!(|{}| load_level!("levels/01"))
    ...
}
```

Sequencing is `;`, errors are `?` and `match`, retries are loops, and the
intermediate state (`manifest`, `spec`) lives on the task's own stack instead
of in the model. `Msg` shrinks to the *outcomes* the app cares about. This is
what Romain asked for, and it is what Roc's effect system was built around:
effects are ordinary calls, the platform decides how they run.

Romain's click-handler question gets a single answer: a handler is
`=> Msg`. Pure ones return immediately; ones that wait are spawned. A future
retained-UI layer would simply `Task.spawn!` every handler and not need to
know the difference.

### 4.2 The rules an app author has to know

1. **Effects that wait go in a task.** `Files.read_bytes!` called directly in
   `update!` does not block the frame silently -- the phase guard crashes
   with "`Files.read_bytes!` waits; call it from `init!` or inside
   `Task.spawn!`". In `init!` it simply blocks, which is what asset loading
   at startup wants: `atlas = Files.read_bytes!("atlas.png")?`, no
   first-frame state machine.
2. **A task's return value arrives as a message on a later frame**, in
   completion order. A task cannot reach into the model; it reports, and
   `update!` decides. Same as a `Request` callback today.
3. **`render!` describes a frame; it does not change the world.** Audio,
   clipboard, window, `Task.spawn!`, and waiting effects all crash in
   `Render`. Draw effects crash everywhere else. Same rule as today, enforced
   at runtime instead of by `Frame`'s type alone.
4. **A task that computes for a long time stalls the frame.** Tasks are
   cooperative: they yield to the frame loop only when they wait on the host.
   Parsing 50 MB in Roc inside a task blocks rendering for the duration. It is
   the same rule as "don't do 50 ms of work in `update!`", plus `Task.yield!`
   for long loops and a host warning when a single resumption blows the frame
   budget (section 5.7).

There is no thread-safety story to learn, because there is no second Roc
thread. A task closure may capture a `Str` shared with the model, hand it to
another task, or return it in a message.

### 4.3 Standard modules instead of a catalogue

| Today                                   | After                                                         |
|-----------------------------------------|---------------------------------------------------------------|
| `Command.SetClipboardText(s)`           | `Window.set_clipboard!(s)`                                    |
| `Command.PlaySound(playback)`           | `Audio.play!(playback)`                                       |
| `Command.SetCursor(c)` (+ 25 others)    | the hosted effect, called directly                            |
| `Command.Exit(code)`                    | `Err(Exit(code))` from `update!`                              |
| `Request.ReadText({path, callback})`    | `Files.read_text! : Str => Try(Str, ReadTextError)`            |
| `Request.ReadBytes({path, callback})`   | `Files.read_bytes! : Str => Try(List(U8), ReadBytesError)`     |
| `Request.ListDirectory({path, callback})` | `Files.list_dir! : Str => Try(List(Entry), ListError)`       |
| `Request.Delay({millis, callback})`     | `Task.sleep! : U64 => {}`                                      |
| `Request.ReadClipboard({callback})`     | `Window.read_clipboard! : {} => Try(Str, ClipboardReadError)` |
| `Request.Screenshot({path, callback})`  | `Capture.screenshot! : Str => Try({}, ScreenshotError)`        |

`Http.fetch!`, `Files.write_text!`, `Path.*` become additions to a module,
not to a union.

### 4.4 Components

Without `Transition.map_msg`, a child component's tasks must produce the
parent's `Msg`, because `Task.spawn!` is monomorphic in the app's message
type. The idiom is the one Elm-family code already uses: the child takes a
`to_parent : ChildMsg -> msg` (or the parent passes a wrapping spawn):

```roc
Counter.update! : Counter.Model, App.Input(msg), (Counter.Msg -> msg) => Counter.Model
Counter.update! = |model, input, wrap| {
    if ... Task.spawn!(|{}| wrap(Counter.load!()))
    ...
}
```

This is a real regression in elegance from `map_msg` and should be stated as
such. It is the price of tasks being effects rather than data. Mitigation:
`App.Input.map` for routing child messages downward stays, and a small
`Task.spawn_with! : ({} => a), (a -> Msg) => {}` helper removes the closure
nesting from the common case.

## 5. The platform developer's view

### 5.1 What gets deleted

`App.Transition` and its receivers, `App.Command`, `App.Request`,
`App.RequestDescription`, `command_description`, `request_description`,
`CommandApply.roc`, the request/response envelopes in `AppTransport` and
`AppHost`, `RequestQueue.roc`'s pacing role, the command-coverage lint and
`docs/command-coverage.md`, the per-kind request dispatch in
`host_native.zig`, and the generated-ABI churn that came with all of it.

Adding a host effect becomes: the `hosted {}` block in both `main.roc`
files, the public wrapper module, one Zig `roc_fx_*` implementation, and a
phase tag. A waiting effect adds one line to that implementation:
the IO call goes through `rt.io()`, which parks the task instead of
blocking (section 5.3).

### 5.2 Host architecture: zio

The coroutine runtime is [zio](https://github.com/lalinsky/zio)
(`lalinsky/zio`, MIT, no dependencies, Zig 0.16 on `main`, v0.17.0 as of
2026-08-21). It is a layered async runtime: `zio.ev` (event loop:
io_uring/epoll/kqueue/iocp/poll), `zio.coro` (context switch, growable
guard-paged stacks, manual scheduling), and `zio.Runtime` (scheduler,
blocking-syscall thread pool, cancellation, task groups, and a full
`std.Io` implementation). Verified against its source:

* **One executor, on the frame thread, is the default.**
  `RuntimeOptions.executors = .exact(1)` with `enable_main_executor = true`
  makes the calling thread executor 0 and spawns no worker executors.
  Coroutines therefore only ever run on the frame thread; task migration is
  moot. This is the section 6 invariant, configured in one line.
* **Blocking work never runs a coroutine.** `spawnBlocking` and the
  `ev.ThreadPool` run plain functions on pool threads. File IO is io_uring on
  Linux and pool-backed elsewhere, transparently. That *is* the "workers see
  bytes" layer, already written -- the host's effect-worker rings are
  superseded.
* **All four targets.** io_uring/epoll on Linux, kqueue on macOS, IOCP on
  Windows; CI runs ubuntu x64 + arm64, macOS arm64 + intel, windows.
* **Stacks**: one guard page, 256 KB committed growing on demand to 8 MB
  (both configurable via `stack_pool`), pooled and recycled. Growth is a
  SIGSEGV handler on POSIX and `PAGE_GUARD` on Windows. Overflow faults on
  the guard page.
* **Cancellation** is first-class: `JoinHandle.cancel()` makes every later
  wait in that task return `error.Canceled`.
* **`std.Io`**: `rt.io()`. The host already writes file and directory code
  against `std.Io` (`readFileAlloc`, `createDirPath`, ...); on a task those
  calls now park instead of block, with no rewrite.

`zio.coro` is usable on its own, so if the `Runtime` scheduler ever proves
wrong for a frame loop, the fallback is the ~300-line own-scheduler design
this document originally proposed, on zio's switch and stacks.

**Phase guard.** Ours, not zio's. A single `threadlocal var phase: enum {
init, update, render, task }` set by the host around each entry into Roc,
and a comptime table mapping each `roc_fx_*` to its allowed phases. One
comparison at the top of every effect.

### 5.2a Why zio rather than `std.Io`'s own event loops, or our own

Zig 0.16 ships fiber-based evented `Io` implementations (`Io.Uring`,
`Io.Kqueue`, `Io.Dispatch`). Verified against the 0.16.0 source, they fall
short for a frame loop on four counts, and zio answers each:

| Concern | `std.Io` evented | zio |
|---|---|---|
| Threads | Work-stealing pools by default; `thread_limit = 0` pins to one thread but is a configuration of private internals | Single executor on the calling thread is the documented default |
| Windows | No evented backend; `Io.Threaded.async` spawns a real thread or runs inline | IOCP backend, in CI |
| Stacks | 60 MB virtual each, no guard page | Guard page, 256 KB committed, grows to a cap |
| Blocking syscalls | Per-implementation | Built-in thread pool, never runs a coroutine |

Writing our own scheduler on `std.Io.fiber.contextSwitch` (the switch
itself is public and ABI-agnostic) was the previous plan. It is still the
fallback, but it would re-implement stack pooling, growth, cancellation, a
blocking pool, and an event loop that zio already has tested on every
target we ship.

Risks specific to the dependency: single maintainer; pre-1.0 API that
tracks Zig master (pin the version, vendor if necessary); the stack-growth
SIGSEGV handler and sigaltstack must coexist with the host's own crash
handling; the `roc build` link path may need a few more libc stubs
(`sigaltstack`, `mmap`, `mprotect`) -- the same exercise as threads.

### 5.3 The suspend path

A hosted effect that may wait is ordinary `std.Io` code against `rt.io()`:

```zig
export fn roc_fx_files_read_bytes(path: *const RocStr, out: *RocResultBytes) void {
    guard.require(.files_read_bytes);                 // init | task, else crash
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io(), path.slice(), host_alloc, limit)
        catch |err| return out.fail(err);
    out.* = convertToRoc(bytes);                     // via roc_alloc
}
```

* **On a task**: zio parks the task on the io_uring/IOCP/kqueue completion
  (or on the blocking pool's result) and switches to the executor, which
  returns to the frame loop. A later frame's pump resumes the task; the
  call returns. From Roc's side it simply took a while.
* **In `init!`**: the frame loop is zio's main task, so the same call
  parks the main task and runs the event loop until the result is in --
  effectively blocking, which is correct there.
* **In `update!`/`render!`**: unreachable; the guard already crashed.

### 5.4 `Task.spawn!` and type erasure

`Task.spawn!` takes a `{} => Msg` closure. The host cannot know `Msg`; it
stores the closure as an opaque box and a ticket, the same way it stores
callback envelopes today. The platform provides
`run_task_for_host! : Box(TaskClosure) => Msg` (as it provides
`update_for_host!` now), and the host calls it as the body of a
`rt.spawn(...)`. The platform-side wrapper boxes the closure before the
hosted call, so the hosted signature is monomorphic (`Box(Erased) => {}`)
and the only place `Msg` is named is the `for_host` adapter.

### 5.5 The frame loop after

```
loop:
  phase = task;    pump                               # run ready tasks, poll IO
                   collect finished tasks' Msgs
  input = { devices, window, time, messages, capture }
  phase = update;  model = update!(model, input)      # sync effects, Task.spawn!
  phase = task;    pump                               # newly spawned tasks run to first park
  phase = render;  render!(model, frame)
  housekeeping
```

* The frame loop is zio's main task. "pump" is `zio.yield()`: it returns
  to the executor, which runs every ready coroutine and polls the event
  loop before returning when the main task is ready again. **Settled by
  the spike**: the fast path that skips the poll only applies inside a
  100 µs tick, so a frame-paced yield always polls and even an unpaced
  spin observes timers within ~100 µs. Measured idle cost ~0.4 µs.
* Sync effects run *during* `update!`, in program order, interleaved with
  model computation. Today they run after the model is committed. The
  difference is observable only if an effect's result feeds the model in
  the same frame, which is the imperative behaviour the app author wants.
* A task spawned this frame runs to its first park before `render!`, so
  its IO overlaps rendering as it does today. Its message arrives on a
  later cycle.
* zio's tick budget bounds *how many resumptions* happen per pump; it
  cannot interrupt one. That is the cooperative limit in 4.2 rule 4.

### 5.6 Caps, stacks, shutdown

* **Live tasks**: a cap (32 as now) on *tasks*, not requests. Past the cap
  `Task.spawn!` queues the closure and starts it when a slot frees, rather
  than answering `Err(Busy)`. That removes the reason `RequestQueue` exists.
* **Stacks**: zio's pool. Defaults (256 KB committed, 8 MB max) become
  `Config` knobs for apps that recurse deeply. Overflow hits the guard page;
  the host's crash handler names the task label.
* **Shutdown**: `Runtime.deinit` asserts no live tasks, so draining is
  mandatory. Stop accepting tasks, `cancel()` every live one, pump until
  they finish or a deadline (2 s) passes. A cancelled task's next wait
  returns `error.Canceled`; the hosted effect maps that to its `Err`
  variant and the Roc task runs to completion on the error path, releasing
  its values normally -- no leak in the common case. Past the deadline the
  host reports "N tasks abandoned" and exits anyway. `roc__drop_model_for_host`
  is unaffected. App-initiated cancellation is out of scope for v1 even
  though zio supports it; it needs every waiting effect's error type to
  carry `Cancelled`, which can be added per effect later.

### 5.7 Diagnostics

The host owns every switch point, so it knows for every task when it
started, how long it has been suspended, and on which effect. That is more
introspection than descriptions gave -- a description knew what was asked
for, never what happened next. `--trace-tasks` logs
start/suspend/resume/complete with the task's label; a per-resumption timer
warns "task `load level` ran 31 ms without yielding". The phase guard's
crash message is the third diagnostic and the one that replaces the type
system.

## 6. Why one Roc thread, and why not the prototype's scheduler

The prototype runs one executor per CPU and steals coroutines between them.
That is safe for a web server because each request is an island.

Our tasks are not islands: a closure's captures may share refcounted cells
with the model, with other tasks, and with the render path, and Roc's
refcounts are non-atomic. Two threads touching one cell is a race ending in
a use-after-free, and nothing the app author can do avoids it short of deep
copies Roc has no primitive for.

So: **one Roc thread, which is the frame thread** (raylib requires the GL
context's thread to render anyway), and worker threads that only see bytes.
This also rules out "just run the closure on an OS thread" as a cheaper
substitute: same sharing problem, plus a call into Roc from a non-frame
thread, which the worker contract forbids. If Roc later grows atomic
refcounts, a second Roc executor becomes an option the design does not
preclude.

## 7. The phase guard, in detail

Effect tags and the phases they are legal in:

| Tag        | Examples                                            | init | update | render | task |
|------------|-----------------------------------------------------|:----:|:------:|:------:|:----:|
| `draw`     | `Draw.*`, `Frame.*`, shader uniforms                |      |        |   ✓    |      |
| `state`    | clipboard set, cursor, audio, window hints, fps     |  ✓   |   ✓    |        |  ✓   |
| `load`     | font/texture/sound loading, `Text.prepare!`         |  ✓   |   ✓    |        |  ✓   |
| `wait`     | file IO, sleep, clipboard read, http, screenshot    |  ✓   |        |        |  ✓   |
| `spawn`    | `Task.spawn!`, `Task.yield!`                        |      |   ✓    |        |  ✓   |

Open choices, with a recommendation:

* **`load` in `render!`**: today a texture load mid-render is possible via
  the `Frame` type. Recommend: disallow, since it is a stall and a resource
  leak waiting to happen; `update!` or a task is where it belongs.
* **`wait` in `update!`**: crash (recommended) versus block-with-warning. A
  one-off config read on a keypress is harmless in practice, but
  "sometimes it's fine" is how 200 ms frame hitches ship. Crash, with the
  message pointing at `Task.spawn!`.
* **`spawn` in `init!`**: tempting for "start loading the second level
  before the first frame". Recommend allow; the task queues and starts on
  frame 0.

Guard violations are programmer errors and crash the process with a
one-line diagnosis, not a `Try`. The check is `roc_panic`-adjacent and costs
one comparison per effect.

## 8. Testing

`expect` cannot call effectful functions, so `update!` is not exercised by
`roc test`. This is a decision, not a regret: purity of `update` was the
only thing that guarantee was buying, and the project does not value it
enough to keep an enum layer for it. What exists instead:

* **Pure helpers stay pure.** `apply_message : Model, Msg -> Model`, rules,
  layout, parsing -- ordinary functions, `expect`-tested as today.
  `Input.for_tests` and the `with_*` builders remain for those.
* **Headless runs are the integration test.** `--headless
  --headless-frames=N` already runs the real loop; `--trace-tasks` makes
  task start/suspend/resume/complete assertable from `scripts/all_tests.py`.
* **Labels.** `Task.spawn_named!("load level", thunk)` names a task in
  traces and stall warnings. Optional, app-chosen.

## 9. Costs and risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Wrong-phase effect is a runtime crash, not a type error | Medium, accepted | Guard message names effect, phase, and fix; `roc check` still catches everything else |
| Cooperative stall from heavy compute in a task | Medium, by design | Frame budget + stall warning; `Task.yield!`; rule 4 |
| Component composition loses `map_msg` | Medium | `Task.spawn_with!`; document the `wrap` idiom (4.4) |
| zio is a single-maintainer pre-1.0 dependency | Medium | Pin the version; vendor if it stalls; `zio.coro` + own scheduler is the fallback |
| Frame-loop pump semantics (`yield` fast path skips the poll) | Closed | Spike: `yield` per frame is sufficient (see Spike status) |
| zio's SIGSEGV stack-growth handler vs host crash handling | Closed | Spike: overflow reports by name, no interference observed; still to do: name the task label in the report |
| zio's syscalls need glibc link stubs on the `roc build` path | Closed | Spike: one stub (`raise`) |
| Tasks still live at exit | Low | Cancel + drain with deadline (zio requires it); report abandoned count |
| Task stack overflow is a segfault | Low | Guard page + handler naming the task; configurable size |
| Every example rewritten | Certain | Mechanical; mostly deletion |
| Assumption: all Roc call state is on the native stack | Closed | Verified by the spike: a Roc call parked mid-effect and resumed 18 frames later with the frame loop running in between |
| A `Msg` cannot cross a hosted signature that carries a type variable | **Open, blocking** | Found in step 4; already breaks `App.request!` on the branch. Fix upstream, or keep `msg` out of hosted signatures and build every erased callable inside `update_for_host!` (see `docs/spike-coro-findings.md`) |

## 10. Migration plan

1. **Prove the loop.** *Done on `spike-coro` (five commits, not merged).*
   zio dependency, single-executor runtime, `Task.sleep!`,
   `Transition.with_task`, `examples/task_sleep`, trace flag. Settled the
   critical row, the pump question, and the link-stub cost.
2. **Phase guard + effectful `update!`.** `update! : Model, Input =>
   Try(Model, [Exit(I64)])`; sync effects called directly; `Command`,
   `Transition`, `CommandApply`, coverage lint deleted. No coroutines needed
   yet; `Request` survives this step. Port every example. This step alone
   answers most of the critique and is independently shippable.
3. **`Task.spawn!` as a hosted effect** (the host already holds closures
   opaquely and has the `task` phase; what changes is that `update!` calls
   it instead of returning tasks as data). Tasks and requests coexist.
   Port `async_read`. `ROC_RAY_TRACE_TASKS` already exists.
4. **Retire the effect worker**: `Files.*`, clipboard read, screenshot
   become `std.Io` calls against `rt.io()` that park on a task. Port
   remaining examples. *Done on `spike-coro`.* `async_read`,
   `capture_screenshot` and `postcard_studio` spawn tasks; `live_plot`
   replaced `RequestQueue` with its own `List(Work)` backlog;
   `input_inspector` dropped its message type entirely, because
   `Window.read_clipboard!` never parks and its result feeds the frame that
   asked.
5. **CI on all four targets**; link stubs the `roc build` path needs.
6. **Delete** `Request` and everything under it. Regenerate the ABI. *Done
   on `spike-coro`*: about 2,200 lines out of `host_native.zig` -- the
   effect worker, the ticket table, the delay timers, the per-cycle request
   budgets -- and `App.request!`, `App.Request`, `RequestQueue.roc`,
   `AppHost`'s request records, and all of `AppTransport` bar the
   recording-status decoding. Task results ride a `TaskResultStaging` of
   erased message thunks instead of the old response envelopes. The live
   task cap (32, queueing past it) landed with it.
7. **Add what the critique asked for**: `Http.send!` (`std.http.Client`
   over `rt.io()`; zio has an `http_client` example) -- *done, out of
   order, see "Step 7 status" above*; `Files.write_*!`, `Path`.

## 11. Summary for the two audiences

**App developer**: effects are function calls. Synchronous ones you call
from `update!`. Ones that wait you call from inside `Task.spawn!`, in
sequence, with `?`, and get a message back when they finish. `render!` only
draws. Get a phase wrong and the host tells you on the first run. Don't
compute for 50 ms without yielding.

**Platform developer**: one Roc thread, the frame thread; workers see
bytes; the host owns every suspend point and the phase of every call, so it
can trace, budget, cap, and police effects better than enum descriptions
ever let it. Adding an effect is adding an effect. The price is a dependency on zio configured to one executor, a guard table, and a
shutdown drain -- paid once, instead of seven edits per effect and an enum
that has to mirror the hosted list forever.

## Appendix: notes on the prototype

`bhansconnect/roc-coro-webserver` (Nov 2024, old syntax, native codegen):

* `coro.zig`: mmap 1 MB stack + guard page; `switch_context` saves
  callee-saved registers; `await_completion` registers an xev completion and
  switches to the scheduler; coroutines pooled via `reinit`.
* `scheduler.zig`: global queue + per-executor ring with steal, one executor
  per CPU. Not reused (section 6).
* `main.zig:659`: `roc_fx_sleepMillis` is the whole pattern -- a hosted
  effect that, from Roc's side, just blocks.
* Gaps for us: Windows, shutdown, live-task cap, frame budget, phase guard.
  zio (section 5.2) covers the first three; the budget and guard are ours.
  Its hand-written `asm/*.s` and libxev dependency are superseded.

## Follow-up: keep release bundles lean

Adding the HTTP client pulled `std.crypto` (TLS) into the host. A Debug
host archive grew 51 → 88 MB across four targets, pushing a locally built
bundle past roc's 100 MB transitive-dependency default; the harness now
passes `--max-transitive-mb=512` for local bundles. Releases build with
`-Doptimize=ReleaseFast` and `strip`, so a published host is ~10 MB and
unaffected -- but nothing *checks* that. To do:

1. Assert the bundle size in `release.yml` (budget well under 100 MB) so
   growth fails CI instead of being hidden by the raised limit.
2. Measure `std.crypto`'s ReleaseFast cost; evaluate `ReleaseSmall` for
   the host and per-target trimming of CA-bundle code.
