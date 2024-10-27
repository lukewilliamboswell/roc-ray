module [
    Music,
    load,
    play,
    stop,
    pause,
    resume,
    length,
    getTimePlayed,
]

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

## Stop a playing music stream.
## ```
## Music.stop! track
## ```
## maps to Raylib's StopMusicStream
stop : Music -> Task {} *
stop = \@Music { music } ->
    Effect.stopMusicStream music
    |> Task.mapErr \{} -> crash "unreachable Music.stop"

## Pause a playing music stream.
## ```
## Music.pause! track
## ```
## maps to Raylib's PauseMusicStream
pause : Music -> Task {} *
pause = \@Music { music } ->
    Effect.pauseMusicStream music
    |> Task.mapErr \{} -> crash "unreachable Music.pause"

## Resume a paused music stream.
## ```
## Music.resume! track
## ```
## maps to Raylib's ResumeMusicStream
resume : Music -> Task {} *
resume = \@Music { music } ->
    Effect.resumeMusicStream music
    |> Task.mapErr \{} -> crash "unreachable Music.resume"

## Get the time played so far in seconds.
## ```
## Music.getTimePlayed! track
## ```
## maps to Raylib's GetMusicTimePlayed
getTimePlayed : Music -> Task F32 *
getTimePlayed = \@Music { music } ->
    Effect.getMusicTimePlayed music
    |> Task.mapErr \_fakeStr -> crash "unreachable Music.getTimePlayed"

## The length of the track in seconds.
## ```
## Music.length track
## ```
## maps to Raylib's GetMusicTimeLength
length : Music -> F32
length = \@Music { lenSeconds } ->
    lenSeconds
