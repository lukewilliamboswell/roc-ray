app [Model, init!, render!] {
    rr: platform "../platform/main.roc",
    rand: "https://github.com/lukewilliamboswell/roc-random/releases/download/0.2.2/cfMw9d_uxoqozMTg7Rvk-By3k1RscEDoR1sZIPVBRKQ.tar.br",
    time: "https://github.com/imclerran/roc-isodate/releases/download/v0.5.0/ptg0ElRLlIqsxMDZTTvQHgUSkNrUSymQaGwTfv0UEmk.tar.br",
}

import rr.RocRay
import rr.Draw
import rr.Time
import rand.Random
import time.DateTime

Model : {
    seed : Random.State U32,
}

init! : {} => Result Model []
init! = \{} ->

    RocRay.initWindow! { title: "Time Example", height: 300 }

    seed =
        RocRay.randomI32! { min: Num.minI32, max: Num.maxI32 }
        |> Num.intCast
        |> Random.seed

    Ok { seed }

render! : Model, RocRay.PlatformState => Result Model []
render! = \model, { timestamp } ->

    # GENERATE A RANDOM NUMBER BETWEEN 0 AND 100 TO SLEEP FOR
    { value, state: seed } = Random.step model.seed (Random.u32 0 100)

    Time.sleepMillis! (Num.toU64 value)

    # CONVERT THE PLATFORM TIMESTAMPS TO A READABLE ISO STRING
    initStart = millisToIsoStr timestamp.initStart
    initEnd = millisToIsoStr timestamp.initEnd

    lastRenderStart = millisToIsoStr timestamp.lastRenderStart
    lastRenderend = millisToIsoStr timestamp.lastRenderEnd

    renderStart = millisToIsoStr timestamp.renderStart

    ## CALCULATE USEFUL TIMING INFORMATION
    durationAlive = Num.toStr (timestamp.renderStart - timestamp.initStart)
    durationFrame = Num.toStr (timestamp.renderStart - timestamp.lastRenderStart)

    Draw.draw! White \{} ->
        Draw.text! { pos: { x: 10, y: 10 }, text: "Platform Timing Information", size: 20, color: Green }

        Draw.text! { pos: { x: 10, y: 50 }, text: "Init", size: 20, color: Navy }
        Draw.text! { pos: { x: 10, y: 70 }, text: "    Started    $(initStart)", size: 15, color: Black }
        Draw.text! { pos: { x: 10, y: 90 }, text: "    Ended      $(initEnd)", size: 15, color: Black }

        Draw.text! { pos: { x: 10, y: 120 }, text: "Last Render", size: 20, color: Navy }
        Draw.text! { pos: { x: 10, y: 140 }, text: "    Started    $(lastRenderStart)", size: 15, color: Black }
        Draw.text! { pos: { x: 10, y: 160 }, text: "    Ended      $(lastRenderend)", size: 15, color: Black }

        Draw.text! { pos: { x: 10, y: 190 }, text: "Current Render", size: 20, color: Navy }
        Draw.text! { pos: { x: 10, y: 210 }, text: "    Started    $(renderStart)", size: 15, color: Black }

        Draw.text! { pos: { x: 10, y: 240 }, text: "App alive $(durationAlive) ms", size: 15, color: Black }
        Draw.text! { pos: { x: 10, y: 260 }, text: "Frame delta $(durationFrame) ms", size: 15, color: Black }

    Ok { model & seed }

millisToIsoStr : U64 -> Str
millisToIsoStr = \ts ->
    ts |> Time.toNanos |> DateTime.fromNanosSinceEpoch |> DateTime.toIsoStr
