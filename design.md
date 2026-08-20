# RocRay design

## Purpose and audience

This is the map, not the manual. It explains where the boundaries of this
platform are, what is deliberately on each side of them, and why -- so that
someone reading a module for the first time, or proposing a change, can tell
which parts of the design are load-bearing and which are just current detail.

It does not list the API. Module documentation does that, and it is generated
from the source, so it stays true. What follows names files instead of quoting
them.

Read `README.md` first if what you want is to write an app. Read
[`CONTRIBUTING.md`](CONTRIBUTING.md) if what you want is a checklist. Read this
if you want to know why those two say what they say.

## What RocRay is

A Roc platform over raylib, for games, visual tools, and interactive apps. It
is not a game engine and is not trying to become one: there is no scene graph,
no entity system, no asset pipeline. What it provides is a disciplined boundary
between a pure Roc application and a large C library, and enough of raylib's
graphics, audio, input, windowing, and resource surface to build real programs
on top of that boundary.

The host is native only -- macOS, Linux (X11 and Wayland), Windows. See
`targets:` in [`platform/main.roc`](platform/main.roc) for the exact set.

## The application model

A program is three functions, declared in the `requires` block of
[`platform/main.roc`](platform/main.roc):

- `init!` chooses the window configuration and builds the initial model. It may
  perform effects: loading, generating, allocating.
- `update` takes the model and one `Program.Step` and returns the next model
  plus any work for the platform. **It is pure.**
- `render!` takes the model and a `Draw.Frame`. **It may only draw.** The frame
  does answer for the surface it is drawing to -- `frame.size!()` -- because
  where a coordinate lands is a property of that surface rather than of the
  model. It observes nothing else.

The purity of `update` is the decision everything else follows from, and it is
not an aesthetic preference.

**Roc application code cannot be moved off the frame thread.** Values that are
immutable to the program still carry mutable reference-count metadata, so two
threads touching the same Roc value race on the refcount, not on the data. That
rules out "run the app on one thread and block on I/O in another". The host
therefore owns every thread, all asynchronous work, and all resource lifetimes;
the app stays single-threaded and never blocks.

**A reducer is testable in a way an effectful loop is not.** `update` is an
ordinary function of two values returning a third. An app's rules can be
exercised with `roc test` and no window, no GPU, and no audio device. The
platform relies on this itself -- see *Testing and verification* below.

**A reducer makes recording and replay meaningful.** The same model and the
same step always produce the same result, so a recording driven through the
real input path -- including the scripted pointer of `Capture.set_virtual_mouse`
-- is reproducible in a way an effectful loop sampling wall time is not. The
host does its half: `FixedStep` capture timing substitutes an exact `1/fps`
delta so encoder input does not depend on how long readback took, and headless
mode runs every effect inline so completion order does not depend on worker
scheduling. (See the caveat at the end of *Testing and verification*: this
particular property is designed for, not currently checked.)

The consequence app authors feel: anything the app needs to *know* must arrive
on the step, and anything the app wants to *do* must be returned as data.

## Three channels, and only three

Everything crossing the line between an app and the host goes through one of
three shapes. There is no fourth, and adding one is a design change rather than
a feature.

### 1. Observations arrive on `Program.Step`

Input, window geometry, time, recording status, and completed-task messages.
One step carries all of them, sampled once for the cycle. See the `Step` docs
in [`platform/Program.roc`](platform/Program.roc).

The rule is: **if application logic needs to see it, it is a `Step` field or a
task completion.** The platform does expose some host-state reads, but they are
scoped for drawing decisions -- a font metric, whether a sound is still
playing, how big the surface being drawn to is -- and are not a back door for
logic. A read has an answer, and an answer needs somewhere to go; the two
places that exist are the next step and a task callback.

`Draw.Frame.size!` is the shape of that exception. Where a drawing coordinate
goes is a property of the surface it lands on, so `render!` can ask the frame
how big that surface is: the window's logical drawing size normally, the render
target's size inside `with_render_texture!`. Nothing is decided with it that
`update` also has to decide -- which arrangement to use, or what the pointer is
over, still comes off `step.window`, because those are application logic and
belong where the rest of it is.

