app [Model, init!, render!] {
    rr: platform "../platform/main.roc",
    rand: "https://github.com/lukewilliamboswell/roc-random/releases/download/0.5.0/yDUoWipuyNeJ-euaij4w_ozQCWtxCsywj68H0PlJAdE.tar.br",
}

import rr.RocRay exposing [Rectangle, Color]
import rr.Keys
import rr.Draw
import rand.Random

Model : {
    seed : Random.State,
    number : U64,
}

width = 800
height = 800

init! : {} => Result Model []
init! = |{}|

    RocRay.set_target_fps!(500)
    RocRay.display_fps!({ fps: Visible, pos: { x: 10, y: 10 } })
    RocRay.init_window!({ title: "Random Dots", width, height })

    Ok(
        {
            number: 10000,
            seed: Random.seed(1234),
        },
    )

render! : Model, RocRay.PlatformState => Result Model []
render! = |model, { keys, timestamp }|
    now_str = Inspect.to_str(timestamp.render_start)

    { seed, lines } = random_list(model.seed, Random.bounded_u32(0, 800), model.number)

    number =
        if Keys.down(keys, KeyUp) then
            Num.add_saturated(model.number, 10)
        else if Keys.down(keys, KeyDown) then
            Num.sub_saturated(model.number, 10)
        else
            model.number

    Draw.draw!(
        Black,
        |{}|

            Draw.text!({ pos: { x: 10, y: 50 }, text: "RenderStart: ${now_str}", size: 20, color: White })

            List.for_each!(lines, Draw.rectangle!)

            Draw.text!({ pos: { x: 10, y: height - 25 }, text: "Up-Down to change number of random dots, current value is ${Num.to_str(model.number)}", size: 20, color: White }),
    )

    Ok({ model & seed, number })

# Generate a list of lines using the seed and generator provided
random_list : Random.State, Random.Generator U32, U64 -> { seed : Random.State, lines : List { rect : Rectangle, color : Color } }
random_list = |initial_seed, generator, number|
    List.range({ start: At(0), end: Before(number) })
    |> List.walk(
        { seed: initial_seed, lines: [] },
        |state, _|

            random = generator(state.seed)

            x = Num.to_f32(random.value)

            random2 = generator(random.state)

            y = Num.to_f32(random2.value)

            lines = List.append(state.lines, { rect: { x, y, width: 1, height: 1 }, color: color_from_u32(random2.value) })

            { seed: random2.state, lines },
    )

color_from_u32 : U32 -> Color
color_from_u32 = |u32|
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
