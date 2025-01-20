module [
    Music,
    length,
    load!,
    play!,
    stop!,
    pause!,
    resume!,
    get_time_played!,
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
load! = |path|
    Effect.load_music_stream!(path)
    |> Result.map_ok(@Music)
    |> Result.map_err(LoadErr)

## Play a loaded music stream.
## ```
## Music.play! track
## ```
## maps to Raylib's PlayMusicStream
play! : Music => {}
play! = |@Music({ music })|
    Effect.play_music_stream!(music)

## Stop a playing music stream.
## ```
## Music.stop! track
## ```
## maps to Raylib's StopMusicStream
stop! : Music => {}
stop! = |@Music({ music })|
    Effect.stop_music_stream!(music)

## Pause a playing music stream.
## ```
## Music.pause! track
## ```
## maps to Raylib's PauseMusicStream
pause! : Music => {}
pause! = |@Music({ music })|
    Effect.pause_music_stream!(music)

## Resume a paused music stream.
## ```
## Music.resume! track
## ```
## maps to Raylib's ResumeMusicStream
resume! : Music => {}
resume! = |@Music({ music })|
    Effect.resume_music_stream!(music)

## Get the time played so far in seconds.
## ```
## duration = Music.getTimePlayed! track
## ```
## maps to Raylib's GetMusicTimePlayed
get_time_played! : Music => F32
get_time_played! = |@Music({ music })|
    Effect.get_music_time_played!(music)

## The length of the track in seconds.
## ```
## length = Music.length track
## ```
## maps to Raylib's GetMusicTimeLength
length : Music -> F32
length = |@Music({ len_seconds })|
    len_seconds
