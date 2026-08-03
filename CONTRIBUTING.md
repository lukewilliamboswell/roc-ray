# Contributing to RocRay

Thanks for your interest in RocRay!

RocRay is an **experimental platform** that supports research and development of the Roc compiler. Its aim is to make simple games that demonstrate the benefits of the Roc language and of platform development. The goal isn't to build or support a large game engine — but we expect the ideas here to be expanded in future, and we're happy to provide support where it helps progress those aims.

Contributions that move that work forward are very welcome: new examples, bug fixes, additional platform primitives, documentation, and improvements that exercise the new Roc compiler. If you're unsure whether something fits, open an issue to discuss it first.

## Requirements

- [Zig](https://ziglang.org/download/) 0.16.0
- [Roc](https://www.roc-lang.org/) nightly for the new compiler, available as `roc` on `PATH`

## Building the Platform

Build the platform and cross-compile the pre-built host libraries for all supported targets:

```bash
zig build
```

The checked-in examples intentionally reference the latest published RocRay
bundle so that their source can be copied into another project and used as-is.
You can normally build and run them directly, e.g.:

```bash
roc build examples/hello_world.roc
./hello_world
```

For the best performance, prefer `roc build` over running a file directly with `roc examples/hello_world.roc`; the latter uses the in-development backends. See the performance note in the [README](README.md).

### Developing against unreleased platform changes

After a platform API change, the examples may temporarily require APIs that are
not present in the published bundle they reference. This is expected between
that change and the next release; a direct `roc check`, `roc build`, or
`roc examples/example.roc` can consequently report errors from the older
bundle.

Use the repository test script while developing the platform:

```bash
scripts/all_tests.py
```

To run one example interactively against the local platform:

```bash
scripts/run-example.py examples/cave_climb.roc
```

The runner builds the host, temporarily points that example at
`../platform/main-default.roc`, launches it, and restores its published URL on
exit. Pass `--skip-platform-build` to reuse host libraries from an earlier
`zig build`.

Debug host builds use the fast thread-safe allocator by default so
allocation-heavy interactive examples remain responsive. To diagnose Roc-side
leaks with Zig's stack-tracing allocator, opt in when launching an app:

```bash
./example --debug-allocator
```

The flag only changes allocator selection in a Debug host build.

The test script applies the same temporary substitution across the example
suite. CI follows the same policy using a freshly built bundle. Do not commit a
local platform reference in an example merely to make an unreleased API change
testable. Keep the published URLs in source, then update them to the new default
bundle after the release is available.

## Testing

Run code-quality lints (tidiness + style):

```bash
zig build lint
```

Run the full test suite (lints, Zig unit tests, and `roc check`/`fmt`/`test`/`build` over the examples):

```bash
zig build test
```

Rendering code also has an opt-in pixel-level smoke test. It opens a hidden
raylib window and validates scissoring, convex polygon rasterization, texture
source regions, and flipped quads against framebuffer pixels:

```bash
zig build graphical-smoke
# On a headless Linux CI worker with Xvfb installed:
xvfb-run -a zig build graphical-smoke
```

The regular headless example runs intentionally do not assert pixels, so run
this step whenever changing rendering primitives, texture coordinates, or
paired drawing modes.

Or run just the Roc example tests directly:

```bash
scripts/all_tests.py            # check, fmt, test, build, headless runtime
scripts/all_tests.py --skip-platform-build # reuse host libraries from zig build
scripts/all_tests.py --skip-roc-build      # skip building and running Roc apps
```

Enable the pre-commit hook (run once after cloning):

```bash
git config core.hooksPath .githooks
```

### Profiling the Roc compiler build

Profile Roc compiler build time on Linux with `perf`:

```bash
scripts/profile-roc-build.sh examples/cave_climb.roc 20
```

Set `ROC=/path/to/roc` to compare compiler builds. A Debug-built Roc compiler can spend substantial time in Zig's debug allocator; the cumulative call-stack report is usually more useful than self time for finding the compiler phase.

### Profiling example allocations

On Linux, measure steady-state Roc allocation traffic in every example with:

```bash
scripts/profile-example-allocations.py --build
```

The profiler runs each example headlessly for one frame and for 120 frames,
then subtracts the one-frame result to keep startup and resource loading out of
the per-frame totals. Pass example names to profile a subset, increase the run
length with `--frames`, show allocation-size histograms with `--sizes`, or use
`--json` for machine-readable output:

```bash
scripts/profile-example-allocations.py cave_climb top_down --frames 1000 --sizes
```

This measures calls through Roc's allocation ABI. It does not include internal
raylib or Zig allocator traffic.

Most non-empty example models currently show exactly one allocation whose size
is stable for every frame. That is the `Box(Model)` returned by
`render_for_host!`, not app-level list or string construction. Roc's box-reuse
optimization does not yet reuse it for these effectful render procedures. Treat
additional allocation sizes or reallocations as actionable app/platform work;
track the single model box as a compiler optimization opportunity. A zero-sized
model can avoid even that allocation.

### Host boundary performance

Shared read-only frame information should normally be sampled once by the host
and passed through `Host`, rather than exposed as several hosted queries. Keep
the Roc-facing API ergonomic and independent of its transport representation.
For example, callers can use `host.key_pressed(KeySpace)` while the host packs
held/pressed/released bits into one persistent key-state list; the equivalent
module-style call is `Keys.key_pressed(host, KeySpace)`.

Keep per-frame culling and coordinate lookup in pure Roc. Tilemap's
`draw_all_in!`/`draw_layer_in!` APIs bound work before drawing so each visible
tile crosses the host boundary exactly once and offscreen tiles do not cross it
at all. Do not create per-tile host resources or temporary Roc lists in a draw
loop.

Gamepad availability, buttons, and axes follow the same rule: the host samples
four fixed slots into flat persistent lists, and `Gamepad` helpers perform all
indexing on the Roc side. Mouse position, delta, and two-axis wheel movement are
sampled into scalar fields. Unicode text input is the intentional exception to
fixed-size storage: empty frames use the empty-list representation, while a
frame containing text allocates one exact-size `List(U32)` for the variable
number of queued codepoints.

The host allocates keyboard, mouse, and gamepad state lists once, updates them
in place, and retains them only while Roc owns the frame snapshot. If an app
keeps a snapshot list in its model, the next update uses copy-on-write so the
retained value stays immutable; that unusual case necessarily allocates a new
backing list. Do not rebuild these lists in the normal per-frame path.

Loaded fonts, textures, sounds, and music use typed, fixed-capacity host resource
heaps. Their handle allocation is ABI-compatible with Roc's `Box`: releasing the
final Roc reference routes through `roc_dealloc`, unloads the native value, and
makes the slot reusable. Creation effects return these host-backed boxes
directly; do not wrap a scalar handle with `Box.box` on the Roc side. Hot draw
and audio effects unbox the lifecycle token before crossing the boundary, so
they pass a scalar without per-call retain/release traffic. A live Roc reference
pins the slot, and the host validates its type, generation, and liveness on
every lookup.

Keep built-in resources allocation-free. For example, `Draw.default_font` is a
plain tag, while only `LoadedFont` carries a host-backed box. Box payloads may
also include immutable metadata: `Assets.Texture` stores dimensions beside its
token in the host slot, keeping the Roc model representation to one pointer.

Generated textures follow the same host-owned lifetime path as loaded textures.
CPU images used during generation are released before the hosted effect returns.
`Assets.update_texture!` borrows the contiguous Roc color list for one call and
does not copy or retain it in the host; build reusable pixel buffers outside the
render loop when possible.

Render textures and shaders follow the same ownership contract, but use distinct
resource kinds so a stale or cross-typed scalar token cannot resolve. A render
texture box stores its dimensions beside the token and owns its framebuffer,
color texture, and depth attachment as one unit. `Draw.render_texture` is an
allocation-free view: the returned host-managed reference still owns the complete
render target. Shader uniforms retain their shader and cache the native location
once; per-frame setters therefore pass only the shader token, location, and
scalar or small vector value. Avoid resolving uniform names, creating render
targets, or compiling shaders in the render loop.

Use `Draw.with_render_texture!`, `Draw.with_shader!`, and
`Draw.with_blend_mode!` for paired begin/end state changes. Render-texture color
attachments are vertically inverted when sampled, so use
`Draw.render_texture_source` when drawing them to the screen. The headless host
allocates typed lifecycle slots without creating GPU objects, allowing ownership
and effect composition to run in normal example tests. The host validates typed
resource tokens before a scope callback runs, so an invalid or cross-kind handle
cannot trigger an unmatched end call. Do not nest scopes of the same mode; raylib
does not restore an outer render target, shader, or blend mode.

App-specific state still belongs in the Roc model. Initialization-only effects
such as loading resources, reading files, and reading environment variables
should populate that model once; event-driven effects such as audio playback or
random spawning should remain at the event site.

## Glue Bindings

The Zig host's ABI types in `src/roc_platform_abi.zig` are generated by `roc glue`. Regenerate them after changing the hosted functions in `platform/main-default.roc`:

```bash
roc glue <path-to-roc>/src/glue/src/ZigGlue.roc ./src/ ./platform/main-default.roc
```

## Bundling

```bash
scripts/bundle.sh
```

This creates a `.tar.zst` bundle containing the default platform package, all shared `.roc` files, and prebuilt host libraries for all supported native targets.

The Wayland package is Linux x64 only and uses `platform/main-wayland.roc`:

```bash
scripts/bundle.sh --platform wayland
```

The Wayland bundle requires `vendor/raylib/linux-x64-wayland/libraylib.a`. Build it from a raylib 6.0 source checkout on Linux with:

```bash
scripts/build-raylib-wayland.sh /path/to/raylib-6.0
```

To use a Roc package bundle it should be hosted online with an `https:` url.

## Supported Targets

| Target | Description |
|--------|-------------|
| x64mac | macOS Intel |
| arm64mac | macOS Apple Silicon |
| x64glibc | Linux x64 |
| x64win | Windows x64 |

- We vendor the pre-compiled libraries from [raylib v6.0](https://github.com/raysan5/raylib/releases/tag/6.0)
- ARM Linux is not available (raylib doesn't provide pre-built libraries)
