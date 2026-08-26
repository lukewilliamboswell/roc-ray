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
| async_read | 100.0 us | 3,791 B / 5.1 calls | 27.0 | Baseline captured; analysis pending |
| breakout | 339.1 us | 280 B / 1.0 calls | 114.0 | Baseline captured; analysis pending |
| camera | 124.1 us | 56 B / 1.0 calls | 83.0 | Baseline captured; analysis pending |
| capture_plot | 131.8 us | 168 B / 3.0 calls | 46.0 | Baseline captured; analysis pending |
| capture_screenshot | 80.1 us | 366 B / 2.3 calls | 10.8 | Exits after 6 cycles headlessly; workload-specific capture still needed |
| capture_ui_demo | 91.0 us | 296 B / 3.2 calls | 15.2 | Baseline captured; analysis pending |
| cave_climb | 251.1 us | 816 B / 1.0 calls | 69.0 | Optimized; see result below |
| drop_viewer | 106.5 us | 11,219 B / 92.0 calls | 8.0 | Optimized; see result below |
| generated_assets | 124.1 us | 1,852 B / 18.0 calls | 21.0 | Baseline captured; analysis pending |
| hello_world | 85.8 us | 4,778 B / 39.0 calls | 10.0 | Optimized; see result below |
| http_fetch | 105.9 us | 8,443 B / 4.1 calls | 35.4 | Baseline captured; task workload needs separate interpretation |
| input_inspector | 389.4 us | 14,368 B / 125.0 calls | 87.0 | Optimized; see result below |
| live_plot | 1,538.6 us | 3,507,271 B / 291.9 calls | 438.1 | Optimized; parsing remains the dominant cost |
| particles | 58.9 us | 192,703 B / 3.0 calls | 2.0 | Trace attributes recurring list construction; analysis pending |
| pong | 140.0 us | 479 B / 3.0 calls | 37.5 | Baseline captured; analysis pending |
| post_process | 180.9 us | 21,091 B / 171.0 calls | 17.0 | Optimized; see result below |
| postcard_studio | 58.6 us | 102 B / 1.0 calls | 16.0 | Baseline captured; analysis pending |
| projective_texture | 51.5 us | 144 B / 1.0 calls | 14.0 | Baseline captured; analysis pending |
| responsive_ui | 120.9 us | 420 B / 6.0 calls | 21.0 | Baseline captured; analysis pending |
| snake | 157.1 us | 2,386 B / 20.1 calls | 64.6 | Baseline captured; analysis pending |
| sqlite_scores | 62.5 us | 264 B / 2.0 calls | 13.0 | Baseline captured; database workload needs scripted capture |
| task_sleep | 16,798.3 us | 193 B / 2.1 calls | 59.0 | Expected pacing/waiting example; task query separates parked from active work |
| top_down | 321.5 us | 5,024 B / 37.0 calls | 106.0 | Optimized; see result below |
| udp_cursor | 143.5 us | 771 B / 8.0 calls | 84.0 | Baseline captured; network workload needs scripted capture |

## Accepted optimizations

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
