# RocRay Platform

A [Roc platform](https://www.roc-lang.org/platforms) for creating simple native graphics applications and games, built on [raylib](https://www.raylib.com/).

![Running the hello world example](examples/hello-world-demo.gif)

RocRay is an **experimental platform** that supports research and development of the Roc compiler. Its aim is to make simple games that demonstrate the benefits of the Roc language and of platform development. We expect the ideas here to be expanded in future, and contributions are welcome.

The goal isn't to build or support a large game engine. We're happy to help where it advances those aims — see [CONTRIBUTING.md](CONTRIBUTING.md) if you'd like to get involved.

> **Work in Progress:** This platform targets the new Roc compiler and Zig 0.16. Expect breaking changes and incomplete functionality.

> **Performance:** For the best performance, run your app with `roc build` (e.g. `roc build examples/breakout.roc`) rather than `roc <file>`. `roc build` uses the optimised LLVM backend, while running directly uses the in-development backends. This is expected to be a temporary limitation while the dev backends mature.

### Frame pacing

`target_fps` and `vsync` control different parts of frame pacing:

- `target_fps` asks raylib to limit the frame loop on the CPU. Set it to `0` (or a negative value) to render uncapped. This does not select a software renderer; native drawing remains GPU accelerated.
- `vsync` asks the graphics driver to synchronize buffer presentation with the display. The driver, window system, and desktop compositor ultimately decide how that request behaves.

RocRay defaults to `vsync: Bool.False` with a 240 FPS CPU-side cap. This gives predictable behavior across platforms while keeping CPU and GPU usage bounded. Enable VSync when tear-free presentation is more important and it behaves well on the target system.

Some Linux configurations—particularly X11 applications presented through a Wayland compositor—can run substantially below the monitor refresh rate when VSync is enabled. Increasing `target_fps` cannot correct presentation stalls inside the driver. If this occurs, use `vsync: Bool.False` with a suitable software cap such as 60 or 120 FPS. Use an uncapped target for measurement rather than normal application operation, since it needlessly consumes CPU and GPU resources.

## Features

- 2D drawing primitives (styled rectangles, rounded rectangles, circles, lines, triangles, polygons, gradients, text)
- Asset loading for host-owned textures, with source/destination rectangles, arbitrary quadrilateral projection, rotation, origin, scale, and tint
- Pure 2D camera values with scoped world-space drawing
- Sprite helpers for spritesheet frames and simple frame-rate-based animation
- 2D math and collision helpers (Vec2, Rect, Circle, clamp, lerp, normalize, contains, overlaps)
- Tiled TMX tilemap loading, drawing, layer/object roles, solid queries, and object/property access
- Physics helpers backed by compact 3D PGA points, vectors, planes, lines, and translation motors
- RGBA colors with named constants, RGB/RGBA constructors, and hex helpers
- Explicit FPS/debug text drawing
- Text measurement, alignment helpers, long-string rendering, and custom font loading
- Mouse and keyboard input handling
- Per-frame logical screen dimensions for resize-aware rendering and UI layout
- Loaded sound effects and generated procedural sounds with volume, pitch, and pan
- Streamed music playback with host-managed per-frame updates
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

Beginner game examples:

```bash
roc build examples/snake.roc && ./snake
roc build examples/breakout.roc && ./breakout
roc build examples/top_down.roc && ./top_down
roc build examples/cave_climb.roc && ./cave_climb
```

The top-down demo uses a Tiled-authored TMX map and selected CC0 assets from Kenney's Topdown Shooter, Impact Sounds, and Music Jingles packs; asset licenses are included under [`examples/assets/`](examples/assets/).

The cave climber demonstrates TMX tile layers, object roles, sprite sheets, camera following, and Physics distance checks with selected CC0 assets from Kenney's New Platformer Pack.

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
