module [Music, load, play, length]

import Effect
import RocRay

## A loaded music stream, used to play audio.
Music := Effect.LoadedMusic

## Load a music stream from a file.
## ```
## track = Music.load! "resources/green-hill-zone.wav"
## ```
load : Str -> Task Music *
load = \path ->
    Effect.loadMusicStream path
    |> Task.map \loaded -> @Music loaded
    |> Task.mapErr \{} -> crash "unreachable Music.load"

## Play a loaded music stream.
## ```
## Music.play! track
## ```
play : Music -> Task {} *
play = \@Music { music } ->
    Effect.playMusicStream music
    |> Task.mapErr \{} -> crash "unreachable Music.play"

## The length of the track in seconds
length : Music -> F32
length = \@Music { lenSeconds } ->
    lenSeconds
