module [load]

import Effect
import RocRay exposing [Music]

## Load a music stream from a file.
## ```
## track = Music.load "resources/green-hill-zone.wav"
## ```
load : Str -> Task Music *
load = \path ->
    Effect.loadMusicStream path
    |> Task.mapErr \{} -> crash "unreachable Music.load"
