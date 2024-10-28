module [
    Time,
    sleepMillis!,
    toNanos,
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

toNanos : U64 -> U64
toNanos = \millis -> millis * 1_000_000

## Sleep the main thread for a given number of milliseconds.
sleepMillis! : U64 => {}
sleepMillis! = \millis -> Effect.sleepMillis! millis
