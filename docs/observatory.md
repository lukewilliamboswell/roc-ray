# RocRay Observatory

Observatory is an opt-in host recorder for investigating slow host cycles and
the work surrounding them. A capture is a versioned SQLite database with the
`.rrstats` extension. Recording does not expose application payloads or the
opaque model to the host worker.

Start any built RocRay application with:

```text
my-app --host-stats-record
```

The default destination is a timestamped name such as
`20260825T235959Z-my-app.rrstats`. The recorder refuses to overwrite an
existing file.

## Host flags

| Flag | Meaning |
| --- | --- |
| `--host-stats-record` | Enable recording with the defaults. |
| `--host-stats-output=PATH` | Select the `.rrstats` destination and enable recording. |
| `--host-stats-detail=summary\|standard\|full` | Select captured detail; `standard` is the default. Summary records cycle and callback timing, aggregate counts and allocation traffic, annotations, backend facts, and recorder health. Standard adds non-drawing effects, tasks, queues, structural latency, and resource lifecycle transitions. Full adds individual allocations and draw operations. |
| `--host-stats-buffer-mib=N` | Bound recorder-owned memory in MiB; default 32, valid range 1–4096. Detail is omitted before reserved summary capacity is consumed. |
| `--host-stats-max-mib=N` | Stop admitting events once the database reaches this size; default 4096 MiB and must be greater than zero. The application continues. |

The output counter is the logical size of the main SQLite database plus its
active WAL. Admission stops below the selected maximum by a recorded terminal
reserve. One already-started transaction may cross that threshold; metadata
records `terminal_reserve_bytes`, `output_admission_limit_bytes`, and the
bounded `max_transaction_overshoot_bytes` used to interpret the result.

Recorder storage never runs Roc code. The frame thread copies compact events
into a bounded host-owned pool and never waits for SQLite. A dedicated writer
thread owns the database, writes WAL transactions, and checkpoints during
finalization. Saturation and the output limit do not change application
behavior; omissions appear in `recording_gaps` and `recorder_health`.

Startup failures, including an invalid path, an existing destination, or an
unavailable SQLite database, fail the requested recording rather than silently
replacing or overwriting it. A failure after startup disables further
recording, is reported by the host, and is reflected in final metadata where
the database remains writable.

## Privacy

Automatic recording excludes the opaque model, application payloads, input
contents, task messages, file contents, native pointers, and secrets. Labels
passed to `Trace` are application-provided diagnostic text and are stored
verbatim. Do not put personal data, credentials, URLs containing secrets,
file contents, or other sensitive values in a label. Treat an `.rrstats` file
as diagnostic data that may reveal application structure, timing, host and
architecture metadata, and the labels the application deliberately supplied.

## Application annotations

`Trace.mark!`, `Trace.begin!`/`Trace.end!`, `Trace.sample_i64!`, and
`Trace.sample_f64!` are legal in `init!`, `update!`, `render!`, and tasks.
They cannot discover whether recording is active or influence application
behavior. Zones are strict LIFO capabilities and must be ended by the owner
that began them. See the generated `Trace` API documentation for label, unit,
nesting, and programmer-error rules.

## Capture schema

`metadata.schema_version` is currently `1`. Consumers must check it before
assuming table or column meanings.

- `metadata` records schema, requested and effective detail, host environment,
  build identity, configured limits, clean shutdown, and final state. Build
  identity includes the Roc compiler pin embedded from `.roc-version`, target
  profile, backend, OS, architecture, and the portable executable/application
  basename derived from argument zero. `rocray_version` is `unavailable` until
  the build embeds an authoritative RocRay release version. These values come
  only from build/host configuration and process argument zero, never from the
  Roc application model or message payloads.
  `unavailable_sources` explicitly names measurements the selected host cannot
  honestly provide.
  `clock_source`, `clock_resolution_ns`, and `utc_origin_unix_ns` make the
  monotonic-relative timestamp domain and its wall-clock correlation explicit;
  UTC is identification metadata and is never used to calculate durations.
- `measurement_status` is the authority for interpreting every measurement
  family. Its final status is `complete`, `partial`, `not_recorded`, or
  `unavailable`, with row and omission counts and a reason. A missing detail row
  means zero activity only when that family's status is `complete`.
