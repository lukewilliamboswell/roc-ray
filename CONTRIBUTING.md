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

Build the native hosts and platform inputs:

```bash
zig build
```

Run an example against the local platform:

```bash
scripts/run-example.py examples/cave_climb.roc
```

The runner builds the host, uses `platform/main.roc` for the run, and restores
the example's original platform reference when it exits. Pass
`--skip-platform-build` to reuse native libraries from an earlier `zig build`.

Debug hosts use a fast thread-safe allocator by default. To diagnose Roc-side
leaks with Zig's stack-tracing allocator, pass this flag to a Debug-built app:

```bash
scripts/run-example.py examples/cave_climb.roc -- --debug-allocator
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

This covers lints, Zig tests, platform privacy checks, and Roc checks/tests over
the examples. The lower-level example driver is also useful while iterating:

```bash
scripts/all_tests.py
scripts/all_tests.py --skip-platform-build
scripts/all_tests.py --skip-roc-build
```

It checks formatting and types, runs Roc tests, builds the apps, exercises their
headless paths, and verifies a locally served platform bundle. The scripts know
how to handle both local and released platform references; avoid committing an
incidental reference change made only for local testing.

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
scissoring, render textures, or paired drawing modes. The ordinary headless app
runs verify composition and lifecycle behavior, not framebuffer pixels.

## Design principles

These constraints are more important than mirroring raylib function for
function.

### Shape the API for app authors

Prefer operations on values an app already has:

```roc
frame.circle!(config)
host.key_pressed(KeySpace)
camera.screen_to_world(point)
texture.rect()
uniform.set!(value)
```

Use attached constructors such as `Assets.Texture.load!`,
`Draw.RenderTexture.load!`, and `Draw.Shader.load!` when creation naturally
belongs to the result type. A module function is still appropriate for a pure
helper or when there is no natural receiver.

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

### Snapshot input once per frame

Keyboard, mouse, gamepad and text state is sampled into `Input.Snapshot`,
window geometry into `Window.Snapshot`, and timing into `Time.Frame`; one step
carries all three. Prefer pure queries over repeated host calls. Views such as a
connected gamepad belong to that snapshot and should be queried immediately
rather than stored in the model.

Snapshot lists are designed for in-place reuse while uniquely owned. Retaining
an old snapshot can trigger copy-on-write on the next frame, so derive ordinary
app state from input instead of preserving host storage.

### Make ownership explicit

Fonts, textures, prepared text, sounds, music, render textures, and shaders are
typed host resources with lifetimes driven by Roc references. A final release
unloads the native value and makes its bounded slot reusable.

Keep capabilities narrow. For example, an `Assets.Texture` can be updated,
while an `Assets.TextureView` can only be sampled; a render texture exposes the
view. Keep typed shader-uniform handles so invalid setter combinations remain a
compile-time error.

Create long-lived resources during initialization and retain them in the app
model. Do not introduce per-frame loading, preparing, name lookup, or allocation
when the work can be paid once.

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
re-export module links across.

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
behavior without requiring GPU objects.

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

## Vendored encoders

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
added to the glibc link stubs in `platform/targets/*/libc_stub.s`.

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
- Run the graphical smoke test when pixels or drawing state can change.
- Update examples and docs when public behavior changes.
- Check `git status --short`, `git diff`, and `git diff --cached` for untracked
  files, generated output, platform-reference churn, binaries, or unrelated
  local edits.
