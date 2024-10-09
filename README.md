# roc-raylib

Roc platform for graphics and GUI using [zig](https://ziglang.org) *version 0.13.0* and [raylib](https://www.raylib.com)

Also check out [this article](https://lukewilliamboswell.github.io/roc-ray-experiment/) for an overview of how I developed this platform.

## Building the platform locally

Use nix to setup the development environment - we need roc and zig

```sh
$ nix develop
```

Prebuild the platform host for roc to link with.

```sh
$ ./prebuild-host.sh
```

Run an example

```sh
roc examples/gui-counter.roc
```
