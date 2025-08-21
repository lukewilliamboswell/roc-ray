app [Model, init!, render!] {
    rr: platform "../platform/main.roc",
    rand: "https://github.com/lukewilliamboswell/roc-random/releases/download/0.5.0/yDUoWipuyNeJ-euaij4w_ozQCWtxCsywj68H0PlJAdE.tar.br",
}

import rr.RocRay
import rr.Draw
import rr.Time
import rand.Random

Model : {
    seed : Random.State,
}

init! : {} => Result Model []
init! = |{}|

    RocRay.init_window!({ title: "Time Example", height: 300 })

    seed =
        RocRay.random_i32!({ min: Num.min_i32, max: Num.max_i32 })
        |> Num.int_cast
        |> Random.seed

    Ok({ seed })

render! : Model, RocRay.PlatformState => Result Model []
render! = |model, { timestamp }|

    # GENERATE A RANDOM NUMBER BETWEEN 0 AND 100 TO SLEEP FOR
    { value, state: seed } = Random.step(model.seed, Random.bounded_u32(0, 100))

    Time.sleep_millis!(Num.to_u64(value))

    # CONVERT THE PLATFORM TIMESTAMPS TO A READABLE ISO STRING
    init_start = millis_to_iso_str(timestamp.init_start)
    init_end = millis_to_iso_str(timestamp.init_end)

    last_render_start = millis_to_iso_str(timestamp.last_render_start)
    last_renderend = millis_to_iso_str(timestamp.last_render_end)

    render_start = millis_to_iso_str(timestamp.render_start)

    ## CALCULATE USEFUL TIMING INFORMATION
    duration_alive = Num.to_str((timestamp.render_start - timestamp.init_start))
    duration_frame = Num.to_str((timestamp.render_start - timestamp.last_render_start))

    Draw.draw!(
        White,
        |{}|
            Draw.text!({ pos: { x: 10, y: 10 }, text: "Platform Timing Information", size: 20, color: Green })

            Draw.text!({ pos: { x: 10, y: 50 }, text: "Init", size: 20, color: Navy })
            Draw.text!({ pos: { x: 10, y: 70 }, text: "    Started    ${init_start}", size: 15, color: Black })
            Draw.text!({ pos: { x: 10, y: 90 }, text: "    Ended      ${init_end}", size: 15, color: Black })

            Draw.text!({ pos: { x: 10, y: 120 }, text: "Last Render", size: 20, color: Navy })
            Draw.text!({ pos: { x: 10, y: 140 }, text: "    Started    ${last_render_start}", size: 15, color: Black })
            Draw.text!({ pos: { x: 10, y: 160 }, text: "    Ended      ${last_renderend}", size: 15, color: Black })

            Draw.text!({ pos: { x: 10, y: 190 }, text: "Current Render", size: 20, color: Navy })
            Draw.text!({ pos: { x: 10, y: 210 }, text: "    Started    ${render_start}", size: 15, color: Black })

            Draw.text!({ pos: { x: 10, y: 240 }, text: "App alive ${duration_alive} ms", size: 15, color: Black })
            Draw.text!({ pos: { x: 10, y: 260 }, text: "Frame delta ${duration_frame} ms", size: 15, color: Black }),
    )

    Ok({ model & seed })

millis_to_iso_str : U64 -> Str
millis_to_iso_str = |ts|
    Inspect.to_str(ts)
