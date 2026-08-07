# Companion types package spike

Tests whether RocRay's public data types can live in an ordinary Roc package
that both the platform and reusable third-party packages depend on. Without
this, any pure `Host`-to-framework translation is stuck inside the application,
because a package cannot import from the app's chosen platform.

`Keys`, `Mouse`, `Gamepad`, and `Time` move to `package/`; the platform depends
on it and re-exports each under the same name, so `exposes` and every existing
app are unchanged.

## Layout

- `input_adapter/` — a package depending **only** on `roc-ray-types`, never on
  the platform.
- `app.roc` — runs on the platform and passes it the platform's `Host`,
  `host.mouse`, `host.gamepads`, and a re-exported `KeyboardKey`, then feeds the
  returned key back into `rr.Keys.key_code`.

It compiles only if those are the same nominal types on both sides. Give
`input_adapter` a look-alike local key type instead and it fails, so this is
shared identity rather than structural unification.

```bash
roc check test/package_interop/app.roc
roc build test/package_interop/app.roc && ./app --headless
```

## The constraint

The platform must depend on a **released** build of the package. A relative path
does not survive `roc bundle`: the archive is written without the package and
without any error, then fails at the consumer with `INVALID PACKAGE DEPENDENCY`.

Pointing both platform headers at a bundled package URL fixes it — verified
locally over HTTP, with the platform bundle test passing and all examples
building against it. Bundle the package from inside its own directory
(`cd package && roc bundle main.roc`) or the archive paths are nested one level
too deep for roc to resolve.

Release order is therefore: publish the types package, pin its URL in
`platform/main.roc` and `platform/main-wayland.roc`, then release the platform.
The committed source keeps relative paths so local development works before
anything is published.
