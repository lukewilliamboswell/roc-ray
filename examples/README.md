# Example gallery

A zip of the examples pinned to this release is attached to every release;
unzip and `roc examples/<name>/main.roc`.

Choose the closest example to what you want to build and copy its directory.

Build from the repository root so asset paths resolve consistently:

```bash
roc build examples/snake/main.roc --output snake
./snake
```

## Start here

1. Start with [Hello World](hello_world/main.roc) to see the complete app loop
   without asset loading or game rules.
2. Change [Pong](pong/main.roc) to learn time-based movement, collision, input,
   scoring, and generated sound in one approachable file.
3. Read [Task Sleep](task_sleep/main.roc) before adding files, networking, or
   any other work that waits.
4. Pick a direction: [Pixel Workshop](generated_assets/main.roc) for an
   interactive tool, [Responsive Settings](responsive_ui/main.roc) for an app
   interface, or [Snake](snake/main.roc) for a state-driven game.
5. Reach for a focused recipe only when your app needs that feature.

## Work that waits

Use these when copying the `Task.spawn!(input, || ...)` pattern. A task's return
value arrives as one `Msg` on a later `input.messages`.

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
| [Responsive Settings](responsive_ui/main.roc) | A resizable settings screen | Pure layout shared by `update!` and `render!`, mouse and keyboard navigation, minimum window size, DPI scale and monitor placement |
| [Postcard Studio](postcard_studio/main.roc) | A generative postcard editor that exports at twice the window size | Composing into an offscreen target, exporting a render texture from a task, output directories, status folded from a message |
| [Input Inspector](input_inspector/main.roc) | A practical device and clipboard diagnostic | Device snapshots, direct host effects, clipboard, live window reconfiguration, an eyedropper reading the pixel under the pointer |
| [Drop Viewer](drop_viewer/main.roc) | An image viewer whose only control is dropping a file on it | `input.dropped`, reading an absolute path in a task, choosing a decoder from the bytes themselves, a bounded input source reporting its overflow |

## Larger showcases

| Example | What it demonstrates |
| --- | --- |
| [Live Plot](live_plot/main.roc) | A whole source tree walked with `Files.list!`, read and parsed through a backlog of tasks, and drawn as a scrolling strip of a quarter of a million lines under a fixed point budget that evicts and re-reads on demand |
| [Top Down](top_down/main.roc) | An authored TMX level, sprites, collision, music, sound effects, camera movement, and a multi-state game loop |
| [Cave Climb](cave_climb/main.roc) | Platforming physics, a mirror-bouncing laser and a spring grapple, tilemaps, camera tracking, and audio split across modules |
| [RocDOOM E1M1](roc-doom-e1m1/main.roc) | A Doom-compatible game built over pinned Freedoom E1M1 data, with a fixed-tic simulation, BSD-tree rendering, enemies, combat and line specials |

Use these to see several systems composed in one application.

## Focused recipes

Use these as focused references, not starter projects.

| Example | Reach for it when you need... |
| --- | --- |
| [Camera World](camera/main.roc) | World/screen coordinate conversion, follow cameras, zoom, and rotation |
| [Projective Texture](projective_texture/main.roc) | A draggable perspective-correct quad and projected overlay points |
| [Post Process](post_process/main.roc) | Render textures, blend scopes, shaders, and cached uniform locations |
| [Particles](particles/main.roc) | Thousands of sprites drawn as one batched instance list rather than one call each |
| [Capture Plot](capture_plot/main.roc) | A deterministic hidden-window WebM batch render |
| [Capture UI Demo](capture_ui_demo/main.roc) | Reproducible UI recordings driven through the real pointer and keyboard path |

## Conventions used here

- Keep application state in `Model`; fold `App.Input` into it in pure helpers that `update!` calls.
- Load and prepare long-lived resources once in `init!`, then retain them in the
  model instead of recreating them each frame.
- Derive layout and view-only values with pure helpers. Use `frame.size!()` for
  the active surface instead of copying `input.window.size` into the model.
- Call host effects directly from `update!` for work that answers immediately;
  use `Task.spawn!(input, || ...)` for work that waits, and fold its return
  value in when it arrives as a message on a later `input.messages`.
- Give each kind of deferred work its own `Msg` variant. Add an id only when
  multiple instances of the same work may be in flight.
- Keep rules in pure functions so `roc test` can exercise them without calling
  effectful `update!`.
- Treat capture, scripted input, and headless execution as useful app modes,
  not as branches inside ordinary interaction logic.

Exhaustive API probes and invalid-input cases belong in [`../test/`](../test/),
where they can be explicit without making an example harder to understand.
