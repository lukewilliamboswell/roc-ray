module [
    Music,
    length,
    load!,
    play!,
    stop!,
    pause!,
    resume!,
    getTimePlayed!,
]

import Effect

## A loaded music stream, used to play audio.
Music := Effect.LoadedMusic

## Load a music stream from a file.
## ```
## track = Music.load! "resources/green-hill-zone.wav"
## ```
## maps to Raylib's LoadMusicStream
load! : Str => Result Music [LoadErr Str]_
load! = \path ->
    Effect.loadMusicStream! path
    |> Result.map @Music
    |> Result.mapErr LoadErr

## Play a loaded music stream.
## ```
## Music.play! track
## ```
## maps to Raylib's PlayMusicStream
play! : Music => {}
play! = \@Music { music } ->
    Effect.playMusicStream! music

## Stop a playing music stream.
## ```
## Music.stop! track
## ```
## maps to Raylib's StopMusicStream
stop! : Music => {}
stop! = \@Music { music } ->
    Effect.stopMusicStream! music

## Pause a playing music stream.
## ```
## Music.pause! track
## ```
## maps to Raylib's PauseMusicStream
pause! : Music => {}
pause! = \@Music { music } ->
    Effect.pauseMusicStream! music

## Resume a paused music stream.
## ```
## Music.resume! track
## ```
## maps to Raylib's ResumeMusicStream
resume! : Music => {}
resume! = \@Music { music } ->
    Effect.resumeMusicStream! music

## Get the time played so far in seconds.
## ```
## duration = Music.getTimePlayed! track
## ```
## maps to Raylib's GetMusicTimePlayed
getTimePlayed! : Music => F32
getTimePlayed! = \@Music { music } ->
    Effect.getMusicTimePlayed! music

## The length of the track in seconds.
## ```
## length = Music.length track
## ```
## maps to Raylib's GetMusicTimeLength
length : Music -> F32
length = \@Music { lenSeconds } ->
    lenSeconds
