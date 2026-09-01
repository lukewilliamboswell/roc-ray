# Writing a package for RocRay apps

This guide is for you if you are writing a Roc package that will be used by an
application running on RocRay—for example, a UI toolkit, renderer, layout
library, or game framework.

If you are writing a RocRay application, start with the
[example guide](../examples/README.md). If you are changing RocRay itself, read
[CONTRIBUTING.md](../CONTRIBUTING.md).

## The short version

There are three participants:

- **Your package** depends on `roc-ray-types`. It defines the higher-level API.
- **The app using your package** depends on RocRay and your package. It creates
  resources, starts tasks, and passes effects to your package.
- **RocRay** owns the window, frame, host resources, scheduling, and platform
  checks.

Here, an *effect* is simply a call that asks RocRay to do something outside
pure Roc code, such as draw or read a file.

If your package draws, its rendering function accepts one value:

```roc
draw! : Drawing.Effects, View => {}
```

The app turns its current frame into that value and passes it to your package:

```roc
# Inside render!
draw = App.effects().render(frame)
Toolkit.draw!(draw, view)
```

Your package does not import the RocRay platform and cannot access the host
unless the app passes an effect value to it. If your package also needs to wait
for work such as reading a file, the optional task section below adds that
second pattern.

## 1. Add `roc-ray-types` to your package

The package header depends on `roc-ray-types`, commonly named `rrt`:

```roc
package [Toolkit] {
    rrt: "../../roc-ray/types/main.roc",
}
```

Your package modules can then import the shared types they use:

```roc
import rrt.App
import rrt.Drawing
import rrt.Files
import rrt.Font
import rrt.Texture
```

The relative path above is useful while developing beside a RocRay checkout.
For a published package, use the released `roc-ray-types` bundle that matches
the RocRay release you support.

## 2. Write your package API

### A package that draws

Accept `Drawing.Effects` in the function that renders your package's view:

```roc
import rrt.Drawing

View : {
    panel : Drawing.RoundedRectangle,
    title : Drawing.Text,
}

Toolkit := [].{
    draw! : Drawing.Effects, View => {}
    draw! = |draw, view| {
        draw.rounded_rectangle!(view.panel)
        draw.text!(view.title)
    }
}
```

This one argument replaces a separate structural `where` constraint for every
drawing operation. Your package can use the standard shape, gradient, line,
text, texture, batch, projective-texture, and scissor helpers exposed by
`Drawing.Effects`.

### Optional: a package that waits for work

A package should define its own message type and expose a task body. It should
not need to know the application's `Msg`:

In `App.Effects(frame)`, `frame` is a type parameter saying which kind of frame
the effects can later bind. The root value does not contain a current frame.

```roc
import rrt.App
import rrt.Files

Msg : [ThemeLoaded(Try(Str, Files.ReadTextError))]

read_theme! : App.Effects(frame), Str => Try(Str, Files.ReadTextError)
read_theme! = |effects, path| effects.read_text!(path)

load_theme! : App.Effects(frame), Str -> (() => Msg)
load_theme! = |effects, path| || ThemeLoaded(effects.read_text!(path))
```

The direct function is useful during application initialization. The task body
is useful after the app has started, when waiting must not stop the frame loop.

## 3. Connect your package in the app

The application depends on RocRay and your package. It does **not** add its own
`roc-ray-types` dependency:

```roc
app [Model, program] {
    rr: platform "../../roc-ray/platform/main.roc",
    toolkit: "../package/main.roc",
    roc: "nightly-2026-08-31-86e69b4",
}

import rr.App
import toolkit.Toolkit
```

### Connect drawing

The app gets the configured effects value from RocRay. Inside `render!`, it
binds the current frame and calls your package:

```roc
app_effects = App.effects()

render! = |model, frame| {
    draw = app_effects.render(frame)
    Toolkit.draw!(draw, model.view)
    Ok({})
}
```

A framework that constructs the app's whole `program` can accept the effects
value once:

```roc
program = Toolkit.program(App.effects(), configure, init!, update!, view)
```

Its generated `render!` still calls `effects.render(frame)` for each current
frame. It stores only the unbound root value, never a frame or drawing handle.

### Connect initialization and tasks

During `init!`, a waiting effect may run directly and block startup:

```roc
theme_source = Toolkit.read_theme!(App.effects(), "theme.txt")?
```

After startup, the application starts the package's task body with its current
input and chooses how the package message fits into the app's `Msg`:

```roc
import rr.Task

effects = App.effects()
Task.spawn_with!(
    input,
    Toolkit.load_theme!(effects, "theme.txt"),
    |message| ToolkitMessage(message),
)
```

`spawn_with!` is the application boundary: your package owns its task and
message type; the app owns the `App.Input(msg)` required to start work and the
wrapper into its larger message type.

## Passing values and resources

RocRay re-exports the types from `roc-ray-types`. A value named `Text.Font` or
`Draw.Texture` in the app is the same nominal value your package names as
`rrt.Font` or `rrt.Texture`.

