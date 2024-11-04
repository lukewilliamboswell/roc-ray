# Roc Ray Graphics Platform

[Roc](https://www.roc-lang.org) platform for building graphics applications, like games and simulations, while using the [Raylib](https://www.raylib.com) graphics library.

We aim to provide a nice experience for the hobby developer or a small team who wants to build a game or graphical application in Roc.

**Status** - Early development, not yet ready for production use. We are looking for contributors to help build out the platform and examples. If you find a bug or have a feature request, please open an issue or start a thread in the [roc zulip](https://roc.zulipchat.com/) where you can find us.

## Features

- Write games using Roc, the Fast, Friendly, and Functional programming language
- Cross-platform support for Linux, macOS, Windows, and Web
- Simple API for 2D graphics (3D coming soon)
- Built on the awesome Raylib library
- Designed for beginners, hobby developers and small teams

## Documentation

Checkout the docs site at [lukewilliamboswell.github.io/roc-ray](https://lukewilliamboswell.github.io/roc-ray/)

## Example

(requires cloning the repository locally)

```roc
app [Model, init!, render!] { rr: platform "../platform/main.roc" }

import rr.RocRay
import rr.Draw

width = 800
height = 600

Model : {}

init! : {} => Result Model []
init! = \{} ->

    RocRay.initWindow! { title: "Basic Shapes", width, height }

    Ok {}

render! : Model, RocRay.PlatformState => Result Model []
render! = \_, {} ->

    Draw.draw! White \{} ->
        Draw.text! { pos: { x: 10, y: 10 }, text: "Hello World!", size: 40, color: Navy }
        Draw.rectangle! { rect: { x: 100, y: 150, width: 250, height: 100 }, color: Aqua }
        Draw.rectangleGradientH! { rect: { x: 400, y: 150, width: 250, height: 100 }, left: Lime, right: Navy }
        Draw.rectangleGradientV! { rect: { x: 300, y: 250, width: 250, height: 100 }, top: Maroon, bottom: Green }
        Draw.circle! { center: { x: 200, y: 400 }, radius: 75, color: Fuchsia }
        Draw.circleGradient! { center: { x: 600, y: 400 }, radius: 75, inner: Yellow, outer: Maroon }
        Draw.line! { start: { x: 100, y: 500 }, end: { x: 500, y: 500 }, color: Red }

    Ok {}
```

![basic shapes example](examples/demo-basic-shapes.png)

## Getting Started

### Clone the repository

In future we should be able to provide prebuilt-binaries that work with the Roc cli and writing apps is as simple as `roc run app.roc`, but for now to get started you will need to clone the repository.

```
$ git clone https://github.com/lukewilliamboswell/roc-ray.git
```

### Linux and MacOS

*Required dependencies*
1. Install [roc](https://www.roc-lang.org)
2. Install [rust](https://www.rust-lang.org/tools/install)
3. Install dev tools on linux `sudo apt install build-essential git` or on macOS `xcode-select --install`
4. Install [just](https://github.com/casey/just) `cargo install just`
5. Install [watchexec](https://github.com/watchexec/watchexec) `cargo install watchexec-cli`

Run an example:

```
$ just dev examples/pong.roc
```

**OR**

*Currently broken - Help Wanted*

Use the [nix package manager](https://nixos.org/download/) to install the dependencies

```
$ nix develop
$ just dev examples/pong.roc
```

### Windows

1. Ensure you have [cargo](https://www.rust-lang.org/tools/install) in your path.
2. Install [just](https://github.com/casey/just?tab=readme-ov-file#packages)
3. Run `just setup` to download a windows build of Roc

Run an example:

```
PS > just dev .\examples\pong.roc
```

The unofficial Windows release of roc can be manually downloaded at [lukewilliamboswell/roc/releases/tag/windows-20241011](https://github.com/lukewilliamboswell/roc/releases/tag/windows-20241011)

```
PS > roc version
roc built from commit b5e3c3e441 with additional changes, committed at 2024-10-09 11:34:35 UTC
```

### Web

*Required dependencies*
1. As above for native
2. Install [zig](https://ziglang.org)
3. Install [emscripten](https://emscripten.org)
4. Install simple-http-server `cargo install simple-http-server`

```
$ just web examples/pong.roc
```

## Contributing

To run the tests locally:

```
$ ./ci/all_tests.sh
```

We are exploring how we can make a nice API for Roc and experimenting with different ideas, not quite a 1-1 mapping of the raylib API. We hope to find a nice balance between Roc's functional and Raylib's imperative style.

This platform is young, and there is a lot of work to do. You are welcome to contribute ideas or PR's, please let us know if you have any questions or need help.
