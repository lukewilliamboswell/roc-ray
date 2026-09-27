# RocRay

Build native games, visual tools, and interactive apps in
[Roc](https://www.roc-lang.org/), powered by
[raylib](https://www.raylib.com/).

RocRay is a focused app platform, not a game engine. Your app keeps its own
state and rules; RocRay provides drawing, audio, keyboard and mouse input,
windows, recording, files, and networking. It runs on macOS (Intel and Apple
Silicon), Linux x64, and Windows x64.

The platform includes the complete RocRay API: value types, pure helpers, and
host effects are documented and released together. Import them through your
platform dependency, such as `rr.App`, `rr.Math`, and `rr.Assets`.

## See what it can do

These nine apps span small games, designed levels, creative tools, responsive
interfaces, and scenes with thousands of moving objects. Each tile links to its
complete Roc source; the [example guide](examples/README.md) covers the rest and
suggests a learning path.

<table>
  <tr>
    <td align="center"><a href="examples/cave_climb/main.roc"><img src="examples/gallery/cave_climb.webp" alt="Cave Climb gameplay" width="260"><br><strong>Cave Climb</strong></a><br>Designed level, jumping, camera, sound</td>
    <td align="center"><a href="examples/breakout/main.roc"><img src="examples/gallery/breakout.webp" alt="Breakout gameplay" width="260"><br><strong>Breakout</strong></a><br>Arcade rules, sounds made in code, recording</td>
    <td align="center"><a href="examples/capture_ui_demo/main.roc"><img src="examples/gallery/capture_ui_demo.webp" alt="A scripted responsive interface demonstration" width="260"><br><strong>Capture UI</strong></a><br>Automated controls and GIF recording</td>
  </tr>
  <tr>
    <td align="center"><a href="examples/top_down/main.roc"><img src="examples/gallery/top_down.webp" alt="Top Down gameplay" width="260"><br><strong>Top Down</strong></a><br>Designed map, characters, music, game states</td>
    <td align="center"><a href="examples/generated_assets/main.roc"><img src="examples/gallery/generated_assets.webp" alt="Painting in Pixel Workshop" width="260"><br><strong>Pixel Workshop</strong></a><br>Drawing pixels and creating sounds in code</td>
    <td align="center"><a href="examples/postcard_studio/main.roc"><img src="examples/gallery/postcard_studio.webp" alt="An animated postcard composition" width="260"><br><strong>Postcard Studio</strong></a><br>Generative art and saving larger images</td>
  </tr>
  <tr>
    <td align="center"><a href="examples/responsive_ui/main.roc"><img src="examples/gallery/responsive_ui.webp" alt="Navigating the responsive settings interface" width="260"><br><strong>Responsive Settings</strong></a><br>Keyboard, mouse, resizing, display scaling</td>
    <td align="center"><a href="examples/live_plot/main.roc"><img src="examples/gallery/live_plot.webp" alt="Source files appearing in Live Plot" width="260"><br><strong>Live Plot</strong></a><br>Loading and drawing hundreds of thousands of lines</td>
    <td align="center"><a href="examples/particles/main.roc"><img src="examples/gallery/particles.webp" alt="A moving fountain of particles" width="260"><br><strong>Particles</strong></a><br>Thousands of moving images at once</td>
  </tr>
</table>

The capture examples also produce deterministic media directly, including this
[WebM plot recording](examples/gallery/capture_plot.webm).

For performance investigation, [RocRay Observatory](docs/observatory.md)
records host-cycle summaries and opt-in application annotations to a bounded,
queryable SQLite `.rrstats` capture.

## Try it

Download the [0.10.0-rc3 example starter](https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/examples-0.10.0-rc3.zip)
and install its declared compiler,
[`nightly-2026-08-23-fb208ba`](https://github.com/roc-lang/nightlies/releases/tag/nightly-2026-08-23-fb208ba).
Unzip it, open a terminal in the extracted directory containing `examples/`, and run:

```bash
roc version
roc examples/hello_world/main.roc
```

Each starter includes immutable platform URLs and the matching compiler in its
application headers. The header records the requirement; it does not install
or select the compiler. Run from the extracted directory so asset paths resolve.
Use `roc build` when producing an executable for distribution.

Choose a starting point from the [example guide](examples/README.md). The
[platform release](https://github.com/lukewilliamboswell/roc-ray/releases/tag/0.10.0-rc3)
contains the tested downloads; the platform's development compiler can be newer.

`main` contains development source, including examples of unreleased APIs.
To run those against the checkout, follow [Contributing](CONTRIBUTING.md) and use
`scripts/run-example.py examples/hello_world`. Development checks rebind temporary
copies to the platform source and its compiler, while published starters keep
their own pins.

## The programming model

A RocRay app provides three functions:

- `init!` runs once. It sets the window options, loads what the app needs, and
  creates the starting state.
- `update!` handles input such as keys and mouse movement, then returns the next
  state.
- `render!` draws that state on the screen.

`init!` receives `App.Io`; the update signature is
`update!(model, input, io)`. Select a service and call its receivers:

```roc
# In init! or a task: a directory handle, kept in the model.
saves = io.files().app_data!()?
response = io.http().send!(request)?

# In update!: hand the handle to a task.
Task.spawn!(input, || Loaded(saves.read_text!("slot1.json")))
```

Files are always reached through a directory handle like `saves`, never an
ambient path: `io.files()` opens the app's private storage (named by
`App.default.with_app_id`), the directory beside the executable, or a
directory the app declared.

Every app can draw, read input, play audio, print to stdout and stderr, write
captures under its output directory, and read the directory beside its
executable. Reaching further -- a network origin, a directory, a program, an
environment variable, the clipboard -- is declared in the startup config, and
the declaration is the grant:

```roc
config =
    App.default
    .with_permission(HttpOrigin("https://api.example.com"))
    .with_permission(Directory("saves", ReadWrite))
```

There are no launch flags for this: what an app can reach is written in its
source. A target outside every declared scope returns `PermissionDenied`, and
using a facility the app never declared stops it with a message naming the
declaration to add. This is platform policy that holds because Roc code can
only act through the platform; it is not an operating-system sandbox.

Reading a file or waiting for a network reply can take time. Start that work as
a task so the app can keep updating and drawing; when it finishes, `update!`
receives the result.

Read [`hello_world/main.roc`](examples/hello_world/main.roc) for the smallest
complete app, then choose a project from the
[example guide](examples/README.md). The
[API reference](https://lukewilliamboswell.github.io/roc-ray/) documents the
available features and functions.

Configure a shared startup font when one font serves most of the app. Loading
a font file reads the working directory, so it needs that declared; the
built-in font does not:

```roc
config =
    App.default
    .with_default_font({ path: "assets/body.ttf", size: 32 })
    .with_permission(Directory("assets", ReadOnly))
font = io.default_font!()?
```

`Text.Font` carries both its opaque host handle and an immutable metric
snapshot, so `font.measure(...)` is pure.

## Project links

- [Examples and learning path](examples/README.md)
- [API reference](https://lukewilliamboswell.github.io/roc-ray/)
- [Latest release](https://github.com/lukewilliamboswell/roc-ray/releases/latest)
- [Architecture](design.md)
- [Contributing](CONTRIBUTING.md)

RocRay follows Roc's new compiler closely, and its APIs may still change as the
language evolves. Bug reports, documentation improvements, approachable APIs,
and focused capabilities are welcome.
