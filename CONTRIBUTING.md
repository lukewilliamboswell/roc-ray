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

The resource receiver examples were measured over 119 startup-subtracted frames
after this API migration:

| Example | Allocations/frame | Bytes/frame | Deallocations/frame | Reallocations/frame |
|---------|------------------:|------------:|--------------------:|--------------------:|
| `generated_assets` | 1.000 | 32.0 | 1.000 | 0.000 |
| `sprites` | 1.000 | 56.0 | 1.000 | 0.000 |
| `post_process` | 1.000 | 48.0 | 1.000 | 0.000 |

Each allocation is exactly the current model box (32 B, 56 B, and 48 B,
respectively). Texture views, receiver dispatch, scoped callbacks, and typed
uniform updates add no steady-state Roc allocation.

### Host boundary and frame ownership

The native host owns BeginDrawing/EndDrawing and invokes Roc's
`render!(model, host, frame)` between them. Native cleanup closes the frame after
either `Ok` or `Err`. `Draw.Frame` is an opaque, zero-sized capability constructed
only by the platform adapter; every public drawing effect takes it. This
prevents initialization code from drawing and removes the two hosted outer-frame
calls that `Draw.draw!` previously made each frame.

Keep the Roc API shaped around application values even when its transport is
flatter. Prefer `frame.circle!(cfg)`, `host.key_pressed(KeySpace)`,
`camera.screen_to_world(point)`, `texture.rect()`, and `uniform.set!(value)`.
Attached constructors such as `Assets.Texture.load!`,
`Draw.RenderTexture.load!`, and `Draw.Shader.load!` group creation with the
result type. A module function remains appropriate when there is no natural
receiver or for a deliberate compatibility bridge.

Camera, scissor, blend, shader, and render-target callbacks return `Try`. Each
successful begin runs its matching end after the callback result is computed,
including callback `Err` values. All five scope families use bounded native
stacks, may nest, and restore the outer state without allocating. A full stack
returns `ScopeLimit`; an unresolved transferred resource returns
`ScopeUnavailable`; neither failure runs the callback. Pass the callback's
`Frame` onward rather than reintroducing an unscoped draw helper.

### Snapshot reuse and queries

Shared read-only frame information should be sampled once by the host and passed
through `Host`, rather than exposed as several hosted queries. The host packs
held/pressed/released bits into persistent key and mouse lists, and keeps
gamepad connectivity, buttons, and axes in three persistent flat lists. Their
receiver and module query forms are pure Roc, so multiple queries do not make
multiple host calls.

Use `host.gamepad(id)` to get either `Connected(pad)` or `Disconnected`. The
connected receiver carries the selected ID and references to the same snapshot
lists, so button, axis, and stick queries require neither repeated connectivity
checks nor allocation. It is scoped to that snapshot: query it immediately and
do not retain it in the application model. Resolve the slot again from the next
frame's `Host`.

Mouse position, delta, and two-axis wheel movement are scalar snapshot fields.
Cursor visibility and capture are one tagged operation through
`host.set_cursor_mode!` with `Visible`, `Hidden`, or `Locked`. Native cursor
shape is separate through `host.set_cursor!(cursor)`.

The host allocates keyboard, mouse, gamepad, and text-input state lists once,
then reuses their memory in place while uniquely owned. Unicode text input uses
a variable-length persistent list with initial capacity for raylib's 32-value
drain; changing its logical length and contents is allocation-free while that
capacity is sufficient. If an app retains an older snapshot in its model, the
next update uses copy-on-write so the retained value stays immutable. Text input
also grows when its current capacity is too small. These are intentional unusual
allocations; do not rebuild snapshot lists in the normal per-frame path.

### Resource ownership and capabilities

Loaded fonts, textures, sounds, and music use typed, fixed-capacity host resource
heaps. Their handle allocation is ABI-compatible with Roc's `Box`: releasing the
final Roc reference routes through `roc_dealloc`, unloads the native value, and
makes the slot reusable. Creation effects return these host-backed boxes
directly; do not wrap a scalar handle with `Box.box` on the Roc side. Hot draw
and audio effects transfer the typed owning value across the boundary. The host
resolves its internal token while that owner is live, performs the operation,
then releases the transferred reference. It validates type, generation, and
liveness on every lookup.

