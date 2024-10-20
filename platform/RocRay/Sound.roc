module [Sound, play, load]

# import InternalSound exposing [SoundId]
import Effect

## A handle to a loaded sound
Sound : U32
# Sound : SoundId

load : Str -> Task Sound *
load = \path ->
    Effect.loadSound path #
    # |> Task.map SoundId.pack
    |> Task.mapErr \{} -> crash "unreachable Sound.load"

play : Sound -> Task {} *
play = \sound ->
    sound #
    # |> SoundId.unpack
    |> Effect.playSound
    |> Task.mapErr \{} -> crash "unreachable Sound.play"
