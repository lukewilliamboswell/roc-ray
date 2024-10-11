# roc-raylib

Roc platform for graphics and GUI using [zig](https://ziglang.org) *version 0.13.0* and [raylib](https://www.raylib.com)

Also check out [this article](https://lukewilliamboswell.github.io/roc-ray-experiment/) for an overview of how I developed this platform.

## Documentation

Checkout the docs site at [lukewilliamboswell.github.io/roc-ray](https://lukewilliamboswell.github.io/roc-ray/)

## Building and Run

### Linux and MacOS - Nix Package Manager

Using nix package manager to setup a development environment with roc and zig

```
$ nix develop
```

Run an example

```
$ ./build-and-run.sh examples/pong.roc
```

**Running the tests locally**

```
$ ./ci/all_tests.sh
```

### Windows

Ensure you have [zig 0.13.0](https://ziglang.org/download/) and roc in your path. I've made an unofficial Windows release of roc available at [lukewilliamboswell/roc/releases/tag/windows-20241011](https://github.com/lukewilliamboswell/roc/releases/tag/windows-20241011)

```
PS > zig version
0.13.0
PS > roc version
roc built from commit b5e3c3e441 with additional changes, committed at 2024-10-09 11:34:35 UTC
```

Run an example

```
PS > .\build-and-run.ps1 examples\pong.roc
```

Note if you would like to use a different version of zig, you can set the `ZIG` environment variable to the path of the zig executable.

```
PS > set ZIG=C:\path\to\zig.exe
```
