# Observatory example optimization log

This log tracks the repository-wide pass over every example. Measurements use
ReleaseFast hosts, full Observatory detail, the headless backend, and 240 host
cycles unless an example exits earlier. Each optimization is accepted only
after a fresh capture preserves behavior and improves the targeted metric.
Headless timings describe Roc and host callback work; they do not claim GPU or
presentation cost.

Baseline capture directory: `/tmp/rocray-opt-baseline.2JMbmi` (local QA
artifact, not committed). Allocation and draw figures below are per host cycle.

| Example | Median cycle | Allocation | Draw calls | Status / evidence |
| --- | ---: | ---: | ---: | --- |
| async_read | 100.0 us | 3,791 B / 5.1 calls | 27.0 | Audited; bounded three-task workload retained |
| breakout | 339.1 us | 280 B / 1.0 calls | 114.0 | Audited; visible brick-and-glow workload retained |
| camera | 124.1 us | 56 B / 1.0 calls | 83.0 | Optimized; see result below |
| capture_plot | 131.8 us | 168 B / 3.0 calls | 46.0 | Audited; visible animated plot workload retained |
| capture_screenshot | 80.1 us | 366 B / 2.3 calls | 10.8 | Audited with scripted save through orderly exit |
| capture_ui_demo | 91.0 us | 296 B / 3.2 calls | 15.2 | Audited; static-text candidate rejected |
| cave_climb | 251.1 us | 816 B / 1.0 calls | 69.0 | Optimized; see result below |
| drop_viewer | 106.5 us | 11,219 B / 92.0 calls | 8.0 | Optimized; see result below |
| generated_assets | 124.1 us | 1,852 B / 18.0 calls | 21.0 | Audited; static-text candidate rejected |
| hello_world | 85.8 us | 4,778 B / 39.0 calls | 10.0 | Optimized; see result below |
| http_fetch | 105.9 us | 8,443 B / 4.1 calls | 35.4 | Audited; parked HTTP work is separated from frame work |
| input_inspector | 389.4 us | 14,368 B / 125.0 calls | 87.0 | Optimized; see result below |
| live_plot | 1,538.6 us | 3,507,271 B / 291.9 calls | 438.1 | Optimized; parsing remains the dominant cost |
| particles | 58.9 us | 192,703 B / 3.0 calls | 2.0 | Audited; bounded batch construction is already efficient |
| pong | 140.0 us | 479 B / 3.0 calls | 37.5 | Audited; visible trail-and-glow workload retained |
| post_process | 180.9 us | 21,091 B / 171.0 calls | 17.0 | Optimized; see result below |
| postcard_studio | 58.6 us | 102 B / 1.0 calls | 16.0 | Audited; bounded render-texture workload retained |
| projective_texture | 51.5 us | 144 B / 1.0 calls | 14.0 | Audited; already minimal for its visible workload |
| responsive_ui | 120.9 us | 420 B / 6.0 calls | 21.0 | Audited; dynamic layout/readouts retained |
| snake | 157.1 us | 2,386 B / 20.1 calls | 64.6 | Audited; two optimization probes rejected |
| sqlite_scores | 62.5 us | 264 B / 2.0 calls | 13.0 | Audited; idle and isolated database startup captured |
| task_sleep | 16,798.3 us | 193 B / 2.1 calls | 59.0 | Audited; 1.2 s parked wait is distinct from active work |
| top_down | 321.5 us | 5,024 B / 37.0 calls | 106.0 | Optimized; see result below |
| udp_cursor | 143.5 us | 771 B / 8.0 calls | 84.0 | Optimized; loopback timing remains nondeterministic |

## Accepted optimizations

### camera: cull the world grid to the rotated view

The example submitted every line spanning its 3,200 by 2,400 world regardless
of the camera view. Converting all four screen corners to world space gives a
conservative axis-aligned bound even while the camera is rotated. Applying it
to grid submission reduced accepted draw calls from 83 to 48 per cycle and
total render callback time from 25.1 ms to 22.4 ms over 240 cycles. Median
cycle time improved from 124.1 us to 121.7 us. A hidden real-window run moved
and rotated the camera through 170 frames and recorded zero omissions.

### input_inspector: retain invariant key-chip labels

Fifteen key and mouse chip labels were rebuilt and laid out every render. A
single boxed set of prepared labels reduced recurring allocation from 14,368 B
and 125 calls to 898 B and four calls, and accepted draw calls from 87 to 72.
The larger retained UI set increased average update time from 7.8 us to 20.8
us, but average render time fell from 373.0 us to 335.8 us; median cycle time
improved from 389.4 us to 367.7 us and p95 from 430.2 us to 413.5 us. The
scripted real-window event-order and quit path still produced the expected
events.

