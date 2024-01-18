app "counter"
    packages { ray: "../platform/main.roc" }
    imports [ray.Task.{ Task }, ray.Action.{ Action }, ray.Core.{ Color, Rectangle }, ray.GUI.{ Elem }]
    provides [main, Model] to ray

Program : {
    init : Task Model [],
    render : Model -> Task Model [],
}

Model : {
    left : I32,
    middle : I32,
    right : I32,
    showCounters : Bool,
}

main : Program
main = { init, render }

width = 800
height = 600

init : Task Model []
init =

    {} <- Core.setWindowSize { width, height } |> Task.await
    {} <- Core.setWindowTitle "Basic Demo" |> Task.await

    Task.ok { left: 10, middle: 20, right: 30, showCounters: Bool.true }

render : Model -> Task Model []
render = \model ->

    {} <- Core.drawText { text: "Press ESC to EXIT", posX: width - 220, posY: height - 25, fontSize: 20, color: white } |> Task.await

    Window
        { title: "COUNTER Demo", onClose: \_ -> Action.none }
        (
            Col [
                Text { label: "Click below to change the counters", color: black },
                Row [
                    GUI.translate (renderCounter model.left red) .left (\record, count -> { record & left: count }),
                    GUI.translate (renderCounter model.middle green) .middle (\record, count -> { record & middle: count }),
                    GUI.translate (renderCounter model.right blue) .right (\record, count -> { record & right: count }),
                ],
            ]
        )
    |> GUI.draw model {
        x: width / 8,
        y: height / 8,
        width: width * 6 / 8,
        height: height * 6 / 8,
    }

renderCounter : I32, Color -> Elem I32
renderCounter = \count, color ->
    Col [
        Button { text: "+", onPress: \prev -> Action.update (prev + 1) },
        Text { label: "Clicked $(Num.toStr count) times", color },
        Button { text: "-", onPress: \prev -> Action.update (prev - 1) },
    ]

# === HELPERS ========================

black = { r: 0, g: 0, b: 0, a: 255 }
blue = { r: 0, g: 0, b: 255, a: 255 }
red = { r: 255, g: 0, b: 0, a: 255 }
green = { r: 0, g: 255, b: 0, a: 255 }
white = { r: 255, g: 255, b: 255, a: 255 }