### 2. Immediate mutation is `Program.Action`

`Action` is a closed union in [`platform/Program.roc`](platform/Program.roc).
`update` returns a list of them; they are applied in list order during the
commit phase, before rendering, by `run_action!` in
[`platform/main.roc`](platform/main.roc).

Three things follow from actions being plain data:

- **They cost no ABI.** Actions are interpreted inside the platform, in Roc.
  Adding one adds no hosted function, no glue, no flat transport record.
- **They are inspectable.** `Program.action_shape` reduces an action to
  comparable data, dropping the opaque host resources that structural equality
  cannot see through. That is what makes "assert on what `update` decided to
  do" possible in a plain `expect`.
- **They report nothing.** An action runs and the cycle moves on. An action
  that could fail either stops the app or is silently skipped, by policy (see
  *Crash policy*). Outcomes an app must observe come back on a later step
  instead -- `step.capture` for recordings, a task for reads.

### 3. Deferred work is `Program.Task(msg)`

A task is a request plus the typed callback that turns its one terminal result
into an application message. The platform retains that callback privately;
the host allocates a ticket. **Tickets never reach the app.** Applications do
not invent correlation IDs and do not filter raw completions.

The invariant is: while the app is running, **every accepted task yields
exactly one terminal completion**, including an explicit `Err(Busy)` when the
host has no capacity. That is achieved by bounding *acceptance* rather than
delivery -- a task takes a reservation up front and holds it until its
completion is staged, so the host can refuse work without ever dropping a
callback (`MAX_TASKS_IN_FLIGHT`, 32, in `src/host_native.zig`).

Termination is the one exception, and it is not a leak: pending callbacks are
dropped at shutdown because there is no later step to deliver them on.

An app that wants more than 32 outstanding operations paces them itself.
[`platform/TaskQueue.roc`](platform/TaskQueue.roc) is the blessed pattern: a
pure FIFO holding no resource and performing no effect, so an app's pacing is
as testable as the rest of its logic.

## The action-coverage policy

> A hosted effect reachable in the commit phase without a corresponding
> `Program.Action` is dead API.

Because `update` is pure and `render!` only draws, an `Action` is the *whole*
of what a running app can change about host state. An effect the host will
accept during the commit phase that no action can ask for is reachable only
from `init!` -- which makes the commit-phase permission a lie and leaves apps
with a capability they can read about and cannot use.

[`docs/action-coverage.md`](docs/action-coverage.md) is the authoritative
table. Every commit-phase effect appears there, either against the action that
reaches it or against the written reason it deliberately has none. `zig build
lint` fails when a name is missing, so a commit-phase effect cannot be added
without answering the question.

The exclusions are as much of the design as the inclusions: reads (no result
channel), loaders and allocators (startup-only, and they return a resource,
which is the same result-channel problem), draw state (only meaningful ordered
against the draws around it), and the sticky sound setters -- superseded by
stating volume, pitch, and pan on every play through `Audio.Playback`, because
raylib holds them on the sound resource and the next play by anyone inherited
them.

## Phases

Capabilities can outlive the callback that produced them, so the host validates
each hosted operation against the callback it is currently inside. The `Phase`
enum and the `PhaseSet` constants in `src/host_native.zig` are the definition:

| Phase | Inside | Admits |
| --- | --- | --- |
| `startup` | `init!` and the config callback | loading, generating, GPU allocation, and everything commit admits |
| `commit` | applying the actions `update` returned | mutation of host state |
| `render` | `render!` | drawing and draw state |
| `idle` | between callbacks | nothing an app can reach |

The three that matter read as three sentences. Loading and GPU allocation
happen once, at startup, because they block or allocate on the GPU and a frame
is not the place for it. Mutation happens in the commit phase, because that is
where an ordered list of actions is being applied. Draw state exists only
inside the frame, because its meaning is its position relative to the draws
around it -- shader uniforms in particular have to be set inside
`Frame.with_shader!` and nowhere else.