### live_plot: retain parsed-file summary totals

Added zones separated filesystem task delivery from application work and then
split update and rendering into their major parts. Parsing and eviction remain
the principal cost, but the HUD was also folding every retained lane twice per
frame to rediscover the number of ready files and total parsed lines. Maintaining
those two totals when a scan advances, completes, or is reset for a refetch
removed the full-list folds. Across matched 240-cycle full-detail runs, total
render callback time fell from 351.5 ms to 289.5 ms and the HUD zone from 281.6
ms to 231.0 ms. P95 cycle time fell from 30.45 ms to 28.78 ms. The retained
zones make the still-dominant parse-and-evict work explicit for future tuning.

### cave_climb: cull off-camera actors

Trace zones separated the 183.5 us average render callback into tilemap (14.0
us), HUD (9.6 us), and actors (115.2 us). Gems and hazard markers alone took
67.2 us because all eight gems and six hazards were submitted throughout the
vertically scrolling level. Mirrors and enemies had the same issue. Culling by
the complete glow, sprite, or segment bounds reduced accepted draw calls from
69 to 31 per cycle without changing allocation traffic. Average render time
fell to 119.6 us, median cycle time from 251.1 us to 187.2 us, and p95 from
258.2 us to 196.4 us. A 240-cycle hidden raylib run also completed cleanly with
zero Observatory omissions.

### drop_viewer: prepare static interface copy

Four invariant labels were rebuilt in `render!`, including the empty-state
prompt. Preparing them during `init!` reduced recurring allocation from 11,219
B and 92 calls to 224 B and one call per cycle. Accepted draw calls fell from
8 to 5 because prepared text crosses through the prepared-text operation, and
average render callback time fell from 88.8 us to 34.5 us. The headless median
cycle fell from 106.5 us to 61.4 us.

### hello_world: retain the invariant layout

The baseline attributed 4,778 B and 39 allocation calls per cycle to an
`update!` that measured the same title and rebuilt the same fixed layout every
time. Retaining the layout created during `init!` reduced traffic to 96 B and
one call per cycle, reduced average update time from 33.1 us to 12.7 us, and
reduced the headless median cycle from 85.8 us to 71.8 us. The model also no
longer retains a separate font capability solely to repeat that measurement.

### post_process: prepare invariant text once

The full capture showed 21,091 B and 171 Roc allocation calls every cycle,
almost entirely during `render!`. The example rebuilt two invariant `Text`
values there. Moving `prepare!` to `init!` reduced recurring traffic to 104 B
and one call per cycle, reduced accepted draw calls from 17 to 15, and reduced
the headless median cycle from 180.9 us to 75.7 us. This is a 99.5% reduction
in recurring allocation bytes and a 58.1% median-cycle reduction in this run.

### top_down: cull off-camera world actors

The baseline submitted every obstacle, decoration, spark, and moving hazard in
the level even when the camera could not show it. Conservative tests against
each actor's complete visual bounds reduced accepted draw calls from 106 to 46
per cycle and average render time from 294.6 us to 198.2 us. Although average
update time rose from 14.1 us to 48.3 us across the rebuild, the repeat capture
confirmed a net improvement: median cycle time fell from 321.5 us to 261.7 us
and p95 from 333.0 us to 265.8 us. A 240-frame hidden raylib run moved the
camera in three directions and completed with zero Observatory omissions.

### udp_cursor: stop submitting grid lines beyond the window

The fixed 32-by-32 grid submitted both a horizontal and vertical line for every
offset even after an offset exceeded the corresponding window dimension.
Checking each axis independently reduced accepted draw calls from 84 to 57 per
cycle at the default size. Two repeat captures put total render callback time
at 23.5 ms, down from the 24.9 ms baseline, with allocation unchanged. Overall
cycle latency is not used for this acceptance decision because loopback receive
task delivery varied materially between runs.

## Evidence-backed no-change audits

### particles: retain the explicit 4,000-sprite workload

Full allocation lifetimes showed no realloc moves or copied bytes after the
first cycle. The recurring traffic is the bounded particle-state map plus the
exact 4,000-element texture-instance batch; rendering crosses the hosted
boundary once for the batch. Observatory zones measured particle advancement
at 1.25 ms total and instance preparation at 4.82 ms total over 240 cycles,
with a 58.9 us median cycle. Removing that traffic would require reducing the
demonstrated workload or changing the public batch representation, not fixing
avoidable application work.

