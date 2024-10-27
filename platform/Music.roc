module [Music, load, play, length, getTimePlayed]

import Effect

## A loaded music stream, used to play audio.
Music := Effect.LoadedMusic

## Load a music stream from a file.
## ```
## track = Music.load! "resources/green-hill-zone.wav"
## ```
## maps to Raylib's LoadMusicStream
load : Str -> Task Music *
load = \path ->
    Effect.loadMusicStream path
    |> Task.map \loaded -> @Music loaded
    |> Task.mapErr \{} -> crash "unreachable Music.load"

## Play a loaded music stream.
## ```
## Music.play! track
## ```
## maps to Raylib's PlayMusicStream
play : Music -> Task {} *
play = \@Music { music } ->
    Effect.playMusicStream music
    |> Task.mapErr \{} -> crash "unreachable Music.play"

## The length of the track in seconds.
## ```
## Music.length track
## ```
## maps to Raylib's GetMusicTimeLength
length : Music -> F32
length = \@Music { lenSeconds } ->
    lenSeconds

## Get the time played so far in seconds.
## ```
## Music.getTimePlayed! track
## ```
## maps to Raylib's GetMusicTimePlayed
getTimePlayed : Music -> Task F32 *
getTimePlayed = \@Music { music } ->
    Effect.getMusicTimePlayed music
    |> Task.mapErr \_fakeStr -> crash "unreachable Music.getTimePlayed"
