module [load, play]

import Effect
import RocRay exposing [Sound]

## Load a sound from a file.
## ```
## wav = RocRay.loadSound "resources/sound.wav"
## ```
load : Str -> Task Sound *
load = \path ->
    Effect.loadSound path
    |> Task.mapErr \{} -> crash "unreachable loadSound"

## Play a loaded sound.
## ```
## RocRay.playSound! wav
## ```
play : Sound -> Task {} *
play = \sound ->
    Effect.playSound sound
    |> Task.mapErr \{} -> crash "unreachable playSound"
