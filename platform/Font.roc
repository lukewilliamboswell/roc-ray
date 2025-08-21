module [Font, default, load!, measure!]

import Effect
import InternalVector

## A font that has been loaded into memory and is ready to be used.
Font : [Default, Loaded Effect.Font]

load! : Str => Result Font [LoadErr Str]
load! = |path|
    Effect.load_font!(path)
    |> Result.map_ok(Loaded)
    |> Result.map_err(LoadErr)

default : Font
default = Default

## Measure the width of a text string using the default font.
measure! : { font ?? Font, text : Str, size ?? F32, spacing ?? F32 } => { width : F32, height : F32 }
measure! = |{ font ?? Default, text: t, size ?? 20, spacing ?? 1 }|
    when font is
        Default ->
            Effect.measure_text!(t, size, spacing)
            |> InternalVector.to_vector2
            |> |{ x, y }| { width: x, height: y }

        Loaded(boxed) ->
            Effect.measure_text_font!(boxed, t, size, spacing)
            |> InternalVector.to_vector2
            |> |{ x, y }| { width: x, height: y }
