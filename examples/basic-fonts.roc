app [Model, init!, render!] { rr: platform "../platform/main.roc" }

import rr.RocRay
import rr.Draw
import rr.Font exposing [Font]

Model : {
    poppins: Font,
}

init! : {} => Result Model []
init! = \{} ->

    RocRay.initWindow! { title: "Basic Fonts" }

    poppins = Font.load! "examples/assets/Poppins-Regular.ttf"

    Ok { poppins }

render! : Model, RocRay.PlatformState => Result Model []
render! = \model, _ ->

    startY = 10
    quickBrownFox = "The quick brown fox jumps over the lazy dog."

    Draw.draw! White \{} ->

        _ = drawTextAt! startY quickBrownFox Default 10


    Ok model

drawTextAt! : F32, Str, Font, F32 => F32
drawTextAt! = \nextY, text, font, size ->

    { height } = Font.measure! { text, font, size }

    Draw.text! { font, text, pos: { x: 10, y: nextY }, size }

    nextY + height
