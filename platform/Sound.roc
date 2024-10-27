module [load!, play!]

import Effect
import RocRay exposing [Sound]

## Load a sound from a file.
## ```
## wav = Sound.load! "resources/sound.wav"
## ```
load! : Str => Sound
load! = \path ->
    Effect.loadSound! path

## Play a loaded sound.
## ```
## Sound.play! wav
## ```
play! : Sound => {}
play! = \sound ->
    Effect.playSound! sound
