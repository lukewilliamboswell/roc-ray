module [load, play]

import Effect
import RocRay exposing [Sound]

## Load a sound from a file.
## ```
## wav = Sound.load "resources/sound.wav"
## ```
load : Str -> Task Sound *
load = \path ->
    Effect.loadSound path
    |> Task.mapErr \{} -> crash "unreachable Sound.load"

## Play a loaded sound.
## ```
## Sound.play! wav
## ```
play : Sound -> Task {} *
play = \sound ->
    Effect.playSound sound
    |> Task.mapErr \{} -> crash "unreachable Sound.play"
