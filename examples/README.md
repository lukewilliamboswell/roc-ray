# RocRay examples

Each directory here is a complete app with a `main.roc`. Run every command
from the directory that contains `examples/`, so the paths the examples use
for their files resolve.

In a repository checkout, each example uses the platform in the checkout, so
run `zig build` once first. The examples zip attached to each release points
them at that release instead, and needs no checkout.

To try an example, run it with `roc`:

```bash
roc examples/hello_world/main.roc
```

To build an executable you can run again, use `roc build`:

```bash
roc build examples/hello_world/main.roc --output=hello_world
./hello_world
```

Start with these, in order:

1. `hello_world` -- the app loop, drawing, and the pointer
2. `move_box` -- moving by elapsed time, with a tested pure rule
3. `sprite_and_sound` -- a permission, an asset store, a picture and a sound
4. `pong` -- one player against a computer paddle
5. `snake` -- a grid game across a few modules
6. `task_sleep` -- a task that waits and the message it sends back

The [example gallery](https://lukewilliamboswell.github.io/roc-ray/manual/#examples)
in the RocRay manual describes every example, what it demonstrates, and where
to go next; its source is [`docs/examples.adoc`](../docs/examples.adoc).
