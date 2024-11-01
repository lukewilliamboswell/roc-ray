module [load!, play!]

import Effect
import RocRay exposing [Sound]

## Load a sound from a file.
## ```
## wav = Sound.load! "resources/sound.wav"
## ```
load! : Str => Result Sound [LoadErr Str]_
load! = \path ->
    Effect.loadSound! path
    |> Result.mapErr LoadErr

## Play a loaded sound.
## ```
## Sound.play! wav
## ```
play! : Sound => {}
play! = \sound ->
    Effect.playSound! sound
