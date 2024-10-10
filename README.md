# roc-raylib

Roc platform for graphics and GUI using [zig](https://ziglang.org) *version 0.13.0* and [raylib](https://www.raylib.com)

Also check out [this article](https://lukewilliamboswell.github.io/roc-ray-experiment/) for an overview of how I developed this platform.

## Documentation

Checkout the docs site at [lukewilliamboswell.github.io/roc-ray](https://lukewilliamboswell.github.io/roc-ray/)

## Building the platform locally

Use nix to setup the development environment - we need roc and zig

```
$ nix develop
```

Prebuild the platform host for roc to link with.

```
$ ./prebuild-host.sh
```

Run an example

```
$ roc examples/gui-counter.roc
```

## Running the tests locally

Use nix to setup the development environment - we need roc and zig

```
$ nix develop
```

Run the tests

```
$ ROC=roc ZIG=zig bash ci/all_tests.sh
```
