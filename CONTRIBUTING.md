# Contributing to RocRay

RocRay is a usable, intentionally small Roc platform for native interactive
apps. Contributions should help app authors make things with less friction
while keeping the programming model understandable.

Good contributions include bug fixes, documentation, realistic examples,
compiler compatibility work, performance improvements, and focused raylib
capabilities that compose with the existing API. RocRay is not aiming to grow
the editor, scene graph, or subsystem sprawl of a large engine. Open an issue
before a broad API change or a substantial new subsystem so its shape can be
discussed first.

## Development setup

Install:

- [Zig](https://ziglang.org/download/) 0.16.0
- The exact Roc nightly named in [`.roc-version`](.roc-version), available as
  `roc` on `PATH`
- Python 3 and `zstd` for the full test and bundle checks
- SQLite's `sqlite3` command-line tool for inspecting Observatory captures

`scripts/all_tests.py` resolves `roc` from `PATH`, so the pinned nightly has to
come first on it. A local debug build of the compiler is not a substitute: it
trips SpecConstr invariants on this platform's code and fails in ways that look
like platform bugs.

Build the native hosts and platform inputs:

```bash
zig build
```

Run an example against the local platform:

```bash
scripts/run-example.py examples/cave_climb
```

The runner builds the host and runs a *copy* of the example pointed at the
platform sources, so the checked-in files are never rewritten. Pass
`--skip-platform-build` (before the example) to reuse native libraries from an
earlier `zig build`, and `--platform-mode=bundle` to run against a bundled
platform instead of its sources.

The host reserves a few `--host-` switches for unattended runs. `--host-frames=N`
ends a real windowed run after N cycles, `--host-hidden` opens that window
hidden, and `--host-keys=3:S,4:LEFT+X` / `--host-text=5:hi` script the keyboard
and typed text on the cycles they name (a key is a character, one of a few names
such as `LEFT` or `SPACE`, or a raw key code; a `~` suffix, as in `3:ESCAPE~`,
taps the key inside that cycle -- pressed and released in one input, never
held -- which is what a hardware key that went down and up between two polls
looks like. `~` because it is inert unquoted in cmd, PowerShell, bash and zsh
alike; `^` is cmd's escape character and vanished on Windows). They are what
the windowed sweep below drives the examples with;
`--host-headless` and `--host-headless-frames=N` select the stub backend
instead, which draws nothing.

Debug hosts use a fast thread-safe allocator by default. To diagnose Roc-side
leaks with Zig's stack-tracing allocator, pass this flag to a Debug-built app:

```bash
scripts/run-example.py examples/cave_climb -- --host-debug-allocator
```

## Repository map

| Path | Purpose |
| --- | --- |
| `platform/` | Public Roc API, platform entry points, and hosted declarations |
| `src/` | Zig host, raylib backend, ABI types, resources, and native tests |
| `examples/` | Complete apps and focused, reusable patterns |
| `scripts/` | Local development, profiling, ABI, bundle, and release helpers |
| `test/compile_fail/` | Checks that internal platform details stay private |
| `types/` | The `roc-ray-types` package, released independently |
| `www/` | Versioned generated API documentation |

## Everyday checks

Run formatting and repository tidiness checks:

```bash
zig build lint
```

Run the main test suite:

```bash
zig build test
```

Generate the optional, threshold-free Observatory overhead report with:

```bash
zig build -Doptimize=ReleaseFast observatory-bench
```

The JSON and Markdown reports are written under `zig-out/`. Timing is not a CI
pass/fail threshold; deterministic recorder invariants remain in the ordinary
test suite. See [the Observatory methodology](docs/observatory.md#regression-and-microbenchmark-methodology).

This covers lints, Zig tests, platform privacy checks, and Roc checks/tests over
the examples. The lower-level example driver is also useful while iterating:

```bash
scripts/all_tests.py
scripts/all_tests.py --skip-platform-build
scripts/all_tests.py --skip-roc-build
scripts/all_tests.py --only pong,snake
```

It checks formatting and types, runs Roc tests, builds the apps and exercises
both their headless paths and, in the windowed sweep, the real raylib backend:
every example is run against a real (hidden) window for a bounded number of
frames, with the cases in `scripts/test_spec.json` scripting keys and typed text
into the examples with key-driven features and asserting the output, the exit
code and the files they write. Add a case there when you add an example -- the
spec is validated against `examples/`, so a missing one fails the run. Pass
`--skip-windowed` when there is no display; on Linux use `xvfb-run -a`. `--only` takes example names (repeatable, or comma
separated) and is the way to iterate on one example without waiting for the
rest.

### How the apps reach the platform

Every app stage resolves its packages over localhost. `scripts/bundle.sh`
bundles the roc-ray-types package and the platform into a scratch directory,
`scripts/local_bundles.py` serves that directory over HTTP, and each app is
*copied* to a scratch directory with its header pointed at the served bundle.
Three things follow:

- Examples are checked and built in the shape they ship in. `roc bundle` drops a
  relative dependency without complaining, and the app it breaks fails
  `roc check` with INVALID PACKAGE DEPENDENCY.
- Every reference to roc-ray-types resolves one freshly built artifact: the
  platform's, the four examples that name the package themselves
  (`cave_climb`, `generated_assets`, `projective_texture`, `top_down`), and both
  halves of `test/package_interop`. Building an app against a package build
  nobody produced is not expressible. `test/package_interop` is built every run
  to keep that honest.
- No tracked file is ever rewritten, so `git status` stays clean however a run
  ends -- including a `kill -9` part way through a build.

Built executables land in the scratch directory rather than beside each
`main.roc`; pass `--copy-executables` if you want them in place, and use
`scripts/run-example.py` to run one interactively.

Roc caches packages by content hash, so re-bundling changed sources produces a
new hash and a stale reference is not expressible. The port is derived from the
checkout path so the hashes stay put between runs and the cache is reused; edits
to `platform/` or `types/` each leave another extracted copy (~90 MB for the
platform) under `~/.cache/roc/packages`, so delete that directory when it grows.

Run `python3 scripts/local_bundles.py --serve` to hold the bundles up on
localhost yourself, for instance to build a separate app or package against the
same URLs.

Enable the repository's pre-commit hook once after cloning:

```bash
git config core.hooksPath .githooks
```

### Graphical changes

Rendering changes have an opt-in pixel-level smoke test:

```bash
zig build graphical-smoke
```

On a headless Linux worker with Xvfb:

```bash
xvfb-run -a zig build graphical-smoke
```

Run it when changing primitives, texture coordinates, shaders, blending,
scissoring, render textures, paired drawing modes, or native font metrics. It
also compares the scalar snapshot inside `Text.Font` with raylib's
`MeasureTextEx` for the default font and, when the system provides one, a
loaded proportional font. The ordinary headless app runs verify composition
and lifecycle behavior, not framebuffer pixels.

## Design principles

These constraints are more important than mirroring raylib function for
function.

### Shape the API for app authors

Prefer operations on values an app already has:

```roc
frame.circle!(config)
host.key_pressed(KeySpace)
camera.screen_to_world(point)
Assets.update_texture!(texture, pixels)
uniform.set!(value)
```

Use attached constructors such as `Draw.RenderTexture.load!` and
`Draw.Shader.from_store!` when creation naturally belongs to the result type.
Shared textures deliberately use standalone `Assets` functions because their
authoritative type lives in `roc-ray/types`, which has no host authority.

Keep transport details inside the platform. Flattened ABI records, scalar
handles, and hosted helpers should not leak into normal application code.

### Keep drawing frame-scoped

The native host opens and closes the outer raylib drawing scope. Roc receives an
opaque `Draw.Frame` in `render!`, and every public drawing effect requires it.
Pass the callback's frame through helpers; do not retain it in the model.

Camera, scissor, blend, shader, and render-target scopes return `Try`. A
successful begin must always run its matching end, including when the callback
returns `Err`. Scopes can nest and restore their outer state. Preserve
`ScopeLimit`, and preserve `ScopeUnavailable` for scopes backed by transferred
resources.

### Snapshot devices once per host cycle

Keyboard, mouse, gamepad and text state is sampled into `Devices.Snapshot`,
window geometry into `Window.Snapshot`, and timing into `Time.Cycle`; one
`App.Input` carries all three. Prefer pure queries over repeated host calls. Views such as a
connected gamepad belong to that snapshot and should be queried immediately
rather than stored in the model.

Snapshot lists are designed for in-place reuse while uniquely owned. Retaining
an old snapshot can trigger copy-on-write on the next host cycle, so derive ordinary
app state from input instead of preserving host storage.

### Make ownership explicit

Fonts, textures, prepared text, sounds, music, render textures, and shaders are
typed host resources with lifetimes driven by Roc references. A final release
unloads the native value and makes its bounded slot reusable.

Keep capabilities narrow. A package depending only on `roc-ray/types` can
retain a `Texture` and read its dimensions, while mutation requires the
platform's `Assets` module. Keep typed shader-uniform handles so invalid setter
combinations remain a compile-time error.

An *application* never adds `roc-ray-types` to its header. Name a texture held
in the model `Assets.Texture` (or `Draw.Texture`, the same type under a second
name); the platform re-exports it as a transparent alias, so it still unifies
with a package written against `rrt.Texture`. The same applies to every other
package type the platform's API mentions. If you find yourself adding an `rrt:`
entry to an example just to name a type, the platform is missing a re-export.

Create long-lived resources during initialization and retain them in the app
model. Do not introduce per-frame loading, preparing, name lookup, or allocation
when the work can be paid once.

**The package describes, the app performs.** A package that needs fonts,
textures, a window size, or work that waits does not get startup authority to
go and take them: `App.Startup` is a capability token the platform adapter
mints, and a type nobody outside the platform can construct would be a type
nobody outside the platform can use. Instead the package exposes a plan and a
pure constructor -- `Toolkit.required_assets : Theme -> List(AssetRequest)` and
`Toolkit.init : List(Draw.Texture), Text.Font -> Toolkit.State` -- and the
app's `init!` walks the plan, calls `Assets.load_texture!` and
`Draw.load_store_font!`, and hands the results back. For work that waits the
package exposes a closure rather than spawning: `Toolkit.fetch_theme! : () =>
Toolkit.Msg`, which the app starts with `Task.spawn_with!(input,
Toolkit.fetch_theme!, |m| ToolkitMsg(m))`. A package wanting to configure the
window answers the same way, with a suggestion the app applies. This is why
`Task.spawn_with!` exists, and it is the answer whenever a package author asks
for `App.Init` or `App.Config` in `roc-ray-types`.

### Validate before the hot path

Opaque values such as cameras, projective quads, and `App.Config` prevent
invalid states. Tilemap builders validate bindings and roles before rendering.
Prefer boundary validation that makes pure per-frame operations total and
cheap.

Startup configuration is one validated choice for frame pacing (`VSync`,
`Capped(fps)`, or `Uncapped`) plus independent window and cursor settings. Keep
the Roc representation and the native host's defensive normalization in sync.

## Examples and documentation

Examples are applications first and API demonstrations second. Each should have
a concrete interaction or game loop, retain long-lived resources in its model,
update state before drawing, and remain understandable without knowing host
internals. Exhaustive edge-case coverage belongs in tests.

When adding an example:

- Add it to [`examples/README.md`](examples/README.md) with its purpose and
  reusable patterns.
- Run it from the repository root so asset paths match how users invoke it.
- Put third-party licenses and attribution beside the relevant assets.
- Prefer generated or existing assets unless new binary files materially improve
  the example.
- Keep its platform reference compatible with the release workflow; local tools
  temporarily rewrite recognized local or release references as needed.

Public API changes should update module documentation, relevant examples, and
the user-facing README when they change how an app is started or structured.

## API documentation

The published reference is two doc sets: the platform at `www/<version>/` and
the `roc-ray-types` package at `www/<version>/types/`. Both are required.
`roc docs` attaches a nominal's receivers to the module that *declares* it, so
the platform's re-export modules carry the signatures while `Camera2D.with_zoom`,
`Mouse.State.position` and the rest live only on the package's pages. Each
re-export module links across. Put a receiver's user-facing documentation on
the module that declares the nominal, or it will not render anywhere.

The renderer takes paragraphs, `backtick` code spans, and fenced code blocks
opened with ```` ```roc ````. It does not take markdown headings, bullet lists,
`**bold**`, or four-space indented code: each of those reaches the page as
literal text. Write examples in fences and structure a long module comment with
short paragraphs.

Build and validate both locally:

```bash
scripts/build_docs.py --check              # temp dir, touches nothing
scripts/build_docs.py --version 0.10.0     # writes www/0.10.0 and www/0.10.0/types
```

`--check` fails on a module missing a page, a broken relative link, or a
re-export module that stops pointing at the package docs. The release workflow
runs `--check` before building and the versioned form when publishing.

## Releases

The platform and the `roc-ray-types` package release independently, so either
can be bumped on its own:

- **Types package** — run the "Release roc-ray-types" workflow, then update
  `.types-version` with the URL it prints.
- **Platform** — run the "Release" workflow. `scripts/bundle.sh` rewrites the
  staged platform header to the pinned package URL and refuses to build if
  `types/` no longer bundles to the pinned filename. Bundles are content
  addressed, so a platform release can never reference a package build that was
  never published.

When `types/` changes, release the package first. The local and CI bundle tests
bypass the pin with `--types-url-base`, bundling and serving the package
themselves.

## ABI and host changes

`platform/main.roc` and `platform/main-wayland.roc` are the same platform built
for two link configurations. Every change outside their `targets:` blocks --
adding a hosted effect, an exposed module, a package dependency -- must be made
to both. `zig build lint` enforces this and points at the first line that
drifted; without it a missing entry only surfaces when someone links against the
Wayland bundle.

A value that crosses the host boundary is flat: scalars, `List` of scalars, or
`List` of a record of scalars. Unions and boxed lists do not cross. The input
event record is the worked example -- the host fills
`List({ kind : U8, code : U32, x : F32, y : F32 })` and
`Devices.events_from_raw` in the types package decodes it into the typed
`Devices.Event`; the `kind` numbering is stated on both sides
(`InputEventKind` in `src/backend_raylib.zig`, `event_from_raw` in
`types/Devices.roc`) so neither can drift alone. A new field on
`Devices.Snapshot` touches `InputFromHost` and `input_from_raw` in both
platform headers, `Devices.none` and `Devices.empty`, and the ABI regeneration
below.

Every hosted effect carries a phase set in `src/host_native.zig` --
`enforcePhase(name, during_update)` and friends -- that says which app
callbacks may reach it: `during_load` and `during_update` for anything that
changes host state (`init!`, `update!`, tasks), `during_render` for drawing,
`during_wait` for effects that park a task, `during_spawn` for `Task.spawn!`,
`constant_time_anywhere` for a query with nothing to allocate and no I/O to do.
A call from the wrong phase stops the app with a message naming the effect, the
phase, and the fix, so choose the set deliberately and keep the public wrapper's
doc comment in step with it.

`during_load` is for allocating or generating a resource from bytes the app
already holds -- `Assets.texture_from_bytes!`, `Draw.Shader.from_source!`,
`Audio.gen_sound!`. A loader that opens a directory or reads a file is
`during_wait`, however small the file: reaching the filesystem from `update!`
is exactly what invariant 4 forbids. Where the resource can be built without
touching the filesystem, give the effect a `*_from_bytes!` sibling in
`during_load` so an app can still finish in `update!` a load a task started.

An effect in `during_wait` does its I/O through `waitingIo()` rather than
`mainThreadIo()`, and wraps the call in a `WaitScope` so the phase is restored
when it resumes. On a task that parks the coroutine and the frame loop keeps
running; in `init!` it parks the frame loop's own task and pumps the event loop
until the answer is in, which is the blocking behaviour startup wants.

Work the event loop cannot take runs on zio's blocking pool instead, through
`rt.spawnBlocking` with a `std.Io.Threaded` inside the worker: a file write,
because creating directories through the runtime's file backend fails on
Windows, and anything reached through a descriptor the frame thread opened and
closes, such as an asset store's directory handle. The pool parks the caller
the same way the event loop would, and the worker must see host-owned bytes
only -- never a Roc value.

`during_frame_wait` is `during_wait` without `init!`, for a waiting effect
whose answer is a frame that has to be drawn first. `Capture.screenshot!` is
the one that needs it: it parks until the framebuffer has been read back at the
end of a frame, and `init!` runs before the frame loop has drawn one, so a
screenshot asked for there would wait for a frame that cannot arrive while it
holds the frame thread. Reach for this set only when an effect genuinely waits
on the frame loop's own progress; anything else that waits belongs in
`during_wait`.

An effect that reports a failure by code, rather than by tag union, shares the
numbering with the effects it fails alongside. `Files` is the worked example:
`NotFound`, `Unavailable` and the generic failure have the same code for a read
and for a write, so one code never means two things across the boundary, and
the codes only one of them can produce -- `NotUtf8`, `NotADirectory`,
`PermissionDenied`, `NoSpace` -- are numbered past that shared table. Keep the
Roc-side decoder and `src/host_native.zig` in step; each constant says where
its counterpart lives.

A new private `<X>Host.roc` needs its own privacy fixture. The module is kept
out of `exposes` so an app cannot import it, and nothing but a test proves that
stayed true: add `test/compile_fail/<x>_host_module.roc` importing it, and
register the file in `scripts/test_app_transport_privacy.py` as a `CASES` entry
pairing that path with the diagnostic strings the compiler must produce -- the
title `package module is private` and the module's own name -- so `zig build
test` compiles it and requires that failure. Without the registration the
fixture is never built and the privacy is unchecked.

`roc test` cannot reach a new effect through `update!`: an `expect` cannot call
an effectful function, and the phase guard would refuse the effects inside one
anyway. Cover it from both sides instead -- a Zig test in `src/` for the host
half, a headless example run for the whole path -- and shape the public wrapper
so an app can keep its decisions in pure functions (`apply_message : Model, Msg
-> Model` and friends) that `update!` only performs. Those pure functions are
what an app's own `expect`s exercise, using `App.Input.for_tests` and the
resource `stub`s.

### Pin `msg` with a witness

**Any platform function whose signature mentions `msg` and reaches a hosted
effect must pin `msg` with an `App.Input(msg)` parameter** (or something else
equally concrete that the app already holds). That is why `Task.spawn!` takes
an input it never reads:

```roc
spawn! : App.Input(msg), (() => msg) => {}
spawn! = |_input, task!| TaskHost.spawn!(Box.box(task!))
```

Only `platform/main.roc` can name the `requires` bound `Msg`. Everywhere else
`msg` is an ordinary type variable, so without a witness it generalizes: the
call site's closure is compiled at whatever type its own body implies --
`|| Woke` becomes `[Woke]`, a single-tag union with no discriminant -- while
`run_task_for_host!` decodes the bytes as the app's real `Msg`. The result is a
wrong tag, a payload read through the wrong variant's layout, or an abort in
`roc_dealloc` when the misread variant holds a `Str` or a `List`. The witness
unifies the two and the whole class of failure goes away.

`Task.spawn_with!` takes the same witness and adds a wrapper, so a component
can answer in its own message type while the parent lifts it:
`Task.spawn_with!(input, Counter.load!, |m| CounterMsg(m))`. The input still
pins `msg` -- through the wrapper's result rather than the closure's -- so the
rule is unchanged. The wrapper is a lambda because a bare tag name is not a
function in Roc.

This is an API rule, not a workaround for a compiler defect. `test/task_delivery`
guards it: it spawns one task per `Msg` variant and exits non-zero unless every
message comes back with the right tag and payload. `scripts/all_tests.py` runs
it.

The Zig ABI types in `src/roc_platform_abi.zig` are generated by `roc glue`.
After changing hosted functions in `platform/main.roc`, regenerate them with a
local checkout of the Roc repository:

```bash
scripts/roc_platform_abi.py \
    --roc-repo /path/to/roc \
    --roc /path/to/pinned/roc \
    --update
```

Verify the checked-in file without modifying it:

```bash
scripts/roc_platform_abi.py \
    --roc-repo /path/to/roc \
    --roc /path/to/pinned/roc \
    --check
```

The helper requires the compiler and Roc source revision to agree with
`.roc-version`. Its focused tests run under `zig build test` or directly with:

```bash
python3 scripts/test_roc_platform_abi.py
```

Host-backed resources use typed, generation-checked slots. Successful hosted
effects must release transferred references exactly once, including failure and
scope-unwind paths. The headless backend should continue to exercise lifecycle
behavior without requiring GPU objects. A new typed resource adds a member to
`host_resource.Kind` and nowhere else -- heaps name a kind rather than a number,
and the host fails to build if a kind has no heap or has two.

A new `src/*.zig` module whose only caller is a hosted export needs a
`test { _ = the_module; }` in `src/host_native.zig`. The exports are compiled
out under `zig test`, so nothing references the module, Zig never analyses it,
and its tests are silently absent from the run -- the suite reports the same
number of passes it did before, with a broken assertion sitting in the file.
`src/http_effect.zig` is the worked example.

A Debug host archive carries the whole of `std.crypto` for the HTTP client's
TLS and bundles past roc's default 100 MB transitive-dependency budget, so
bundling one by hand needs `--max-transitive-mb=512`, which the scripts already
pass.

## Performance work

Profile a Roc compiler build on Linux:

```bash
scripts/profile-roc-build.sh examples/cave_climb.roc 20
```

Set `ROC=/path/to/roc` to compare compiler builds.

Measure steady-state Roc allocation traffic and hosted calls in examples:

```bash
scripts/profile-example-allocations.py --build
scripts/profile-example-allocations.py cave_climb top_down --frames 1000 --sizes
```

The allocation profiler subtracts one-frame startup behavior from a longer run.
It sees Roc allocation ABI calls, not internal allocations made by raylib or
Zig. Use the native lifecycle and allocation tests when optimizing inside a
hosted effect.

Any built app can report its own per-frame allocation instead, without GDB:

```bash
ROC_RAY_ALLOC_STATS=1 examples/pong/main --host-headless --host-headless-frames=120
```

Each frame prints one line to stderr with the bytes and calls that frame
allocated and freed, and how much of it belonged to `update`. Unset, the host
does not install the meter at all.

That is how the cost of holding a collection in the model was measured:

```bash
scripts/test_model_allocation.py --report
```

Changing one element of a list in the model is an in-place write: the box the
model arrived in is consumed, so the list is uniquely referenced at the write
and a frame costs only the model box. `test/model_inplace` is the probe and
`scripts/test_model_allocation.py` runs in `all_tests.py`, holding steady-state
per-frame allocation under a 16 KiB budget.

## Bundles and targets

Build the default release bundle:

```bash
scripts/bundle.sh
```

Build the Linux x64 native Wayland bundle:

```bash
scripts/bundle.sh --platform wayland
```

The Wayland bundle requires
`vendor/raylib/linux-x64-wayland/libraylib.a`. Rebuild it from a raylib 6.0
source checkout with:

```bash
scripts/build-raylib-wayland.sh /path/to/raylib-6.0
```

Both bundles need every target's archives under `platform/targets/`, which a
plain `zig build` produces -- it cross-compiles all four of x64mac, arm64mac,
x64glibc and x64win. So a local checkout can build a complete bundle, which is
what `scripts/all_tests.py` relies on. `bundle.sh` names the exact file it is
missing if some target was never built.

The platform depends on roc-ray-types by relative path, which cannot survive
bundling, so `bundle.sh` rewrites the staged header to a real URL: the release
pinned in `.types-version`, or `--types-url-base` when the package is being
served locally.

## Vendored C libraries

Screenshots go through raylib's own PNG writer, but GIF and video need encoders
the vendored raylib does not have. Both are vendored as *source* and compiled by
`zig build` for every target, so there is no configure step, no prebuilt archive
to re-vendor per platform, and no per-OS CI runner in the loop:

- `vendor/msf_gif/` -- a single-header GIF encoder (MIT or public domain). Built
  freestanding like the host; the handful of libc declarations it needs come
  from the `shim/` directory beside it.
- `vendor/libvpx/` -- the VP8 encoder from libvpx (BSD-3-Clause, royalty-free).
  C only: libvpx writes some of its SIMD as compiler intrinsics, which `zig cc`
  compiles, and the rest as NASM/GAS assembly, which Zig cannot assemble. The
  intrinsics are vendored, the assembly is not, so no assembler is needed to
  build or to re-vendor. Because the ISA is fixed at compile time (there is no
  runtime CPU detection), the generated headers are per architecture:
  `config/x86_64/` for the three x86-64 targets, `config/arm64/` for arm64mac.
  `vendor/libvpx/config/regenerate.sh` redoes all of it in one command and
  `config/README.md` explains what it produces -- that is the one thing to run
  when upgrading. `scripts/check_libvpx_archives.py` guards the invariants.
- `vendor/sqlite/` -- the SQLite amalgamation (public domain), behind `Sqlite`.
  One source file and no configure step, so upgrading is a two-file copy;
  `vendor/sqlite/README.md` pins the version and SHA-256 and explains the
  compile flags that are decisions rather than tuning. `SQLITE_THREADSAFE=1`,
  `SQLITE_OMIT_LOAD_EXTENSION` and `SQLITE_DQS=0` are the three worth knowing
  about before changing anything.

`zig build graphical-smoke` runs the pixel-level rendering and capture checks
under a real GL context. CI runs it under `xvfb-run` in a job of its own, on a
newer runner than the build matrix: it is the only target that links the system
libc directly, and the vendored raylib references glibc 2.38 symbols that
ubuntu-22.04 lacks. The platform and examples link through the generated libc
stub and are unaffected.

Both expose only primitives and opaque pointers to Zig through a small C shim,
so the freestanding host module never needs C headers. Each produces its own
static archive, copied into `platform/targets/<target>/` and named in the
`targets:` block of `platform/main.roc`, exactly as `libraylib.a` is.

libvpx uses `setjmp`/`longjmp` for encoder error handling, so those symbols were
added to the glibc link stubs in `platform/targets/*/libc_stub.s`. SQLite's unix
VFS and its serialized threading mode added ten more there and in
`libm_stub.s`. Expect this to be the recurring cost of vendoring a new C
library: the stub files are hand-written assembly, and a missing symbol shows up
as a link error naming it, not as a build failure in the library itself.

Release bundles support Intel and Apple Silicon macOS, x64 Linux, and x64
Windows. The vendored raylib version is recorded in `vendor/raylib/VERSION`.
ARM Linux is not currently included.

The release workflow builds and tests both bundles, publishes versioned API
docs, and opens a follow-up PR that updates example bundle URLs and the docs
index. Do not manually publish an untested local bundle as a release artifact.

## Pull request checklist

Before opening a PR:

- Keep the change focused and explain the app-author problem it solves.
- Add or update tests for behavior and failure paths.
- Run `zig build lint` and `zig build test`.
- For a new private `<X>Host.roc`, add `test/compile_fail/<x>_host_module.roc`
  and register it in `scripts/test_app_transport_privacy.py`.
- Run the graphical smoke test when pixels or drawing state can change.
- Update examples and docs when public behavior changes.
- Check `git status --short`, `git diff`, and `git diff --cached` for untracked
  files, generated output, platform-reference churn, binaries, or unrelated
  local edits.
