module [load!, play!]

import Effect
import RocRay exposing [Sound]

## Load a sound from a file.
## ```
## wav = Sound.load! "resources/sound.wav"
## ```
load! : Str => Result Sound [LoadErr Str]_
load! = |path|
    Effect.load_sound!(path)
    |> Result.map_err(LoadErr)

## Play a loaded sound.
## ```
## Sound.play! wav
## ```
play! : Sound => {}
play! = |sound|
    Effect.play_sound!(sound)
