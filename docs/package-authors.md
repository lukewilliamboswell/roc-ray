# Building reusable packages on RocRay

RocRay separates shared API vocabulary from host authority so a reusable Roc
package can provide layout, rendering, input, asset-planning, or other
higher-level APIs without depending on its application's platform.

The package depends on `roc-ray-types`. The application depends on RocRay and
the reusable package. The application supplies any authority the package needs:

```text
application             reusable package              RocRay host
App.effects()  ───────► App.Effects(frame)
       │
       └─ render(frame) ───────► Drawing.Effects ─────► drawing effects
```

Importing `roc-ray-types` creates no host authority. It contains vocabulary and
opaque effect interfaces, but no hosted declarations and no way to mint a live
frame, resource, startup token, or task. Only a value configured by the
application's platform can reach the host.

## Dependencies and names

A package imports the companion package under a name such as `rrt`:

```roc
package [Renderer, Toolkit] {
    rrt: "../../roc-ray/types/main.roc",
}
```

Its modules name shared types through that dependency:

```roc
import rrt.App
import rrt.Drawing
import rrt.Font
import rrt.Texture
```

The application imports only the platform and the reusable package:

```roc
app [Model, program] {
    rr: platform "../../roc-ray/platform/main.roc",
    toolkit: "../package/main.roc",
    roc: "nightly-2026-08-31-86e69b4",
}

import rr.App
import rr.Draw
import rr.Text
import toolkit.Toolkit
```

Do not add a second `roc-ray-types` dependency to the application. RocRay
transparently re-exports package-owned types, so the app's `Text.Font`,
`Draw.Texture`, `Devices.Snapshot`, and `App.Input(msg)` are the same nominal
types a package names as `rrt.Font`, `rrt.Texture`, `rrt.Devices.Snapshot`, and
`rrt.App.Input(msg)`.

For a published package, replace the local `rrt` path with the released
`roc-ray-types` bundle matched by the RocRay release. During sibling-checkout
development, use the same local `types/main.roc` from which the local platform
is built. Two look-alike package builds may create different nominal identities.

## Values, resources, and authority

A package can freely accept and retain ordinary package-owned values. This
includes input snapshots, geometry, colors, cameras, font metrics, textures,
and other opaque resource handles. The package can use their pure receivers;
only the platform can construct or mutate host-owned resources.

Prefer pure plans at startup. For example, a toolkit can return a list of asset
requests, then accept the loaded fonts and textures from the application:

```roc
required_assets : Theme -> List(AssetRequest)

init : List(Texture), Font -> Toolkit
```

This keeps `App.Startup`, platform configuration, and loading policy in the
application. Create long-lived resources once during `init!` and retain them in
the application or package state rather than loading them per frame.

When a package must call the host synchronously, the application can instead
inject the configured root effect handle.

## The two effect handles

| Name in a package | Purpose | May be retained? | Who supplies it? |
| --- | --- | --- | --- |
| `App.Effects(frame)` | Phase-neutral root containing configured low-level and waiting effects | Yes; it contains no frame or input | The application, from platform `App.effects()` |
| Platform `Draw.Frame` | Host-minted authority for one active render target | No; use it only in the callback or scope that supplied it | RocRay calls the application's `render!` or a platform drawing scope |
| `Drawing.Effects` | Canonical drawing API bound to the current frame or nested drawing scope | No; use it synchronously inside that render scope | `effects.render(frame)` or a drawing-scope callback |

The application-side platform alias `App.Effects` fixes the hidden `frame`
parameter to RocRay's `Draw.Frame`. A reusable package sees the parameterized
companion-package type because it does not import that platform.

`App.effects()` performs no host work. It returns configured functions and is
safe to retain or capture in a task body. `effects.render(frame)` binds the
current explicit frame and produces the narrower drawing-only handle.

## A canonical rendering package

A renderer should normally accept `Drawing.Effects` directly:

```roc
import rrt.Drawing

Renderer := [].{
    draw! : Drawing.Effects, View => Try({}, [ScopeLimit])
    draw! = |draw, view| {
        draw.rounded_rectangle!(view.panel)
        draw.text!(view.title)
        Ok({})
    }
}
```

The application-facing adapter accepts the root handle once. It binds each
frame inside `render!` and hands the resulting drawing capability to the
renderer:

```roc
Program := [].{
    new = |effects, configure, init!, update!, view| {
        render! = |model, frame| {
            draw = effects.render(frame)
            Renderer.draw!(draw, view(model))
        }

        {
            init!: { config: configure, run!: init! },
            update!,
            render!,
        }
    }
}
```

The application makes the authority transfer explicit:

