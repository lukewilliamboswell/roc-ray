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
`DoomReplay.roc` contains a frozen Baby-skill ordinary-command trace;
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

## Profiling performance

Profile a deterministic workload before changing code. Use the same compiler,
build mode, binary, host flags, and frame count for the before and after runs.
The headless spawn workload is a useful first pass because it is repeatable;
also record a scripted movement or combat workload when investigating costs
that depend on nearby active enemies. `--host-keys` can supply those inputs
(for example, `--host-keys=3:W,4:W+SPACE`). Keep the script fixed while
comparing implementations.

Build with debug information using the compiler under test. `--debug` is
important even when the suspected problem is pure Roc code, because generated
procedure names otherwise cannot be mapped reliably to their source module:

```sh
ROC=~/roc_nightly-linux_x86_64-2026-08-23-fb208ba/roc
$ROC build examples/doom/main.roc --debug --output=/tmp/doom-profile
/usr/bin/time -f 'elapsed=%e user=%U sys=%S' \
    /tmp/doom-profile --host-headless --host-headless-frames=500
```

Run the timing command several times and use the stable range, not a single
best result. Then sample the exact same binary with Linux `perf`:

```sh
perf record -F 999 -g --call-graph dwarf -o /tmp/doom-perf.data -- \
    /tmp/doom-profile --host-headless --host-headless-frames=500
perf report --stdio --no-children --sort=symbol -i /tmp/doom-perf.data
```

Roc procedures currently appear as names such as `roc__proc_f884`. Resolve a
dominant procedure's start address back to a module and line with `nm` and
`addr2line`, and use `perf annotate` when the start line covers several source
expressions:

```sh
nm -n /tmp/doom-profile | rg 'roc__proc_f884'
addr2line -f -C -e /tmp/doom-profile 0xADDRESS
perf annotate --stdio -i /tmp/doom-perf.data roc__proc_f884
```

Treat the reported line as the start of an evidence trail rather than proof
that the expression on that line is itself faulty. Check its callers and the
size and frequency of the collections it traverses. In particular, look for
work repeated per host cycle, simulation tic, actor, sector, or linedef; an
innocent `List.any`, `List.prepend`, or `memcpy` often exposes an unnecessarily
repeated traversal or a large captured record.

Measure allocation traffic separately. The host flag has no metering cost when
absent and reports total and `update!` allocation per cycle when enabled:

```sh
/tmp/doom-profile --host-alloc-stats --host-headless \
    --host-headless-frames=500
ROC=~/roc_nightly-linux_x86_64-2026-08-23-fb208ba/roc \
    scripts/test_doom_performance.py --frames 500
```

The script is the repository's bounded performance gate; direct output is more
useful when comparing idle, active-enemy, and unusually expensive cycles.
Allocation reductions support a diagnosis, but elapsed time and samples decide
whether a change actually helps.

For each candidate fix:

1. Preserve a before binary or measurement; rebuilding replaces the evidence.
2. Make one conceptual change and rerun the identical workload several times.
3. Run `roc test examples/doom/main.roc` with the same compiler, then sample the
   new binary. A shifted hotspot is expected; a lower percentage alone is not
   evidence of lower absolute cost.
4. Add or extend a semantic test when optimizing collision, portals, actor
   scheduling, or dynamic geometry. Faster code must retain directional portal
   behavior and the distinction between host cycles and simulation tics.
5. Revert experiments that do not improve stable elapsed time. Commit each
   verified hotspot fix separately so its performance and correctness evidence
   remain reviewable.

Stop when the remaining samples are linear work required by the frame, further
experiments produce noise-sized gains or regressions, or the next improvement
would require a deliberate architecture change. Record that larger proposal
separately instead of hiding it inside a local optimization.

Fidelity scope, reference policy, and intentional departures are recorded in
[`FIDELITY.md`](FIDELITY.md). No commercial Doom data is used or required.