### breakout and pong: retain the visible game presentation

Both baselines have negligible recurring allocation relative to their work:
280 B in one call for `breakout` and 479 B in three calls for `pong`. Source
review accounts for the draw submissions as visible bricks and their sheen in
`breakout`, and the centre dashes, short ball trail, bodies, and additive glow
in `pong`. They use prepared invariant text and bounded on-screen collections;
there is no off-camera population or invariant per-frame layout to remove
without simplifying the intended examples.

### capture examples: retain bounded demonstration work

`capture_plot` uses 46 visible submissions for its animated bars, caps, points,
grid, and recording UI while allocating 168 B in three calls per cycle.
`capture_screenshot` was rerun with a scripted `S` press: the screenshot task
completed, the app exited on cycle six, and Observatory measured the hosted
screenshot call at about 2 us with zero omissions. `capture_ui_demo` already
prepares every reachable counter and field value. Preparing its two remaining
static captions reduced allocation events but regressed median cycle time from
91 us to 114 us and increased both update and render totals, so that candidate
was reverted.

### asynchronous I/O examples: retain the work being demonstrated

`async_read` starts exactly three bounded file tasks; Observatory separated
their parked intervals from sub-millisecond active work and showed 100 us
median cycles. `http_fetch` likewise attributed 286.7 ms to its one HTTP task
while the frame loop remained at a 105.9 us median. `task_sleep` attributed
1,200.0 ms to the intentional parked sleep, with an 11 us active task turn.
Treating any of those waits as callback work would have pointed at the wrong
code; no application-side optimization is warranted.

### low-cost graphics and UI examples: retain visible or dynamic work

`postcard_studio` (58.6 us median, 102 B in one call) and
`projective_texture` (51.5 us, 144 B in one call) are already allocation-light
and their submissions are visible composition. `responsive_ui` prepares its
invariant copy; its remaining strings describe the live window, framebuffer,
monitor, or selected panel. `generated_assets` and `snake` were also audited,
but their rejected experiments are recorded below because lower allocation did
not produce lower callback or cycle time.

### sqlite_scores: retain bounded database and row presentation work

An isolated empty-directory run captured database creation, schema setup,
statement preparation, and the initial query without touching repository data.
The one-time SQLite effects are individually visible, recurring allocation is
264 B in two calls, and idle median cycles are 62.5 us. Row formatting is
dynamic database content and the displayed row set is bounded; there is no
invariant layout or unbounded rendering population to remove.

## Observatory friction and issues

- Full detail has meaningful observer cost, so absolute timings are used to
  locate work and before/after captures use identical recorder settings.
- Headless presentation and GPU measurements are correctly unavailable; apps
  dominated by drawing still require a graphical follow-up.
- The bulk example builder deliberately skips `cave_climb`; a dedicated runner
  invocation was required to capture it.
- `capture_screenshot` exits after six headless cycles because its capture
  lifecycle completes; its representative workload must be scripted rather
  than treated as a 240-cycle steady-state run.
- Many examples have no Trace zones. Observatory identifies the expensive
  callback and allocation phase, but source-level attribution then requires
  inspection or a temporary/additional annotation.
- `live_plot` walks the working directory using concurrent tasks, so the files
  delivered in any particular cycle vary between captures. Repeated aggregate
  zone and callback totals are useful, but individual cycle comparisons are
  not a controlled benchmark until the app exposes a deterministic non-capture
  workload.
- `udp_cursor` loopback delivery changes how many receive completions are
  folded into each cycle. Render callback totals and accepted draw counts are
  repeatable, but whole-cycle before/after latency is not without a scripted
  peer and delivery schedule.
- A `generated_assets` experiment prepared its four swatch numbers and one
  static subtitle. It reduced allocation from 1,852 B/18 calls to 128 B/one
  call, but two repeat captures showed update time rising by about 9 us with
  unchanged render time. The candidate was rejected: allocation reduction is
  diagnostic evidence, not by itself proof of a performance improvement.
- Two `snake` experiments were rejected. Retaining a prepared score label
  reduced allocation but increased update cost; replacing short list-built
  drawing loops with effectful recursion reduced allocation by only three
  calls per cycle while increasing both update and render timings. Identical
  repeat captures are needed before interpreting the cross-build update shift,
  but neither candidate meets the acceptance rule now.
