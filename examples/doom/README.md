# Libre Doom E1M1

This example is a complete, libre E1M1 vertical slice built from the pinned
Freedoom 0.13.0 Phase 1 WAD. Run it from the repository root:

```sh
roc examples/doom/main.roc
```

Controls are `W`/`S` or Up/Down to move, `A`/`D` or Left/Right to strafe,
mouse movement to turn, left mouse or Space to fire, and `E` to use doors and
switches. Number keys `2`, `3`, `4`, `5`, `6`, and `8` select owned weapons.
`R` restarts after death or exit; Escape quits.

`author_replay.roc` is the bounded offline authoring controller used to discover
a legal route. It is intentionally adaptive and is not regression evidence.
`DoomReplay.roc` contains the frozen 883-tic Baby-skill ordinary-command trace;
its tests replay those fixed commands through the normal runtime, assert the
exit/checkpoints/checksum, and compare host-cycle partitions.

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
