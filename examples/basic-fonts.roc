app [Model, init!, render!] { rr: platform "../platform/main.roc" }

import rr.RocRay
import rr.Draw
import rr.Font

Model : {
    poppins : Font.Font,
}

init! : {} => Result Model _
init! = |{}|

    RocRay.init_window!({ title: "Basic Fonts", width: 900, height: 300 })

    poppins = Font.load!("examples/assets/Poppins-Regular.ttf")?

    Ok({ poppins })

render! : Model, RocRay.PlatformState => Result Model []
render! = |model, _|

    start_y = 10f32
    quick_brown_fox = "The quick brown fox jumps over the lazy dog."

    Draw.draw!(
        White,
        |{}|
            start_y
            |> draw_text_next_y!({ text: quick_brown_fox, font: Font.default, size: 10, color: Red })
            |> draw_text_next_y!({ text: quick_brown_fox, font: Font.default, size: 20, color: Green })
            |> draw_text_next_y!({ text: quick_brown_fox, font: Font.default, size: 30, color: Blue })
            |> draw_text_next_y!({ text: quick_brown_fox, font: Font.default, size: 40, color: Black })
            |> draw_text_next_y!({ text: quick_brown_fox, font: model.poppins, size: 10, color: Red })
            |> draw_text_next_y!({ text: quick_brown_fox, font: model.poppins, size: 20, color: Green })
            |> draw_text_next_y!({ text: quick_brown_fox, font: model.poppins, size: 30, color: Blue })
            |> draw_text_next_y!({ text: quick_brown_fox, font: model.poppins, size: 40, color: Black })
            |> |_| {},
    )

    Ok(model)

draw_text_next_y! : F32, { text : Str, font : Font.Font, size : F32, color : RocRay.Color } => F32
draw_text_next_y! = |next_y, { text, font, size, color }|

    Draw.text!({ font, text, pos: { x: 10, y: next_y }, size, color })

    { height } = Font.measure!({ text, size })

    next_y + height