A fourth set, `constant_time_anywhere`, admits operations with nothing to
allocate and no I/O to do -- a font metric, whether a sound is still playing --
in any callback but not outside one. Anything that copies, allocates, writes,
or touches a driver does not belong in it.

`enforcePhase` runs on every hosted export in release builds and panics on a
violation, naming the operation, the phases it *is* valid in, and the phase the
app called it from, in the app's own vocabulary rather than raylib's.

## Crash policy

The platform stops the app for programmer errors and reports recoverable
outcomes as data. The line is drawn at *could the app have known?*

Two upload failures crash: `PixelCountMismatch` (a pixel list that is not
exactly `width * height`) and `RegionOutOfBounds`. Both are knowable before any
action runs, both are reported by `Program.check_uploads`, and there is no
sensible way to carry on past one. The adapter checks the whole action list
*before* applying any of it, so the app stops without half a cycle applied.

Running out of upload budget is not one of these. It is a runtime limit and it
is handled in order, in the section below.

## Resources and data

Fonts, textures, prepared text, sounds, music, render textures, shaders, and
asset stores are typed handles over host-owned resources, reference counted by
Roc. The final Roc reference releases the native value and frees its bounded
slot. There is no release effect to remember and no way to use a handle after
freeing it.

Destruction does not happen inside `update`. A dropped reference *retires* the
resource; the host destroys retired resources at the end of the frame, up to a
budget (16 per frame), because each destruction is a driver or audio-device
call and a transition that drops two hundred textures should not stall the
frame it happened in. Pure `update` retires; the effectful loop destroys.

**Large file reads are the exception that proves the model.** `Program.read_file`
does not hand back a handle. The worker's allocation becomes a seamless
`List(U8)` -- an ordinary Roc list whose backing storage is the host resource --
so delivery copies no payload bytes and *holding the list is the whole ownership
API*. Sublists are seamless too, which means retaining a small slice pins the
whole source file; `List.release_excess_capacity` is the deliberate copy for
when that is the wrong trade. See `examples/async_read/main.roc`.

**Texture uploads are budgeted per step.** A cycle may upload
`Assets.max_upload_bytes_per_step` (4 MiB) in total. Validation is
all-or-nothing and happens first. The budget is then applied in order: the
first upload that does not fit is skipped, **and so is every upload after it in
the same cycle**, so the outcome does not depend on the sizes of later uploads.
Those textures keep the contents they had; nothing is fatal. `Program.check_uploads`
runs the identical placement logic in pure code, so an app can ask before
returning the actions and defer the rest itself rather than losing them.

## Performance doctrine

**The unit of cost is a boundary crossing, not a draw call.** raylib and the
GPU are fast; going back and forth across the Roc/host line thousands of times
a frame is not. The API is shaped to let an app pay for a crossing once:

- `Draw.Frame.texture_instances!` takes a list and lets the host loop, so a
  sprite batch costs one crossing however many sprites are in it. See
  `examples/particles/main.roc`.
- Tilemap drawing batches host-side for the same reason.
- `Text.Prepared` caches layout at startup so a frame does not re-measure text
  that did not change.
- Input is sampled once into `Input.Snapshot` rather than queried repeatedly.

**One honest caveat.** Mutating a collection held in the model currently costs
one full copy of it, every frame. The model arrives boxed, `Box.unbox` borrows
rather than consumes, so the box and the unboxed model are both live while
`update` runs and the first write to one of the model's lists takes the
copy-on-write path. Measured: 4,000,000 bytes per frame for a one-million-element
`List(F32)`.

This is a compiler-level gap, not a platform bug to route around, and it is
characterized rather than assumed -- `test/model_inplace` is the probe and
[`scripts/test_model_allocation.py`](scripts/test_model_allocation.py) keeps the
number from drifting *in either direction*. Its `--require-in-place` mode
asserts the invariant we want and expects to fail today; the day the upstream
fix lands, that becomes the checked mode and the characterization numbers are
deleted.

