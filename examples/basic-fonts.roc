app [Model, init!, render!] { rr: platform "../platform/main.roc" }

import rr.RocRay
import rr.Draw
import rr.Font

Model : {
    poppins : Font.Font,
}

init! : {} => Result Model _
init! = \{} ->

    RocRay.initWindow! { title: "Basic Fonts", width: 900, height: 300 }

    poppins = Font.load!? "examples/assets/Poppins-Regular.ttf"

    Ok { poppins }

render! : Model, RocRay.PlatformState => Result Model []
render! = \model, _ ->

    startY = 10f32
    quickBrownFox = "The quick brown fox jumps over the lazy dog."

    Draw.draw! White \{} ->
        startY
        |> drawTextNextY! { text: quickBrownFox, font: Font.default, size: 10, color: Red }
        |> drawTextNextY! { text: quickBrownFox, font: Font.default, size: 20, color: Green }
        |> drawTextNextY! { text: quickBrownFox, font: Font.default, size: 30, color: Blue }
        |> drawTextNextY! { text: quickBrownFox, font: Font.default, size: 40, color: Black }
        |> drawTextNextY! { text: quickBrownFox, font: model.poppins, size: 10, color: Red }
        |> drawTextNextY! { text: quickBrownFox, font: model.poppins, size: 20, color: Green }
        |> drawTextNextY! { text: quickBrownFox, font: model.poppins, size: 30, color: Blue }
        |> drawTextNextY! { text: quickBrownFox, font: model.poppins, size: 40, color: Black }
        |> \_ -> {}

    Ok model

drawTextNextY! : F32, { text : Str, font : Font.Font, size : F32, color : RocRay.Color } => F32
drawTextNextY! = \nextY, { text, font, size, color } ->

    Draw.text! { font, text, pos: { x: 10, y: nextY }, size, color }

    { height } = Font.measure! { text, size }

    nextY + height
