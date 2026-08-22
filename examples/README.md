# Example gallery

These examples are small applications first and API demonstrations second.
Choose one that resembles what you want to build, copy its directory, and keep
the model/update/render shape as the project grows.

Build from the repository root so asset paths resolve consistently:

```bash
roc build examples/snake/main.roc --output snake
./snake
```

## A good first hour

1. Start with [Hello World](hello_world/main.roc) to see the complete app loop
   without asset loading or game rules.
2. Change [Pong](pong/main.roc) to learn time-based movement, collision, input,
   scoring, and generated sound in one approachable file.
3. Pick a direction: [Pixel Workshop](generated_assets/main.roc) for an
   interactive tool, [Responsive Settings](responsive_ui/main.roc) for an app
   interface, or [Snake](snake/main.roc) for a state-driven game.
4. Reach for a focused recipe only when your app needs that feature.

## Small apps worth copying

| Example | What it is | Patterns to reuse |
| --- | --- | --- |
| [Hello World](hello_world/main.roc) | A polished minimal interactive scene | App lifecycle, prepared text, pointer input, exiting from `update!` |
| [Pong](pong/main.roc) | A complete two-player arcade game | Delta-time movement, collision, scoring, generated audio |
| [Snake](snake/main.roc) | A grid-based game with restartable state | Discrete simulation, keyboard control, deterministic updates |
| [Breakout](breakout/main.roc) | A complete game that can record its own demo | Separating game rules from effects, event-driven sound, CLI modes, capture |
| [Pixel Workshop](generated_assets/main.roc) | A tiny paint program with a mutable GPU texture | Generated assets, palette tools, texture updates, feedback sounds |
| [Responsive Settings](responsive_ui/main.roc) | A resizable settings screen | Pure layout, mouse and keyboard navigation, minimum window size |
| [Postcard Studio](postcard_studio/main.roc) | A generative postcard editor and PNG exporter | Screenshot requests, output directories, async success feedback |
| [Input Inspector](input_inspector/main.roc) | A practical device and clipboard diagnostic | Device snapshots, typed messages, direct window effects, clipboard requests |

## Larger showcases

| Example | What it demonstrates |
| --- | --- |
| [Live Plot](live_plot/main.roc) | A whole source tree walked with `Files.list`, read and parsed through a paced request queue, and drawn as a scrolling strip of a quarter of a million lines under a fixed point budget that evicts and re-reads on demand |
| [Top Down](top_down/main.roc) | An authored TMX level, sprites, collision, music, sound effects, camera movement, and a multi-state game loop |
| [Cave Climb](cave_climb/main.roc) | Platforming physics, animation, tilemaps, camera tracking, audio, and mouse-driven tools split across modules |

These are useful references once a project has outgrown its first feature. They
show how features fit together, but they are intentionally not the shortest
introduction to any individual API.

## Focused recipes

The recipes stay narrow so their unusual API is easy to find. They are not the
recommended starting point for a whole application.

| Example | Reach for it when you need... |
| --- | --- |
| [Camera World](camera/main.roc) | World/screen coordinate conversion, follow cameras, zoom, and rotation |
| [Async Read](async_read/main.roc) | Non-blocking text and byte reads with typed completion messages |
| [Task Sleep](task_sleep/main.roc) | A coroutine task that sleeps without stalling the frame (spike) |
| [HTTP Fetch](http_fetch/main.roc) | An HTTP GET on a task, with the frame still animating while the reply is in flight |
| [Projective Texture](projective_texture/main.roc) | A draggable perspective-correct quad and projected overlay points |
| [Post Process](post_process/main.roc) | Render textures, blend scopes, shaders, and cached uniform locations |
| [Particles](particles/main.roc) | Thousands of sprites drawn as one batched instance list rather than one call each |
| [Capture Plot](capture_plot/main.roc) | A deterministic hidden-window WebM batch render |
| [Capture UI Demo](capture_ui_demo/main.roc) | Reproducible UI recordings driven through the real input path |

## What these examples consider good practice

- Keep application state in `Model`; fold `App.Input` into it in pure helpers that `update!` calls.
- Load and prepare long-lived resources once in `init!`, then retain them in the
  model instead of recreating them each frame.
- Derive layout and view-only values with pure helpers rather than storing
  duplicate state that can drift out of sync. Ask `frame.size!()` for the
  surface being drawn to instead of copying `input.window.size` into the model:
  it is current, and inside `with_render_texture!` it is the target's size
  rather than the window's.
- Call host effects directly from `update!` for work that answers immediately;
  use `Task.spawn!(input, || ...)` for work that waits, and fold its return
  value in when it arrives as a message on a later `input.messages`.
- Keep game or tool rules separate from rendering where that makes them easy to
  test, as Breakout does.
- Treat capture, scripted input, and headless execution as useful app modes,
  not as branches inside ordinary interaction logic.

Exhaustive API probes and invalid-input cases belong in [`../test/`](../test/),
where they can be explicit without making an example harder to understand.