Two practical consequences meanwhile: writes after the first, within one cycle,
are in place, so batching a cycle's changes into one `update` costs one copy
rather than several; and a collection that changes every frame is worth keeping
small.

## Testing and verification

Claims in this document are properties of the code, held up by named checks.
When a detail here drifts, the check is what stays true.

| Property | Where it is held up |
| --- | --- |
| Exactly-once completion, including `Err(Busy)` past the bound | `src/host_native.zig`: *"more than 32 tasks receive terminal envelopes without a public task cap"*, *"a direct busy result moves its callback into staging"*, *"unknown and duplicate tickets do not consume another callback"*, *"pending callbacks are dropped once on shutdown"* |
| Zero-copy `List(U8)` delivery, and its ARC drop orders | `src/host_native.zig`: *"completing a large read transfers the worker allocation without copying"* (a 16 MiB read costs the frame thread the same bytes as a 29-byte one), *"seamless byte lists retain their typed slot through List and Str ARC in every drop order"* |
| Phase enforcement | phase tests in `src/host_native.zig`, including that a rejection names every phase the operation *was* allowed in |
| Upload budget and skip semantics | `src/host_native.zig`: *"a frame's texture uploads are metered, and startup's are not"*; `expect` blocks in [`platform/Program.roc`](platform/Program.roc) asserting a refusal yields a *prefix* and that `check_uploads` stops at the same first refusal |
| `action_shape` covers every variant | `expect` blocks in [`platform/Program.roc`](platform/Program.roc), including one shape per `Action` variant and a non-vacuous equality check |
| Model allocation cost | `test/model_inplace` + [`scripts/test_model_allocation.py`](scripts/test_model_allocation.py) |
| Action coverage | `checkActionCoverage` in [`ci/tidy.zig`](ci/tidy.zig), against [`docs/action-coverage.md`](docs/action-coverage.md) |
| Platform header sync (`main.roc` vs `main-wayland.roc`) | `checkPlatformHeadersInSync` in [`ci/tidy.zig`](ci/tidy.zig) |
| Internal platform modules stay private | `test/compile_fail/` + [`scripts/test_app_transport_privacy.py`](scripts/test_app_transport_privacy.py) |
| Pixel-level drawing behaviour | `zig build graphical-smoke` (opt-in; needs a display) |
| Every example still checks, tests, builds, and runs headless | [`scripts/all_tests.py`](scripts/all_tests.py) |

`zig build test` is the entry point; it depends on `lint` and covers the Zig
tests, the ABI and privacy checks, and `scripts/all_tests.py`.

**One claim in this document is designed for rather than checked.** Nothing
compares two capture runs byte for byte. The *mechanisms* are tested -- fixed
step timing in `src/capture.zig`, and headless mode executing every effect
inline precisely so its output does not depend on worker scheduling -- but the
end-to-end property is not. Treat "recordings reproduce" as a design intent
with a missing test, not as a verified invariant.

Two things worth knowing about the local flow. Apps resolve their packages over
**localhost**, not over relative paths: `scripts/bundle.sh` bundles the types
package and the platform, `scripts/local_bundles.py` serves them, and each app
is *copied* to a scratch directory with its header pointed at the served
bundle. So examples are checked in the shape they ship in, a stale reference is
not expressible, and no tracked file is ever rewritten -- `git status` stays
clean however a run ends. And a bare `roc check examples/foo.roc` checks the
*released* platform, not your working tree; use `roc check platform/main.roc`.

## Deliberately not in scope

Each of these is a decision with a reason, not a gap waiting for a volunteer.

**Subscriptions.** Cmd before Sub. The exactly-once, single-completion
invariant is load-bearing in the host's ticket table: a reservation is taken at
acceptance and released when the one completion is staged. A recurring event
stream has a lifecycle -- start, deliver repeatedly, stop, and something to say
when the app stops listening -- that does not fit that table and should not be
retrofitted onto it. Polling `Step` covers most of what subscriptions would.