```roc
program = Program.new(App.effects(), configure, init!, update!, view)
```

This is preferable to repeating structural `where` constraints for every draw
operation. It gives the package one documented capability contract and keeps
the platform dependency at the application boundary.

## Scoped drawing

Drawing scopes such as scissoring substitute a nested drawing capability while
host state is active. Always continue with the handle passed to the callback:

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

Do not use or retain the outer `draw` inside that callback. Nested targets may
have different dimensions and host state, and the supplied `scoped` handle is
the authority for exactly that scope.

The current scissor receiver has the fixed callback shape
`Drawing.Effects => Try({}, [ScopeLimit])`. This reflects a compiler limitation
around generalized result and open-error variables stored in the private effect
record, not a different ownership protocol.

## Waiting effects and tasks

The root handle also supports package-owned waiting effects. A package may
expose both a direct operation for initialization and a task body in its own
message type, without knowing the application's `Msg`:

```roc
import rrt.App
import rrt.Files

Msg : [ThemeLoaded(Try(Str, Files.ReadTextError))]

read_theme! : App.Effects(frame), Str => Try(Str, Files.ReadTextError)
read_theme! = |effects, path| effects.read_text!(path)

load_theme! : App.Effects(frame), Str -> (() => Msg)
load_theme! = |effects, path| || ThemeLoaded(effects.read_text!(path))
```

During `init!`, the application may call that function directly, where the read
blocks startup:

```roc
theme_source = Toolkit.read_theme!(App.effects(), "theme.txt")?
```

During the orderly application lifetime, work that waits belongs in a task.
The application owns the `App.Input(msg)` witness, starts the task, and chooses
the message wrapper:

```roc
effects = App.effects()
Task.spawn_with!(
    input,
    Toolkit.load_theme!(effects, "theme.txt"),
    |message| ToolkitMessage(message),
)
```

The package must not manufacture an input, spawn work without the application's
message witness, or ask the host to retain an arbitrary callback. `spawn_with!`
lets the task answer in the package's own message type while the application
chooses how to wrap it. The task body returns exactly one message; scheduling,
parking, shutdown, and payload bounds remain platform-owned.

Application callbacks and task bodies remain serial on the frame thread.
Waiting parks a task so frames can continue; long pure computation inside the
task still blocks the frame loop.

## Alternative package APIs

A package with a deliberately different drawing model can accept the same root
and explicit frame instead of using the canonical high-level receivers:

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

The application constructs that facade only while it has a frame:

```roc
Alternative.from_effects(App.effects(), frame).panel!(panel)
```

Use this form when the package intentionally owns a different drawing API.
Packages that merely compose RocRay's standard helpers should accept
`Drawing.Effects` instead.

## Phase and ownership rules

The root handle is phase-neutral. Its type does not hide operations that are
invalid in the current callback, because Roc values are not affine and a
retained phase-shaped handle would not prove correct use. RocRay remains the
semantic authority:

| Operation | Legal phases |
| --- | --- |
| Drawing through `Drawing.Effects` | `render!` only |
| Waiting `read_text!` | `init!`, where it blocks, or a task, where it parks |
| Pure package receivers | Any pure Roc code |

An invalid hosted call fails immediately as a programmer error naming the
effect, phase, and fix. Runtime conditions such as a missing file remain typed
outcomes. Package receivers call their injected delegates synchronously; the
host never retains, schedules, or resumes those delegates.

Keep these boundaries intact:

- The application owns `App.Config`, `App.Startup`, `App.Input(msg)`, task
  spawning, and `Draw.Frame`.
- The package owns its domain API, state, pure algorithms, and higher-level
  effect receivers.
- RocRay owns hosted primitives, phase checks, resource bounds, scope
  restoration, scheduling, and backends.

## Package-author checklist

- Depend on `roc-ray-types`, never the application-selected platform.
- Keep the application free of a separate `roc-ray-types` dependency.
- Accept shared package types directly; do not copy or translate host-resource
  handles.
- Prefer pure startup plans and application-loaded resources.
- Accept `Drawing.Effects` for the canonical rendering path.
- Accept `App.Effects(frame)` plus a frame only for a deliberately different
  facade or for a root effect such as `read_text!`.
- Bind frames only inside `render!`.
- Propagate callback-supplied scoped effects through recursive drawing.
- Let the application provide the task message witness and wrapper.
- Test local platform and package builds together so their nominal identities
  cannot drift.

The executable source of truth for these boundaries is
[`test/package_interop`](../test/package_interop/README.md). It compiles a
types-only input adapter, canonical and alternative renderers, scoped drawing,
resource round trips, a waiting effect, and an application that depends only on
the platform and those packages.
