app "counter"
    packages { ray: "../platform/main.roc" }
    imports [ray.Core.{ Color, Elem }, ray.Task.{Task}, ray.Action.{ Action }]
    provides [main, Model] to ray

Program : {
    init : {width : F32, height : F32 } -> Task Model [],
    render : Model -> Task (Elem Model) [],
}

Model : {
    left : I32,
    middle : I32, 
    right : I32,
    window : {width : F32, height : F32 },
}

main : Program
main = { init, render }

init : {width : F32, height : F32 } -> Task Model []
init = \window ->

    {} <- Core.setWindowTitle "Counter Demo" |> Task.await

    Task.ok { left: 10, middle: 20, right: 30, window }

render : Model -> Task (Elem Model) []
render = \model ->

    left = Core.translate (renderCounter model.left red) .left (\record -> \count -> { record & left: count })
    middle = Core.translate (renderCounter model.middle green) .middle (\record -> \count -> { record & middle: count })
    right = Core.translate (renderCounter model.right blue) .right (\record -> \count -> { record & right: count })

    {} <- Core.text "Press ESC to EXIT" { x: model.window.width - 120, y: model.window.height - 10, size: 10, color: black } |> Task.await
    {} <- drawBackground model |> Task.await

    Col [
        Text { label: "Counter Demo", color: black },
        Row [left, middle, right],
    ]
    |> Task.ok

renderCounter : I32, Color -> Elem I32
renderCounter = \count, color ->
    Col [
        Button { label: "+", onPress: \prev -> Action.update (prev + 1) },
        Text { label: "Clicked $(Num.toStr count) times", color },
        Button { label: "-", onPress: \prev -> Action.update (prev - 1) },
    ]

drawBackground : Model -> Task {} []
drawBackground = \model -> 
    Core.drawRectangle { x : 0, y : 0, width : model.window.width, height : model.window.height, color : white }

black = { r: 0, g: 0, b: 0, a: 255 }
white = { r: 255, g: 255, b: 255, a: 255 }
blue = { r: 0, g: 0, b: 255, a: 255 }
red = { r: 255, g: 0, b: 0, a: 255 }
green = { r: 0, g: 255, b: 0, a: 255 }