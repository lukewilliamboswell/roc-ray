# RocRay

Build native games, visual tools, and interactive apps in
[Roc](https://www.roc-lang.org/), powered by
[raylib](https://www.raylib.com/).

RocRay is a focused app platform, not a game engine. Your app keeps its own
state and rules; RocRay provides drawing, audio, keyboard and mouse input,
windows, recording, files, and networking. It runs on macOS (Intel and Apple
Silicon), Linux x64, and Windows x64.

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

## Try it

Download the [0.10.0-rc3 example starter](https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/examples-0.10.0-rc3.zip)
and install its declared compiler,
[`nightly-2026-08-23-fb208ba`](https://github.com/roc-lang/nightlies/releases/tag/nightly-2026-08-23-fb208ba).
Unzip it, open a terminal in the extracted directory containing `examples/`, and run:

```bash
roc version
roc examples/hello_world/main.roc
```

## A whole app

```roc
app [Model, program] { rr: platform "<platform bundle URL from the release>" }

import rr.App
import rr.Color
import rr.Draw

Model : { frames : U64 }

Msg : []

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default.with_title("Hello"), |_io| Ok({ frames: 0 }))

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, _io| {
    if input.devices.key_pressed(KeyEscape) {
        Err(Exit(0))
    } else {
        Ok({ frames: model.frames + 1 })
    }
}

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |_model, frame| {
    frame.clear!(Color.black)
    frame.circle!({ center: { x: 400, y: 300 }, radius: 40, style: Draw.filled(Color.red) })
    Ok({})
}
```

`init!` creates the starting state, `update!` folds each frame's input into the
next state, and `render!` draws it. Work that waits, such as reading a file or
fetching a URL, runs as a task and reports back to a later `update!`. What an
app reaches beyond its own window -- the network, a directory, another program
-- is declared in its startup config.

## Documentation

The [RocRay manual](https://lukewilliamboswell.github.io/roc-ray/manual/) is
published as a website and a PDF. Its chapters are the AsciiDoc files in
[`docs/`](docs/), which you can also read here:

- [Getting started](docs/getting-started.adoc): install, run an example, and
  write the smallest app
- [Example gallery](docs/examples.adoc): what each example shows, and a
  learning path
- Guides: [the app model](docs/app-model.adoc), [input](docs/input.adoc),
  [drawing](docs/drawing.adoc), [tasks](docs/tasks.adoc),
  [declaring what an app reaches](docs/permissions.adoc),
  [files and assets](docs/files-and-assets.adoc), [audio](docs/audio.adoc),
  [HTTP and UDP](docs/networking.adoc), [capture](docs/capture.adoc),
  [testing](docs/testing.adoc), and [performance](docs/observatory.adoc)
- [API reference](https://lukewilliamboswell.github.io/roc-ray/)
- [Architecture](docs/architecture.adoc)
- [Contributing](docs/contributing.adoc)
- [Release notes](docs/releases/) and the
  [latest release](https://github.com/lukewilliamboswell/roc-ray/releases/latest)

RocRay follows Roc's new compiler closely, and its APIs may still change as the
language evolves. Bug reports, documentation improvements, approachable APIs,
and focused capabilities are welcome.
