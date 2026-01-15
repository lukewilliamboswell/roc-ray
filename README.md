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

```bash
zig build test
```

This runs both Zig unit tests and WASM integration tests.

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
