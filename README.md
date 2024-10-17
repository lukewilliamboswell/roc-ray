# Roc Ray Graphics Platform

[Roc](https://www.roc-lang.org) platform for building graphics applications, like games and simulations, using the [Raylib](https://www.raylib.com) graphics library.

## Documentation

Checkout the docs site at [lukewilliamboswell.github.io/roc-ray](https://lukewilliamboswell.github.io/roc-ray/)

## Example

(requires cloning the repo locally)
```roc
app [main, Model] { ray: platform "../platform/main.roc" }

import ray.RocRay

width = 800
height = 600

Model : {}

main : RocRay.Program Model []
main = { init, render }

init =

    RocRay.setWindowSize! { width, height }
    RocRay.setWindowTitle! "Basic Shapes"

    Task.ok {}

render = \_, _ ->

    RocRay.drawText! { text: "Hello World", x: 300, y: 50, size: 40, color: Navy }
    RocRay.drawRectangle! { x: 100, y: 150, width: 250, height: 100, color: Aqua }
    RocRay.drawRectangleGradient! { x: 400, y: 150, width: 250, height: 100, top: Lime, bottom: Green }
    RocRay.drawCircle! { x: 200, y: 400, radius: 75, color: Fuchsia }
    RocRay.drawCircleGradient! { x: 600, y: 400, radius: 75, inner: Yellow, outer: Maroon }

    Task.ok {}
```

![basic shapes example](examples/demo-basic-shapes.png)

## Building and Run

### Linux and MacOS

*Required dependencies*
1. Install [roc](https://www.roc-lang.org)
2. Install [rust](https://www.rust-lang.org/tools/install)
3. Install dev tools on linux `sudo apt install build-essential git` or on macOS `xcode-select --install`

Run an example:

```
$ ./build-and-run.sh examples/pong.roc
```

**OR**

Use the [nix package manager](https://nixos.org/download/) to install the dependencies

```
$ nix develop
$ ./build-and-run.sh examples/pong.roc
```

### Windows

Ensure you have [roc](https://www.roc-lang.org) and [cargo](https://www.rust-lang.org/tools/install) in your path.

Unofficial Windows release of roc available at [lukewilliamboswell/roc/releases/tag/windows-20241011](https://github.com/lukewilliamboswell/roc/releases/tag/windows-20241011)

```
PS > roc version
roc built from commit b5e3c3e441 with additional changes, committed at 2024-10-09 11:34:35 UTC
```

Run an example

```
PS > .\build-and-run.ps1 examples\pong.roc
```

## Contributing

To run the tests locally:

```
$ ./ci/all_tests.sh
```
