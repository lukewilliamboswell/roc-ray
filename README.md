# roc-raylib

Roc platform for graphics and GUI using [zig](https://ziglang.org) and [raylib](https://www.raylib.com)

🚧 Work in Progress 🚧 basic implementation, no release, still refining APIs, please explore and give any feedback or assistance 

Also check out [this article](https://lukewilliamboswell.github.io/roc-ray-experiment/) for an overview of how I developed this platform.

## Documenation

**Hosted** docs site coming soon.

**Generate** locally with `roc docs platform/main.roc` and then serve with file server e.g. `cd generated-docs &&  simple-http-server`.

## Developing Locally

Tested on *MacOS apple silicon* and *Ubuntu x64*, please let me know if this works on other systems.

**Build platform** using `bash build.sh`

**Run examples** with `roc dev --prebuilt-platform examples/basic_shapes.roc`

## Demo - GUI Counter

This is a minimal implementation of the Counter Example used in the [Action-State](https://docs.google.com/document/d/16qY4NGVOHu8mvInVD-ddTajZYSsFvFBvQON_hmyHGfo/edit?usp=sharing) design idea.

![GUI counter demo](/examples/gui-counter.gif)

## Demo - Pong

This is a demo of the classical [pong](https://en.wikipedia.org/wiki/Pong) video arcade game.

![pong demo](/examples/pong.gif)