- `cycles` records one admitted host-cycle summary with application update and
  render-callback time, task-executor time (including polling or pacing), and
  residual host time; task/effect/draw/resource/queue counts; and Roc allocation,
  free, live, peak-live, and update-attributed allocation counters.
- `annotations` records marks, zone endpoints, and numeric samples. The
  irrelevant numeric column is SQL `NULL`. Zone-end rows include `wall_ns`,
  `active_ns`, and `parked_ns`; nested open zones are each charged for waits
  they span, and `wall_ns = active_ns + parked_ns`. A live task cancelled by
  orderly shutdown closes its remaining zones with the stable `zone_abort`
  annotation kind; ordinary callback escape remains a programmer error.
- `recording_gaps` records explicit per-family omission counts plus the honest
  bounded interval and producer track known by the frame-thread snapshot. When
  only one snapshot boundary is known, first/last cycle and start/end time are
  equal rather than implying unavailable precision.
- `recorder_health` records transactions, checkpoints, queue high-water,
  database size, omissions, written rows, writer failure, output limiting, and
  writer active/idle wall time. Writer CPU time is SQL `NULL` when unavailable
  and is disclosed by `metadata.unavailable_sources`.
  `metadata.drain_duration_ns` records orderly queue-drain wall time and
  `metadata.application_outcome` records the host-owned terminal outcome.

Schema v1 also defines nine detail tables. `task_events` records task
lifecycle and scheduling facts; `hosted_effects` records non-drawing effects with stable effect and
owner-correlation IDs, directional copy/ownership-transfer bytes, total call
timing, and nullable validation, conversion, worker, and external intervals;
`Task.sleep!` reports its actual waiting interval, and `Files.read_text!`
separately brackets filesystem waiting, UTF-8 validation, and the Roc string
copy/conversion. Other sub-intervals remain SQL `NULL` unless their production
boundary can isolate them without inference;
`queue_pressure` records bounded-facility occupancy, release, saturation, and
lossy overflow. Native interval-input rows cover hardware and virtual event
items plus typed codepoints; they report item capacity, current/high-water
occupancy, admitted or released amount, and oldest-item age without recording
keys, codepoints, pointer positions, or other input payloads. Overflow remains
distinct from queue saturation. Task pending-closure and staged-message rows
likewise contain only counts and ages. Their capacity is `0`, meaning
application-proportional with no platform admission cap: task spawns retain
FIFO delayed-start and exactly-one-message semantics, so these facilities emit
reserve/release facts but never an invented saturation or refusal;
`resource_lifecycle` records creation, saturation, reuse, retirement, and destruction
under recorder-private resource IDs (never application-visible lifecycle
tokens). Individual uses are represented only by the per-cycle resource-event
counter;
`structural_latency` links input or message observations to later cycles;
`draw_summaries` records aggregate drawing pressure. In full detail its stable
kind values distinguish primitive, batch/instance, upload, state change,
readback, and render-target change records; values contain counts and copied
bytes, never submitted payloads. For primitive and state rows, `value_a` is one
accepted call and `value_b` is zero unless the API carries a sized byte value.
For batch rows, `value_a` is the instance count and `value_b` is the known ABI
descriptor span. For texture-update uploads they are pixel count and RGBA8
payload bytes. For successful region, pixel, and screenshot readbacks they are
returned/read pixels and the known RGBA8 byte span. Encoded-image inputs report
their encoded source size because decoded driver-transfer bytes are not
available; no row claims GPU traffic, bandwidth, or execution time.
`allocation_events` is full-detail evidence and records allocation,
free, moving realloc, and in-place realloc facts with phase, private task and
active-zone correlation, current/prior sizes, and honest copied bytes (only a
move reports `min(prior_bytes, bytes)`). These columns support live, peak, and
survivor queries without recording addresses. Summary and standard captures
retain only the allocation counters in `cycles`. `gpu_facts` records the selected
backend, requested pacing, presentation completion, and whether GPU timing is
available. The native raylib backend and headless stub both report GPU timing
as unavailable: RocRay does not force a synchronizing query or present host
callback duration as GPU duration. Detail-level policy determines which
of these receive rows. Their presence in the schema does not imply that the
selected detail level or target supplied that family. `callback_summaries`
records automatic application callback duration and outcome by callback phase.
All recording rows belong to the single `runs` parent row through enforced
foreign keys. Timeline indexes cover common run/cycle/time, effect, task, and
resource lookups; orderly finalization refuses a clean marker if
`PRAGMA foreign_key_check` finds an orphan.

