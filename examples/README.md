# RocRay examples

These examples are applications first and API demonstrations second. Each one
has a concrete interaction or game loop, owns long-lived resources in its
model, and uses frame input to update state before drawing. Platform edge cases
and exhaustive API coverage belong in tests rather than in this directory.

Build from the repository root so asset paths resolve correctly:

```bash
roc build examples/snake.roc
./snake
```

## Learning path

| Example | Why it exists | Patterns to reuse |
| --- | --- | --- |
| `hello_world.roc` | Smallest visual starting point | `App.init`, prepared immutable text, frame-scoped drawing |
| `pong.roc` | Small continuous-motion game | delta-time movement, collision helpers, random serves, generated sound |
| `snake.roc` | Small discrete simulation | bounded fixed-step updates, list-backed state, input buffering |
| `breakout.roc` | Structured arcade game | pure game step, explicit events, effect handling at the boundary |
| `responsive_ui.roc` | Resizable settings screen | startup config, current logical size, prepared labels, cursor feedback, scissoring |
| `input_inspector.roc` | Input inspector utility | edge/held key state, Unicode input, mouse deltas, gamepad snapshots |
| `capture_screenshot.roc` | Smallest capture example | `Capture.screenshot!`, output-directory sandboxing |
| `capture_plot.roc` | Visualization rendered to a file | recording declared in startup config, hidden window, fixed-step timing |
| `capture_ui_demo.roc` | Self-recording UI walkthrough | scripted pointer through the real input path, drawn cursor overlay |
| `camera.roc` | Navigable world viewer | world/screen conversion, camera scope, screen-space HUD |
| `generated_assets.roc` | Tiny pixel editor | generated mutable texture, point sampling, palette input, procedural sound |
| `projective_texture.roc` | Perspective calibration tool | validated homography, interactive quad editing, projected overlays |
| `post_process.roc` | Post-processing scene | render texture ownership, nested blend scope, cached shader uniform |
| `top_down.roc` | Complete top-down game | TMX objects, culled tilemap drawing, sprites, music, camera, collision |
| `cave_climb.roc` | Complete platform game | authored levels, role-based tilemap queries, sprites, camera, 2D PGA physics |

The focused examples deliberately stop at one subsystem. The showcase games
demonstrate how the same APIs fit into larger state and resource lifecycles.

## Practices shown here

- Construct `App.Config` with receiver updates and create assets in `init!`.
- Keep textures, sounds, shaders, fonts, and prepared text in the model instead
  of loading or preparing them inside `render!`.
- Treat `step.input` as the current frame's snapshot. Derive plain game input
  from it; do not retain input snapshot lists in the model.
- Scale continuous motion by `step.time.elapsed_seconds`. For discrete
  simulation, clamp catch-up time and retain the fixed-step remainder.
- Update game state before drawing, and isolate effectful reactions to game
  events where the example is large enough to benefit from that split.
- Draw only through the supplied `Draw.Frame`; pass scoped frames into helpers
  and let fallible camera, scissor, shader, blend, and render-target scopes close
  before propagating errors.
- Prepare immutable labels once. Use direct text drawing for genuinely changing
  values such as scores, dimensions, and timers.
- Validate fallible geometry and resource setup at the boundary, then retain the
  validated value so the steady-state render path stays simple.

Asset licenses and attribution are stored beside third-party assets under
`examples/assets/`.