**Runtime fullscreen toggling.** Starting fullscreen is supported
(`App.Config.with_fullscreen`); changing it while running is not. It needs a
new hosted effect and, before that, an answer to what fullscreen *means* here:
a real mode switch or a borderless window, what happens to the logical drawing
size the app has been laying out against, and what `Window.Snapshot` reports
across the transition. That is a design question, and it is not being answered
by adding an action.

**A web/WASM host.** Native only today. The architecture is kept
web-compatible on purpose, though: actions are data rather than calls,
completions are messages rather than blocking returns, and the application
contract makes no thread assumptions. None of those would have to change to
add a web host later; they would all have to change if the platform had gone
the other way.

**Effect-thunk escape hatches.** No `Program.command(|| ...)`. A closure
returned from `update` would be opaque: `action_shape` could not describe it,
`check_uploads` could not validate it, and the action-coverage policy would
have nothing to check because the closure could reach any effect it liked. It
would buy convenience by removing every property the rest of this document
depends on. The answer to "I need an effect that does not exist" is a new
`Action` variant or a new `Task` kind, both of which are cheap.

## Ecosystem and releases

`roc-ray-types` is a companion package holding the pure types a reusable Roc
package might need to name -- textures, fonts, colour, input, time, camera,
maths -- without depending on the platform. A package that only reads a
texture's dimensions should not have to pull in a host; mutating that texture
still requires the platform's `Assets`. That is the whole reason the package
exists: it is where capability ends and vocabulary begins.

The package is for *packages*. An application never names it: every package
type the platform's own API mentions is re-exported under a platform name --
`Assets.Texture` (aliased as `Draw.Texture`), `Math.Vec2`, `Color.Rgba`,
`Keys.KeyboardKey` -- so an app can hold any of them in its model with only the
platform in its header. The re-export is a transparent alias
(`Texture : RrtTexture.Texture` inside the module object), never a wrapper, so
the platform name and the package name are one nominal: a value an app gets
from `Assets.load_texture!` passes straight into a package signature written
against `rrt.Texture`, and back. A wrapper would look the same in the docs and
break exactly there.

The two release independently. The platform pins a *published* build of the
package in [`.types-version`](.types-version), never a relative path;
`scripts/bundle.sh` rewrites the staged platform header to that URL and refuses
to build if `types/` no longer bundles to the pinned filename. Bundles are
content addressed, so a platform release referencing a package build nobody
published is not expressible. When `types/` changes, release the package first.

Published API documentation is two doc sets, both required: the platform at
`www/<version>/` and the package at `www/<version>/types/`. `roc docs` attaches
a nominal's receivers to the module that *declares* it, so the package pages
carry signatures the platform's re-export modules do not.

## How to extend

**Adding an action** -- a variant on `Program.Action`, an arm in `run_action!`
in [`platform/main.roc`](platform/main.roc), a receiver-form constructor on the
owning type, and a row in [`docs/action-coverage.md`](docs/action-coverage.md).
None of it crosses the ABI. Add the `Program.action_shape` arm too, so the
action stays testable.

**Adding a hosted effect** -- follow the checklist in
[`CONTRIBUTING.md`](CONTRIBUTING.md). It touches both `platform/main.roc` and
`platform/main-wayland.roc` (`zig build lint` enforces the pair), and the
generated ABI in `src/roc_platform_abi.zig` has to be regenerated with
`scripts/roc_platform_abi.py --update`. Then answer the coverage question: if
the effect is admitted during the commit phase it needs an action, and if it
deliberately does not have one, write down why.

**Adding an example** -- a directory under `examples/`, a row in
[`examples/README.md`](examples/README.md), and that is all;
`scripts/all_tests.py` sweeps the directory, so a new example is checked,
tested, built, and run headless without being registered anywhere. Examples are
applications first and API demonstrations second. Exhaustive probes and
invalid-input cases belong in `test/`.