`clean_shutdown = 1` means orderly finalization completed. Consult
`final_state` and `measurement_status` before drawing a conclusion. The status
table incorporates detail policy and `recording_gaps`; consumers should not try
to reconstruct completeness from an empty detail table.

## Query a capture

The standalone, read-only SQL files in `scripts/observatory_queries/` are the
author-facing analysis API. Each file documents the question it answers, the
detail level it requires, its result bound, and any interpretation limits.
Run one with SQLite's command-line tool:

```sh
sqlite3 -readonly -header -column capture.rrstats \
  < scripts/observatory_queries/cycles.sql
```

Every query returns `evidence_status` and `evidence_reason`. Measurements are
SQL `NULL` when the required evidence is partial, not recorded, or unavailable.
This deliberately prefers “not known from this capture” to a plausible but
unsupported performance claim. The Python analyzer remains a non-public CI
reference for the same rules; the SQL files are the supported interface.

On the native raylib backend, `gpu_facts` also separates the `render!`
callback, drawing-scope begin, host capture/submission work, and `EndDrawing`.
Raylib combines command submission, buffer swap/presentation, and pacing wait
inside `EndDrawing`, so RocRay reports that duration under the explicit
`end_drawing_including_presentation_and_pacing` name and does not invent a
split or call it GPU time. Headless captures record the render callback and
explicit unavailable/omitted facts for the other phases.

## Regression and microbenchmark methodology

Recorder hot-path obligations are tested with deterministic operation counts,
not machine-dependent elapsed-time thresholds. The disabled and summary
hosted-effect path uses an injected counting clock and allocation-meter
snapshots to require zero clock reads and zero recorded allocations. Detail
policy is exhaustively checked across summary, standard, and full for every
event family. Backpressure is modeled by retaining every producer chunk as a
blocked writer would; a fixed number of reserve attempts must immediately
refuse, leave capacity unchanged, and increment the refusal counter exactly
once per attempt. This establishes bounded memory and non-waiting producer
admission without a flaky scheduler or wall-clock benchmark.

`scripts/test_effect_scope_audit.py` also scans every production `hosted*`
boundary function: a phase guard must have an `EffectScope`, except for the
explicitly listed Trace annotations that are recorder input themselves. New
hosted effects therefore fail CI until their timing/accounting obligation is
made deliberate.

For machine-dependent overhead measurements, run an opt-in ReleaseFast report:

```sh
zig build -Doptimize=ReleaseFast observatory-bench
```

The command builds `test/observatory_perf/main.roc` once, performs two warmups,
then runs disabled, summary, standard, full, and full with an intentionally
delayed writer nine times each. The delayed-writer case uses the private
benchmark seam plus a 1 MiB recorder pool and requires explicit loss, so it
exercises non-blocking saturation rather than relying on storage luck. The
order is shuffled within each repetition with a recorded seed. It writes the
raw samples, machine description, methodology, medians, and ratios to
`zig-out/observatory-benchmark.json` and a compact table to
`zig-out/observatory-benchmark.md`.

These timings are report-only: operating-system scheduling, storage, CPU power
state, and virtualization make a universal percentage threshold misleading.
The command fails only for semantic problems such as a failed application,
wrong cycle count or detail level, or an unclean capture. Headless measurements
are the primary recorder-overhead comparison. Real-window measurements must
keep render callback and host submission separate from raylib's indivisible
`end_drawing_including_presentation_and_pacing` interval; that interval is not
recorder CPU time. The windowed integration sweep separately records a short
real raylib capture and queries all four backend intervals; on Linux it runs
under the same X11 or Wayland display as the graphical example tests.
