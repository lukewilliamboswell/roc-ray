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
3. Read [Task Sleep](task_sleep/main.roc) once you need anything that waits: a
   file, a network reply, a screenshot. It is the whole task model in eighty
   lines.
4. Pick a direction: [Pixel Workshop](generated_assets/main.roc) for an
   interactive tool, [Responsive Settings](responsive_ui/main.roc) for an app
   interface, or [Snake](snake/main.roc) for a state-driven game.
5. Reach for a focused recipe only when your app needs that feature.

## Work that waits

`update!` calls host effects directly, and most of them answer at once. Work
that has to wait goes in `Task.spawn!(input, || ...)` instead: the closure runs
on its own coroutine while the frame loop keeps drawing, and its return value
arrives as a `Msg` on a later `input.messages`. These five are that idea, from
the smallest version to the largest.

| Example | What it is |
| --- | --- |
| [Task Sleep](task_sleep/main.roc) | One task, one `Task.sleep!`, one message back -- the shape of every other task on this page -- and printing done straight from `update!`, because a stream write queues rather than waits |
| [Async Read](async_read/main.roc) | Two file reads and a `Files.metadata!` in flight at once, each with its own `Msg` variant, so none of them needs an id |
| [Capture Screenshot](capture_screenshot/main.roc) | A screenshot encoded and written off the frame thread, and the output-directory sandbox refusing a path that escapes it |
| [HTTP Fetch](http_fetch/main.roc) | An HTTP GET on a task, re-fetchable mid-flight, with each reply carrying the id of the fetch it belongs to |
| [UDP Cursor](udp_cursor/main.roc) | Two instances showing each other's pointer: a receiving task restarted each time it answers, and sends made straight from `update!` |
| [SQLite Scores](sqlite_scores/main.roc) | A high-score board that survives a restart: the write and the re-read share one task, so the model is told what the database holds rather than guessing |

## Small apps worth copying

| Example | What it is | Patterns to reuse |
| --- | --- | --- |
| [Hello World](hello_world/main.roc) | A polished minimal interactive scene | App lifecycle, prepared text, pointer input, exiting from `update!` |
| [Pong](pong/main.roc) | A complete two-player arcade game | Delta-time movement, collision, scoring, generated audio |
| [Snake](snake/main.roc) | A grid-based game with restartable state | Fixed timestep, keyboard control, seeded randomness in the model |
| [Breakout](breakout/main.roc) | A complete game that can record its own demo | Separating game rules from effects, event-driven sound, CLI modes, capture |
| [Pixel Workshop](generated_assets/main.roc) | A tiny paint program with a mutable GPU texture | Generated assets, single-cell texture uploads, a pure editor returning edits |
| [Responsive Settings](responsive_ui/main.roc) | A resizable settings screen | Pure layout shared by `update!` and `render!`, mouse and keyboard navigation, minimum window size |
| [Postcard Studio](postcard_studio/main.roc) | A generative postcard editor that exports at twice the window size | Composing into an offscreen target, exporting a render texture from a task, output directories, status folded from a message |
| [Input Inspector](input_inspector/main.roc) | A practical device and clipboard diagnostic | Device snapshots, direct host effects, clipboard, live window reconfiguration |

## Larger showcases

| Example | What it demonstrates |
| --- | --- |
| [Live Plot](live_plot/main.roc) | A whole source tree walked with `Files.list!`, read and parsed through a backlog of tasks, and drawn as a scrolling strip of a quarter of a million lines under a fixed point budget that evicts and re-reads on demand |
| [Top Down](top_down/main.roc) | An authored TMX level, sprites, collision, music, sound effects, camera movement, and a multi-state game loop |
| [Cave Climb](cave_climb/main.roc) | Platforming physics, a mirror-bouncing laser and a spring grapple, tilemaps, camera tracking, and audio split across modules |

These are useful references once a project has outgrown its first feature. They
show how features fit together, but they are intentionally not the shortest
introduction to any individual API.

## Focused recipes

The recipes stay narrow so their unusual API is easy to find. They are not the
recommended starting point for a whole application.

| Example | Reach for it when you need... |
| --- | --- |
| [Camera World](camera/main.roc) | World/screen coordinate conversion, follow cameras, zoom, and rotation |
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
- Give each kind of deferred work its own `Msg` variant, which is identity
  enough. Only work that can be in flight against itself -- HTTP Fetch's `R`
  key -- needs to carry an id as well.
- Keep game or tool rules separate from rendering where that makes them easy to
  test, as Breakout does. `roc test` cannot call `update!`, so whatever you want
  covered has to live in a function that does not need a host.
- Treat capture, scripted input, and headless execution as useful app modes,
  not as branches inside ordinary interaction logic.

Exhaustive API probes and invalid-input cases belong in [`../test/`](../test/),
where they can be explicit without making an example harder to understand.
