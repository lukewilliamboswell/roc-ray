# RocRay

Make native games, visual tools, and interactive apps in [Roc](https://www.roc-lang.org/), powered by [raylib](https://www.raylib.com/).

![Launching Cave Climb from a terminal, followed by gameplay with animated sprites and a mouse-controlled laser](examples/roc-ray-showcase.webp)

*Cave Climb combines an authored tilemap, sprites, camera movement, collision
handling, sound, and mouse-driven tools.*

RocRay is intentionally simple: an app owns a model, updates it from the current
input snapshot, and draws a frame. It is not trying to become a large game
engine. Instead, it gives Roc apps a focused interface to raylib's broad set of
graphics, audio, input, windowing, and resource features.

RocRay is a usable app platform rather than a research experiment: release
bundles are tested on the supported systems, and the repository includes
complete games. It follows Roc's new compiler closely, so pin a RocRay release
and its matching Roc nightly together. RocRay APIs may still change as the
language evolves.

## Quick start

Install the Roc nightly named in [`.roc-version`](.roc-version) and
[Zig 0.16.0](https://ziglang.org/download/), then clone this repository and run
the smallest example against the local platform:

```bash
git clone https://github.com/lukewilliamboswell/roc-ray.git
cd roc-ray
zig build
roc build examples/hello_world.roc
./hello_world
```

On Windows, run `hello_world.exe`. Build from the repository root so example
asset paths resolve correctly.

Use `roc build` to produce a native executable. Running a source file directly
with `roc` uses Roc's in-development backend and is currently slower. Apps that
load files at runtime still need those assets distributed at the paths their
source expects.

Zig is not required to build apps with a released RocRay bundle. It is required
when using the local platform from a source checkout or changing the platform
itself.

## The app loop

A RocRay program has two parts. The model is the app state that survives from
one frame to the next:

- `init!` chooses the window configuration and creates the initial model.
- `update` receives that model and a read-only `Step` -- this cycle's
  `Input.Snapshot`, `Window.Snapshot` and `Time.Frame` -- and returns the next
  model plus any work for the platform. It is pure.
- `render!` receives the model and a `Frame` used for drawing.

Read the complete, 44-line [`hello_world.roc`](examples/hello_world.roc) from top
to bottom to see this loop in the smallest complete app. Load long-lived
textures, sounds, fonts, shaders, and text that does not change during `init!`;
store them in the model and reuse them while rendering.

### Deferred tasks

`update` can also return work that finishes later. Give each task constructor a
typed callback that turns its terminal result into your app's `Msg`, then fold
the resulting `step.messages` into the model on a later frame:

```roc
Msg : [ConfigLoaded({ path : Str, result : Try(Str, Program.SmallFileError) })]

tasks = [Program.read_small_file("config.txt", |result| ConfigLoaded({ path: "config.txt", result }))]

Program.static(model)
    .with_tasks(tasks)
```

`Program.static` starts an update with no work. Its receiver methods append
actions or tasks in order; use `Program.from_parts(model, actions, tasks)` when
a helper has already assembled both lists. Independent component updates can
also be combined with Roc's record-builder form, for example
`{ game: game_update, ui: ui_update }.Program`; its actions and tasks retain
that left-to-right field order.

The host owns private transport tickets; apps do not allocate IDs, match
completions, or maintain a task batch. It preserves the host-observed order of
messages within a step. A task that cannot complete with current host capacity
still calls its callback with its operation's `Busy` result, so an app may show
an error or explicitly retry it. See [`async_read.roc`](examples/async_read.roc) for file reads and
[`input_inspector.roc`](examples/input_inspector.roc) for a clipboard task.

## Start your own project

The easiest route is to copy one of the examples closest to what you want to
make. Hello World, Pong, Snake, and Breakout are self-contained; the larger
examples also need their files from `examples/assets/`. For a project outside
this checkout:

1. Copy the example's `.roc` file and any assets it uses.
2. If its first line refers to `platform "../platform/main.roc"`, replace that
   local path with the default `platform` declaration from the
   [latest release](https://github.com/lukewilliamboswell/roc-ray/releases/latest).
   Examples updated by the release workflow may already contain the bundle URL.
3. Build it with `roc build your_app.roc`.

Release bundles include the native host libraries, so app authors do not need
to build RocRay or raylib themselves. A bundle is the packaged Roc API plus
those libraries. Use the `.roc-version` from the bundle's release tag, which may
differ from the version required by the current source checkout.

Use the default bundle on macOS, Windows, and Linux through X11 or XWayland. A
separate native Wayland bundle is included in each release for Linux x64.

## What you can make

RocRay provides the pieces needed for much more than a minimal drawing demo:

- Styled 2D shapes, gradients, text, cameras, scissoring, blending, render
  textures, and shaders.
- Loaded or generated textures, spritesheet animation, mutable pixel data, and
  exact projective texture drawing.
- Explicit executable-relative, working-directory, or external disk asset
  stores with optional manifest identity validation; see [asset stores](docs/assets.md).
- Keyboard, mouse, Unicode text, gamepad, and cursor input.
- Window and frame timing, startup entropy, the
  [`roc-random`](https://github.com/kili-ilo/roc-random) generator package, and
  file and environment access.
- Generated or loaded sound effects plus streamed music with playback controls.
- 2D math and collision helpers, geometric-algebra helpers used for 2D gameplay,
  and TMX tilemaps with culled drawing and object queries.
- Resizable, fullscreen, VSync, capped, or uncapped native windows on macOS,
  Linux, and Windows.
- Screenshots and recordings an app takes of itself, written as PNG, animated
  GIF, or VP8 video in a WebM container.

Browse the [API reference](https://lukewilliamboswell.github.io/roc-ray/) for
individual functions and types.

## Recording an app

An app can capture its own output, which makes it a way to generate
documentation assets and visualizations rather than only to play them. Declare a
recording in the startup config and it needs no code in `render!` at all:

```roc
App.init(
    App.default
    .with_output_dir("captures")
    # Render on the GPU with no window on screen, like a batch job.
    .with_visible(Bool.False)
    .with_recording(
        Record(
            Capture.default
            .with_path("demo.gif")
            .with_format(Gif)
            .with_fps(25)
            .with_max_frames(300),
        ),
    ),
    |_host| Ok({}),
)
```

`Capture.screenshot!`, `Capture.start!`, and `Capture.stop!` cover the cases
where the app decides when to capture. `Capture.set_virtual_mouse!` drives a
scripted pointer through the same input path a real one uses, so a recorded walk
through a UI exercises the app's ordinary hover and click handling.

Three things worth knowing:

- **Paths are sandboxed.** Every capture path resolves under `with_output_dir`.
  Absolute paths and paths containing `..` are refused rather than rewritten;
  this is the only file-writing capability the platform grants an app.
- **Recordings are reproducible.** `FixedStep` timing (the default) reports an
  exact `1/fps` frame delta regardless of how long the readback actually took,
  so a recording plays back smoothly and two runs produce identical output.
  Choose `RealTime` if you would rather see the true frame pacing.
- **A hidden window is not the same as `--headless`.** `with_visible(Bool.False)`
  still renders on the GPU, so captures work; it needs a display server, so wrap
  it in `xvfb-run` on a machine without one. The host's `--headless` flag swaps
  in a stub backend that draws nothing, so it captures nothing.

See `examples/capture_screenshot.roc`, `examples/capture_plot.roc`, and
`examples/capture_ui_demo.roc`.

Separately, note that raylib's own screen-capture shortcut is compiled into the
vendored library: pressing **F12** in any RocRay app writes `screenshotNNN.png`
into the process working directory. That predates this feature, bypasses
`with_output_dir`, and cannot be disabled without rebuilding raylib from source.

## Examples

For a small game, start with Pong, Snake, or Breakout:

```bash
roc build examples/pong.roc && ./pong
roc build examples/snake.roc && ./snake
roc build examples/breakout.roc && ./breakout
```

The larger showcase apps combine authored levels, sprites, sound, cameras, and
collision handling:

```bash
roc build examples/top_down.roc && ./top_down
roc build examples/cave_climb.roc && ./cave_climb
```

In Cave Climb, use A/D to move, W, Up, or Space to jump, the left mouse button
to fire the laser, and the right mouse button to use the hook.

The [example guide](examples/README.md) describes every app, what it teaches,
and a recommended learning path. It includes focused examples for responsive
UI, input, cameras, generated assets, projective textures, and post-processing.

## Supported systems

| System | Architecture |
| --- | --- |
| macOS | Intel and Apple Silicon |
| Linux | x64 (X11/XWayland or native Wayland bundle) |
| Windows | x64 |

ARM Linux is not currently included in release bundles.

## Contributing

Bug fixes, approachable APIs, documentation, examples, and well-scoped new
capabilities are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the
development setup, design principles, tests, and release tooling.