Keep built-in resources allocation-free. For example, `Draw.default_font` is a
plain tag, while only `LoadedFont` carries a host-backed box. Box payloads may
also include immutable metadata: `Assets.Texture` stores dimensions beside its
token in the host slot, keeping the Roc model representation to one pointer.

Generated textures follow the same host-owned lifetime path as loaded textures.
CPU images used during generation are released before the hosted effect returns.
`texture.update!` borrows the contiguous Roc color list for one call and does
not copy or retain it in the host; build reusable pixel buffers outside the
render loop when possible.

Keep the public texture capabilities distinct:

- `Assets.Texture` owns an ordinary mutable texture and provides `.update!`,
  `.width()`, `.height()`, `.size()`, `.rect()`, `.set_filter!`, `.set_wrap!`,
  and `.view()`.
- `Assets.TextureView` owns the same ARC reference but exposes sampling rather
  than pixel mutation. This nominal distinction adds no image copy or Roc heap
  wrapper.
- `Draw.RenderTexture.texture()` returns a `TextureView` that keeps the complete
  framebuffer resource alive. `.source()` returns its full vertically inverted
  sampling rectangle.

Render textures and shaders use distinct resource kinds so a stale or
cross-typed resource cannot resolve. A render texture box stores its dimensions
beside the token and owns its framebuffer, color texture, and depth attachment
as one unit. Resolve shader locations during initialization with typed receiver
constructors such as `shader.uniform_f32!("time")`. `F32Uniform`, `I32Uniform`,
vector, color, and texture handles prevent setter mismatches without runtime
tags. Each handle retains its shader and caches the location once; per-frame
`.set!` calls transfer the existing owner plus scalar or small-vector value
without allocating.

The headless host allocates typed lifecycle slots without creating GPU objects,
allowing ownership and effect composition to run in ordinary example tests.
Successful render-target and shader begins lease the transferred owner until the
matching end; failed lookups release it immediately and return
`ScopeUnavailable`.

### Validation and culling

Keep invalid states out of hot pure code. `Camera.Camera2D` is opaque and rejects
zero zoom through `Camera.new`, `Camera.follow`, `.with_zoom`, and `.clamp_zoom`,
which return `ZeroZoom`. Its receiver transforms and viewport calculation are
then total and stay in Roc.

`TilemapBuilder.build()` validates that every parsed tileset has exactly one
texture binding. Propagate or handle `MissingTilesetBinding(first_gid)` and
`DuplicateTilesetBinding(first_gid)` during initialization. A built tilemap owns
its texture bindings and routes every tile draw through the supplied `Frame`.
The culled `draw_all_in!`/`draw_layer_in!` APIs keep lookup in pure Roc so each
visible tile crosses the boundary once and offscreen tiles do not cross it.

App-specific state still belongs in the Roc model. Initialization-only effects
such as loading resources, reading files, and reading environment variables
should populate that model once; event-driven effects such as audio playback or
random spawning should remain at the event site.

### Startup configuration invariants

`App.Config` is opaque. Applications start from `App.default` and use receiver
updates such as `.with_title(...)`, `.with_size(...)`,
`.with_resizable(...)`, `.with_fullscreen(...)`, `.with_frame_pacing(...)`, and
`.with_cursor(...)`; direct record updates cannot bypass validation. This is the
only public configuration construction surface. The default is an 800×600
window using `Capped(240)` and `CursorVisible`.

Non-positive dimensions passed to `.with_size(...)` independently normalize to
the default width or height. Keep these 800×600 fallbacks synchronized with the
native host's defensive ABI normalization so `Config.to_host()` describes the
window that will actually be created.

Frame pacing is one tagged choice: `VSync`, `Capped(I32)`, or `Uncapped`.
`Capped(fps)` values at or below zero normalize to `Uncapped`, so Config cannot
contain a contradictory VSync-plus-cap state or an invalid non-positive cap.
The initial cursor is independently `CursorVisible` or `CursorHidden`. Runtime
cursor capture remains a `Host.CursorMode`, which additionally supports
`Locked`.

Keep `Config.to_host()` in the platform adapter. It flattens the validated
choices to the existing ABI record. VSync maps to a zero target FPS with VSync
enabled; a cap maps to that FPS with VSync disabled; Uncapped maps to a zero
target FPS with VSync disabled. The cursor tag similarly becomes the
`cursor_visible` boolean. Application code should not depend on that transport
shape.

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
