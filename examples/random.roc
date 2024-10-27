app [Model, init!, render!] {
    rr: platform "../platform/main.roc",
    rand: "https://github.com/lukewilliamboswell/roc-random/releases/download/0.2.2/cfMw9d_uxoqozMTg7Rvk-By3k1RscEDoR1sZIPVBRKQ.tar.br",
    time: "https://github.com/imclerran/roc-isodate/releases/download/v0.5.0/ptg0ElRLlIqsxMDZTTvQHgUSkNrUSymQaGwTfv0UEmk.tar.br",
}

import rr.RocRay exposing [Rectangle, Color]
import rr.Keys
import rr.Draw
import rand.Random
import time.DateTime

Model : {
    seed : Random.State U32,
    number : U64,
}

width = 800
height = 800

init! : {} => Result Model []
init! = \{} ->

    RocRay.setTargetFPS! 500
    RocRay.displayFPS! { fps: Visible, pos: { x: 10, y: 10 } }
    RocRay.initWindow! { title: "Random Dots", width, height }

    Ok {
        number: 10000,
        seed: Random.seed 1234,
    }

render! : Model, RocRay.PlatformState => Result Model []
render! = \model, { keys, timestampMillis } ->

    nowStr = DateTime.fromNanosSinceEpoch (timestampMillis * 1000) |> DateTime.toIsoStr

    { seed, lines } = randomList model.seed (Random.u32 0 800) model.number

    number =
        if Keys.down keys KeyUp then
            Num.addSaturated model.number 10
        else if Keys.down keys KeyDown then
            Num.subSaturated model.number 10
        else
            model.number

    Draw.draw! Black \{} ->

        Draw.text! { pos: { x: 10, y: 50 }, text: "DateTime $(nowStr)", size: 20, color: White }

        forEach! lines Draw.rectangle!

        Draw.text! { pos: { x: 10, y: height - 25 }, text: "Up-Down to change number of random dots, current value is $(Num.toStr model.number)", size: 20, color: White }

    Ok { model & seed, number }

# Generate a list of lines using the seed and generator provided
randomList : Random.State U32, Random.Generator U32 U32, U64 -> { seed : Random.State U32, lines : List { rect : Rectangle, color : Color } }
randomList = \initialSeed, generator, number ->
    List.range { start: At 0, end: Before number }
    |> List.walk { seed: initialSeed, lines: [] } \state, _ ->

        random = generator state.seed

        x = Num.toF32 random.value

        random2 = generator random.state

        y = Num.toF32 random2.value

        lines = List.append state.lines { rect: { x, y, width: 1, height: 1 }, color: colorFromU32 random2.value }

        { seed: random2.state, lines }

colorFromU32 : U32 -> Color
colorFromU32 = \u32 ->
    if u32 % 10 == 0 then
        White
    else if u32 % 10 == 1 then
        Silver
    else if u32 % 10 == 2 then
        Gray
    else if u32 % 10 == 3 then
        Black
    else if u32 % 10 == 4 then
        Red
    else if u32 % 10 == 5 then
        Maroon
    else if u32 % 10 == 6 then
        Yellow
    else if u32 % 10 == 7 then
        Olive
    else if u32 % 10 == 8 then
        Lime
    else if u32 % 10 == 9 then
        Green
    else if u32 % 10 == 10 then
        Aqua
    else if u32 % 10 == 11 then
        Teal
    else if u32 % 10 == 12 then
        Blue
    else if u32 % 10 == 13 then
        Navy
    else if u32 % 10 == 14 then
        Fuchsia
    else if u32 % 10 == 15 then
        Purple
    else
        White

# TODO REPLACE WITH BUILTIN
forEach! : List a, (a => {}) => {}
forEach! = \l, f! ->
    when l is
        [] -> {}
        [x, .. as xs] ->
            f! x
            forEach! xs f!
