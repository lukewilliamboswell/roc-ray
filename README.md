# RocRay Platform

A [Roc platform](https://www.roc-lang.org/platforms) for creating simple native graphics applications and games, built on [raylib](https://www.raylib.com/).

![Running the hello world example](examples/hello-world-demo.gif)

RocRay is an **experimental platform** that supports research and development of the Roc compiler. Its aim is to make simple games that demonstrate the benefits of the Roc language and of platform development. We expect the ideas here to be expanded in future, and contributions are welcome.

The goal isn't to build or support a large game engine. We're happy to help where it advances those aims — see [CONTRIBUTING.md](CONTRIBUTING.md) if you'd like to get involved.

> **Work in Progress:** This platform targets the new Roc compiler and Zig 0.16. Expect breaking changes and incomplete functionality.

> **Performance:** For the best performance, run your app with `roc build` (e.g. `roc build examples/breakout.roc`) rather than `roc <file>`. `roc build` uses the optimised LLVM backend, while running directly uses the in-development backends. This is expected to be a temporary limitation while the dev backends mature.

### Frame pacing

`App.Config` is opaque, so contradictory startup states cannot be created with a
record update. Choose exactly one tagged `App.FramePacing` strategy:

- `VSync` asks the graphics driver to synchronize presentation with the display.
- `Capped(fps)` asks raylib to limit the frame loop on the CPU. A cap at or below
  zero is normalized to `Uncapped`.
- `Uncapped` applies neither VSync nor a CPU-side cap. Native drawing remains GPU
  accelerated.

RocRay defaults to an 800×600 window, `Capped(240)`, and `CursorVisible`.
Update the validated config through receivers:

```roc
config = App.default
	.with_title("My game")
	.with_size({ width: 1280, height: 720 })
	.with_resizable(Bool.True)
	.with_fullscreen(Bool.False)
	.with_frame_pacing(Capped(120))
	.with_cursor(CursorHidden)
```

Non-positive width or height values independently normalize to the default 800
or 600, so the opaque `Config` always agrees with the dimensions the host uses.

The startup cursor choice is independently tagged as `CursorVisible` or
`CursorHidden`; runtime visibility and capture still use
`host.set_cursor_mode!` with `Visible`, `Hidden`, or `Locked`. Some Linux
configurations—particularly X11 applications presented through a Wayland
compositor—can run substantially below the monitor refresh rate under VSync. In
that case prefer `Capped(60)` or `Capped(120)`. Use `Uncapped` for measurement,
not normal operation, because it needlessly consumes CPU and GPU resources.

## Features

- 2D drawing primitives (styled rectangles, rounded rectangles, circles, lines, triangles, convex polygons, gradients, text) and callback-scoped camera/scissor modes
- Loaded and procedurally generated host-owned textures, with full-pixel updates, filter/wrap controls, source/destination rectangles, arbitrary quadrilateral projection, rotation, origin, scale, and tint
- Host-owned render textures and shaders, cached typed uniforms, and scoped shader/blend/offscreen drawing for 2D post-processing
- Pure 2D camera values with scoped drawing and world/screen transforms
- Sprite helpers for spritesheet frames and simple frame-rate-based animation
- 2D math and collision helpers (Vec2, Rect, Circle, clamp, lerp, normalize, contains, overlaps)
- Tiled TMX tilemap loading, viewport-culled drawing, orthogonal tile flips, O(1) world-to-cell lookup, bounded solid queries, layer/object roles, and object/property access
- Physics helpers backed by compact 3D PGA points, vectors, planes, lines, and translation motors
- RGBA colors with named constants, RGB/RGBA constructors, and hex helpers
- Explicit FPS/debug text drawing
- Text measurement, alignment helpers, long-string rendering, and custom font loading
- Mouse, keyboard, Unicode text-entry, and allocation-free connected-gamepad input snapshots
- Mouse delta/two-axis wheel input and runtime cursor visibility, locking, and shapes
- Per-frame logical screen dimensions for resize-aware rendering and UI layout
- Loaded sound effects and generated procedural sounds with playback state, pause/resume/stop, volume, pitch, and pan
- Streamed music playback with host-managed per-frame updates, seeking, timing, and playback state
- Native rendering via raylib (macOS, Linux, Windows)

## Requirements

- [Zig](https://ziglang.org/download/) 0.16.0
- [Roc](https://www.roc-lang.org/) nightly available as `roc` on `PATH`

## Quick Start

First, build the platform and cross-compile the pre-built host libraries for all supported targets:

```bash
zig build
```

Then build and run the hello world example:

```bash
roc build examples/hello_world.roc
./hello_world
```

> Use `roc build` (rather than `roc examples/hello_world.roc`) for the best performance — see the note above.

Every render callback receives the current input snapshot and an opaque drawing
capability:

```roc
render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, host, frame| {
	frame.clear!(Color.ray_white)
	if host.key_pressed(KeyEscape) host.exit!(0)
	frame.circle!({ center: host.mouse.position(), radius: 24, style: Draw.filled(Color.blue) })
	Ok(model)
}
```

The host opens and closes raylib's outer drawing scope around `render!`, even
when it returns `Err`. `Draw.Frame` is opaque, zero-sized drawing authority that
applications cannot construct, so initialization code cannot draw. Roc does not
yet enforce affine use or encode a frame epoch, so pass the callback's frame
through drawing helpers instead of retaining it in the model. This also removes
the two hosted BeginDrawing/EndDrawing boundary calls that `Draw.draw!`
previously made every frame.

### Receiver and scoped drawing APIs

Use receivers for values you already have and attached constructors for new
resources. Module functions remain useful for constructors and pure helpers
that do not have a natural receiver.

```roc
camera = Camera.follow(player, { screen: screen_size, zoom: 1.5 })?
mouse_world = camera.screen_to_world(host.mouse.position())

frame.with_camera!(camera, |world_frame| {
	world_frame.circle!({ center: player, radius: 20, style: Draw.filled(Color.red) })
	Ok({})
})?

frame.with_scissor!(hud_bounds, |clipped_frame| {
	clipped_frame.text_at!({ pos: hud_pos, text: "status", size: 18, color: Color.white })
	Ok({})
})?
```

Camera, scissor, blend, shader, and render-target callbacks return `Try`. Their
matching end operation runs before either `Ok` or callback `Err` is returned.
All five scope families can nest and restore the outer state. Handle
`ScopeLimit` when the fixed native scope stack is full. Shader and render-target
scopes additionally report `ScopeUnavailable` when a transferred host resource
cannot be resolved; value-only camera, scissor, and blend scopes do not expose
that impossible state. A failed begin never runs its callback.

### Prepared and dynamic text

Prepare immutable labels during initialization so measurement, UTF-8 to native
NUL-terminated storage, and loaded-font ownership are paid once:

```roc
label = Text.from("Start Game").size(28).font(font).prepare!()?
size = label.bounds()

# In render!:
label.draw!(frame, {
	pos: { x: 400, y: 240 },
	color: Color.white,
	align: Text.align_center,
})
```

`Text.Prepared` is an ARC host resource. Every draw crosses the host boundary
with only its typed handle, position, and color; it does not transfer the source
`Str`, remeasure, convert to a C string, or allocate. The prepared value retains
its loaded font, so the original font binding may leave scope safely. Handle
`ResourceLimit` when the bounded heap or native text storage is exhausted. For
scores, chat, and other changing content, keep using the direct `frame.text!`
API rather than creating a short-lived prepared value each frame.

### Host-owned textures, render targets, and shaders

`Assets.Texture` owns a mutable ordinary texture. Its dimensions, pixel update,
filter, wrap, and sampling-view operations are receivers:

```roc
texture = Assets.Texture.load!("examples/assets/checker.bmp")?
texture.set_filter!(Bilinear)
texture.set_wrap!(Clamp)
bounds = texture.rect()
sampled = texture.view()
```

`Assets.TextureView` is a distinct sampled/read-only capability with no pixel
update method. It is a zero-cost nominal view sharing the same host-owned ARC
resource, not a copied image or a newly allocated wrapper. Render targets expose
only this sampled view:

```roc
target = Draw.RenderTexture.load!({ width: 800, height: 600 })?
sampled = target.texture()
source = target.source() # full, vertically inverted source rectangle
```

Resolve typed shader uniforms during initialization and retain them in the
model. Each uniform caches its native location and keeps its shader alive;
per-frame `.set!` calls do not repeat a name lookup or allocate.

```roc
shader = Draw.Shader.load!({ vertex_path: "", fragment_path: "examples/assets/post_process.fs" })?
time = shader.uniform_f32!("time")?

# In render!:
time.set!(seconds)
frame.with_shader!(shader, |shader_frame| {
	shader_frame.texture!(target_draw)
	Ok({})
})?
```

Typed handles are available for `F32`, `I32`, `Vec2`, `Vec3`, `Vec4`, color,
and sampled-texture uniforms, so the wrong setter is rejected by Roc.

## Interaction snapshots

`Host` carries one input snapshot per frame. Keyboard, mouse-button, and up to
four gamepad states use persistent flat lists that are updated by the host and
queried in pure Roc; checking several controls does not make several host calls.
Receiver and module dispatch are equivalent, for example
`host.key_pressed(KeySpace)` and `Keys.key_pressed(host, KeySpace)`.

Resolve gamepad connectivity once, then use the proven connected receiver for
all button and axis queries:

```roc
match host.gamepad(One) {
	Connected(pad) => if pad.button_pressed(FaceDown) { jump() }
	Disconnected => {}
}
```

`ConnectedPad` only references the existing snapshot lists. Lookup and its
button, axis, and stick methods neither allocate nor resample the device. It is
a view of that frame's snapshot: query it immediately and do not retain it in
the model, because retaining old snapshot lists triggers copy-on-write next
frame.

`host.text_input` contains the Unicode codepoints entered during the frame. It
tracks text entry and the active keyboard layout, unlike physical key state.
The host reuses a variable-length list with copy-on-write when an older snapshot
is retained, so ordinary empty and non-empty frames allocate nothing. Up to 32
codepoints are delivered per frame; additional queued input is drained.
`host.mouse.delta()` and `host.mouse.wheel_delta()` return the sampled movement
vectors; the equivalent `Mouse.*` helpers remain available. Apply visibility
and capture atomically with `host.set_cursor_mode!(Visible)` (or `Hidden` or
`Locked`), and select an operating-system shape with
`host.set_cursor!(PointingHand)`.

`camera.world_to_screen(point)` and `camera.screen_to_world(point)` perform the
same 2D transform used by `frame.with_camera!` without crossing the host
boundary. Cameras are opaque and always invertible: constructors and receiver
updates reject zero zoom and every non-finite target, offset, rotation, or zoom
with a dedicated validation error instead of constructing an invalid camera.

Tilemap builders validate that each parsed tileset has exactly one bound
texture, reject unused bindings, and reject unknown, duplicate, or overlapping
layer/object role targets, including distinct name/type rules matching one
object. Handle the composable errors from `.build()` during initialization.
Tile drawing requires the current frame capability. The built value retains
flat render metadata and texture owners, so each public draw operation borrows
those existing lists in one host call without constructing a per-frame batch.

## Examples

Sprite and texture drawing:

```bash
roc build examples/sprites.roc
./sprites
```

World-space camera drawing:

```bash
roc build examples/camera.roc
./camera
```

Generated and mutable textures plus sound transport controls:

```bash
roc build examples/generated_assets.roc
./generated_assets
```

Offscreen rendering, additive blending, and fragment-shader post-processing:

```bash
roc build examples/post_process.roc
./post_process
```

Beginner game examples:

```bash
roc build examples/snake.roc && ./snake
roc build examples/breakout.roc && ./breakout
roc build examples/top_down.roc && ./top_down
roc build examples/cave_climb.roc && ./cave_climb
```

The top-down demo uses a Tiled-authored TMX map and selected CC0 assets from Kenney's Topdown Shooter, Impact Sounds, and Music Jingles packs; asset licenses are included under [`examples/assets/`](examples/assets/).

The cave climber demonstrates TMX tile layers, object roles, sprite sheets, camera following, and Physics distance checks with selected CC0 assets from Kenney's New Platformer Pack.

For large maps, pass the visible world rectangle to the culled drawing API so
the host visits only the intersecting range:

```roc
frame.with_camera!(camera, |world_frame| {
	level.tilemap.draw_all_for_camera!(world_frame, camera, screen_size)
	Ok({})
})?
```

If bounds are already available, use `map.draw_all_in!(world_frame, world_view)`;
both forms make one boundary call for the complete selected range. Role-based
drawing accepts only `Tilemap.DrawRole` (`Drawn` or `Solid`); draw a hidden layer
deliberately by naming it with `draw_layer!` or `draw_layer_in!`.

Use `frame.with_scissor!(screen_rect, |clipped_frame| { ...; Ok({}) })?` for paired
screen-space clipping. Filled polygon points must describe a simple convex
boundary; use `frame.convex_polygon!` to make that requirement explicit.

## Migrating to the receiver API

- Change `render! : Model, Host => ...` to
  `render! : Model, Host, Draw.Frame => ...`.
- Remove `Draw.draw!(background, || ...)`; call `frame.clear!(background)` and
  draw through `frame`.
- Change static calls such as `Draw.circle!(cfg)`,
  `Keys.key_pressed(host, key)`, and
  `Camera.screen_to_world(camera, point)` to `frame.circle!(cfg)`,
  `host.key_pressed(key)`, and `camera.screen_to_world(point)` where the
  receiver is clearer.
- Pass the callback frame through camera, scissor, blend, shader, and
  render-target scopes instead of closing over an unscoped drawing API. Return
  `Try` from each callback and propagate `ScopeLimit`; shader/render-target
  scopes can additionally return `ScopeUnavailable`.
- Replace `Assets.load_texture!`/`Assets.update_texture!` with
  `Assets.Texture.load!`/`texture.update!`; use `texture.view()` or
  `target.texture()` wherever only sampling is required.
- Replace `Draw.uniform!` plus `Draw.set_uniform_f32!` with
  `shader.uniform_f32!` during initialization and `uniform.set!` during
  rendering. Choose the matching typed uniform constructor.
- Replace direct `Draw.RenderTexture` helpers with
  `Draw.RenderTexture.load!`, `target.texture()`, and `target.source()`.
- Replace `{ ..App.default, title: ..., target_fps: ..., cursor_visible: ... }`
  with opaque config receivers such as `.with_title(...)`,
  `.with_frame_pacing(Capped(...))`, and `.with_cursor(CursorHidden)`. Choose one
  of `VSync`, `Capped(fps)`, or `Uncapped` rather than combining pacing fields.

## Supported Targets

| Target | Description |
|--------|-------------|
| x64mac | macOS Intel |
| arm64mac | macOS Apple Silicon |
| x64glibc | Linux x64 |
| x64win | Windows x64 |

- We vendor the pre-compiled libraries from [raylib v6.0](https://github.com/raysan5/raylib/releases/tag/6.0)
- The default Linux bundle uses raylib's X11 build. A separate Linux x64 Wayland bundle can be created with `scripts/bundle.sh --platform wayland` after building `vendor/raylib/linux-x64-wayland/libraylib.a`.
- ARM Linux is not available (raylib doesn't provide pre-built libraries)

## Contributing

RocRay exists to push on Roc compiler and platform development, so contributions that serve those aims are very welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to build the platform, run the test suite, regenerate glue bindings, and bundle a release.
