# RocRay Platform

A [Roc platform](https://www.roc-lang.org/platforms) for creating simple graphics applications.

> **Work in Progress:** This branch (`new-compiler`) is actively porting features from the `main` branch while upgrading to new Roc semantics. Expect breaking changes and incomplete functionality.

## Features

- 2D drawing primitives (rectangles, circles, lines, text)
- Mouse input handling (position, buttons, wheel)
- Cross-platform support (macOS, Linux, Windows, Web/WASM)
- Native rendering via raylib, web rendering via Canvas 2D

## Requirements

- [Zig](https://ziglang.org/download/) 0.15.2 or later
- [Roc](https://www.roc-lang.org/)

## Running Examples

First, build the platform and cross-compile the pre-built host libraries for all supported targets:

```bash
zig build
```

Then run an example:

```bash
roc examples/hello_world.roc
```

For web/WASM, build with the wasm32 target and serve the files:

```bash
roc build --target=wasm32 examples/hello_world.roc
```

Helper scripts are available to build and serve WASM:

```bash
# Linux/macOS
./build_wasm.sh examples/hello_world.roc

# Windows (PowerShell)
.\build_wasm.ps1 examples\hello_world.roc
```

## Testing

Run Zig unit tests and WASM integration tests:

```bash
zig build test
```

Run all Roc example tests (check, format, test, build, simulation):

```bash
python3 ci/all_tests.py
```

Enable the pre-commit hook (run once after cloning):

```bash
git config core.hooksPath .githooks
```

## Simulation Testing

RocRay includes a simulation recording and replay system for deterministic testing of graphical applications. This enables regression testing without requiring a display—useful for CI environments.

### How It Works

1. **Record** a session while running the app normally—inputs (mouse position, buttons, frame count) and outputs (draw commands) are captured to a `.rrsim` file
2. **Replay** the session visually to debug or inspect what was recorded
3. **Test** headlessly by re-running the app with recorded inputs and verifying outputs match

### Environment Variables

| Variable | Description |
|----------|-------------|
| `SIM_RECORD=path.rrsim` | Record session to file |
| `SIM_REPLAY=path.rrsim` | Replay visually |
| `SIM_TEST=path.rrsim` | Headless test mode (verify Roc app behaviour) |
| `SIM_LOG=path.log` | Write all mismatches to file (no limit) |

### Recording a Session

```bash
# Build and run the app with recording enabled
roc build examples/hello_world.roc
SIM_RECORD=examples/hello_world_1.rrsim ./examples/hello_world

# Interact with the app, then close the window
# The .rrsim file is written on exit
```

### Running Simulation Tests

```bash
# Headless verification—exits 0 if outputs match, 1 if mismatch
SIM_TEST=examples/hello_world_1.rrsim ./examples/hello_world

# With full mismatch log for debugging
SIM_TEST=examples/hello_world_1.rrsim SIM_LOG=mismatches.log ./examples/hello_world
```

In CI, simulation tests run automatically for any `.rrsim` files found in `examples/`. The naming convention `<app>_<n>.rrsim` maps to `<app>.roc`.

## Bundling

```bash
./bundle.sh
```

This creates a `.tar.zst` bundle containing all `.roc` files and prebuilt host libraries. To use a Roc package bundle it should be hosted online with a `https:` url.

## Supported Targets

| Target | Description |
|--------|-------------|
| x64mac | macOS Intel |
| arm64mac | macOS Apple Silicon |
| x64glibc | Linux x64 |
| x64win | Windows x64 |
| wasm32 | Web/WASM |

- We vendor the pre-compiled libraries from [raylib v5.5](https://github.com/raysan5/raylib/releases/tag/5.5)
- ARM Linux is not available (raylib doesn't provide pre-built libraries)

## Future Ideas

- Extend simulation recording/replay/testing to WASM target for browser-based deterministic testing