That means the app can load a font or texture and pass it directly to your
package:

```roc
# In the app
font = startup.default_font!()?
toolkit = Toolkit.init(font)
```

```roc
# In your package
init : Font -> Toolkit
```

No conversion, native handle, or manual cleanup API is needed. Your package may
retain the resource and use its pure information, such as font metrics or
texture dimensions. Loading, mutation, and other host operations still require
an effect supplied by the app.

For packages that need several resources, consider exposing a pure plan:

```roc
required_assets : Theme -> List(AssetRequest)

init : List(Texture), Font -> Toolkit
```

The app performs the loading during `init!`, then gives the results to your
package.

## Drawing inside a scope

Some drawing operations temporarily change the active host state. Scissoring
is the package-facing example. The callback receives the drawing value for that
scope; use it for every nested draw:

```roc
draw_panel! : Drawing.Effects, Panel => Try({}, [ScopeLimit])
draw_panel! = |draw, panel|
    draw.with_scissor!(
        panel.bounds,
        |scoped| {
            scoped.rectangle!(panel.background)
            draw_children!(scoped, panel.children)?
            Ok({})
        },
    )
```

Do not call the outer `draw` from inside the callback. A nested target can have
different dimensions and host state, so the callback's `scoped` value is the
one your recursive renderer must pass onward.

## Which effect value is which?

You can usually follow two simple rules:

1. A renderer accepts `Drawing.Effects`.
2. Code that creates task bodies or deliberately wraps RocRay's low-level API
   accepts `App.Effects(frame)`.

For reference:

| Value | What it represents | Keep it in package state? |
| --- | --- | --- |
| `App.Effects(frame)` in your package, or `App.Effects` in the app | RocRay-configured root effects, with no current frame or input | Yes |
| `Draw.Frame` in the app | One active host drawing target | No |
| `Drawing.Effects` in your package | Drawing bound to the current frame or nested scope | No |

`App.effects()` only constructs the unbound root value; it performs no host
operation. Calling `effects.render(frame)` binds a frame and returns the
drawing-only value.

Importing or naming any of these types does not create a working effect value.
Only the app's selected platform can configure one that reaches the host.

## When effects may run

RocRay checks the actual hosted operation even when your package wraps it:

| Operation | Where it may run |
| --- | --- |
| Drawing through `Drawing.Effects` | `render!` only |
| Waiting `read_text!` | `init!`, where it blocks, or a task, where it parks |
| Pure package code | Anywhere ordinary pure Roc code may run |

An invalid call stops the application with a programmer error naming the
effect, phase, and fix. External conditions such as a missing file remain typed
results.

Application callbacks and task bodies run serially on the frame thread. A
waiting effect parks its task so frames can continue; long pure computation in
a task still blocks the frame loop.

## Local development and releases

During local development, point both projects at the same checkout:

- Your package points `rrt` at that checkout's `types/main.roc`.
- The integration app points its platform at that checkout's
  `platform/main.roc`.
- Use the Roc compiler version in that checkout's `.roc-version`.

This matters because Roc package types have nominal identity. Two packages with
the same source but different resolved package identities may not unify.

For releases, publish `roc-ray-types` first, then publish the RocRay platform
that references that exact package bundle. A downstream package should pin the
matching released types package; its application should pin the matching
RocRay platform and compiler.

## Advanced: defining a different drawing API

Most renderers should accept `Drawing.Effects`. If your package deliberately
offers a different drawing model, it can combine the root value with an
explicit frame and call the root's lower-level receivers:

```roc
Alternative(frame) :: {
    effects : App.Effects(frame),
    frame : frame,
}.{
    from_effects : App.Effects(frame), frame -> Alternative(frame)
    from_effects = |effects, frame| Alternative.({ effects, frame })

    panel! : Alternative(frame), Panel => {}
    panel! = |Alternative.({ effects, frame }), panel| {
        effects.shape!(frame, panel.geometry, SolidFill(panel.color))
        effects.draw_text!(frame, panel.label)
    }
}
```

The application creates this facade only inside `render!`:

```roc
Alternative.from_effects(App.effects(), frame).panel!(panel)
```

Choose this only when your package needs to replace the canonical drawing API,
not merely compose its helpers.

## Checklist

- Your package depends on `roc-ray-types`, not the RocRay platform.
- The app depends on RocRay and your package, with no separate types dependency.
- The app loads host resources and passes them to your package unchanged.
- Rendering functions accept `Drawing.Effects`.
- Recursive scoped drawing passes the callback's drawing value onward.
- Package tasks return the package's message type; the app calls
  `Task.spawn_with!` and supplies the wrapper.
- Frames and `Drawing.Effects` are never stored for later use.
- Local platform and package dependencies resolve the same `roc-ray-types`.

The executable integration coverage for these patterns lives in
[`test/package_interop`](../test/package_interop/README.md).
