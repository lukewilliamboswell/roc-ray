# Libre Doom E1M1

This example is a complete, libre E1M1 vertical slice built from the pinned
Freedoom 0.13.0 Phase 1 WAD. While developing RocRay, run it against the local
platform source from the repository root:

```sh
scripts/run-example.py examples/doom/main.roc
```

The checked-in application header still names the last published release,
which predates the 3D API used here. The release workflow now verifies this
example against a release-shaped bundle; the direct `roc examples/doom/main.roc`
command becomes valid when that bundle is published and the header is updated.

Controls are `W`/`S` or Up/Down to move, `A`/`D` or Left/Right to strafe,
mouse movement to turn, left mouse or Space to fire, and `E` to use doors and
switches. Number keys `2`, `3`, `4`, `5`, `6`, and `8` select owned weapons.
`R` restarts after death or exit; Escape quits.

`author_replay.roc` is the bounded offline authoring controller used to discover
a legal route. It is intentionally adaptive and is not regression evidence.
`DoomReplay.roc` contains the frozen 789-tic Baby-skill ordinary-command trace;
its single full-route test replays those fixed commands through the normal
runtime and asserts the exit, checkpoints, final state, and checksum. The
shorter `DoomTrace.roc` test proves host-cycle partition invariance without
doubling the several-minute full replay.

Regenerate and verify the pinned assets as described in
[`assets/freedoom/README.md`](assets/freedoom/README.md). Run the focused tests
with:

```sh
scripts/all_tests.py --only doom --skip-platform-build
```

For the local release-bundle gate (including a staged consumer and bounded
headless execution), first build target archives with `zig build`, then run:

```sh
scripts/all_tests.py --only doom --skip-platform-build --skip-roc-test \
    --skip-bundle-test --skip-interop-test --skip-integration-probes \
    --platform-mode=bundle --skip-windowed --headless-frames=3
```

Fidelity scope, reference policy, and intentional departures are recorded in
[`FIDELITY.md`](FIDELITY.md). No commercial Doom data is used or required.
