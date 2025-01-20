module [
    Time,
    sleep_millis!,
    to_nanos,
]

import Effect

## Timing information for key platform events measured in milliseconds from [UNIX EPOCH](https://en.wikipedia.org/wiki/Epoch_(computing)).
## ```
## {
##     initStart: U64,
##     initEnd: U64,
##     renderStart: U64,
##     lastRenderStart: U64,
##     lastRenderEnd: U64,
## }
## ```
Time : Effect.PlatformTime

to_nanos : U64 -> U64
to_nanos = |millis| millis * 1_000_000

## Sleep the main thread for a given number of milliseconds.
sleep_millis! : U64 => {}
sleep_millis! = |millis| Effect.sleep_millis!(millis)
