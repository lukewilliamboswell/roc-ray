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

    left = Core.translate (renderCounter model.left) .left (\record -> \count -> { record & left: count })
    middle = Core.translate (renderCounter model.middle) .middle (\record -> \count -> { record & middle: count })
    right = Core.translate (renderCounter model.right) .right (\record -> \count -> { record & right: count })

    {} <- Core.text "Counter Demo" { x: 10, y: 150, size: 20, color: { r: 255, g: 255, b: 255, a: 255 } } |> Task.await
    
    Task.ok (
        # Note that Row and Col only support exactly 3 elements for now
        Row [left, middle, right]
    )

renderCounter : I32 -> Elem I32
renderCounter = \count ->
    Col [
        Button { label: "+", onPress: \prev -> Action.update (prev + 1) },
        Text { label: "Clicked $(Num.toStr count) times", color: { r: 0, g: 255, b: 255, a: 255 } },
        Button { label: "-", onPress: \prev -> Action.update (prev - 1) },
    ]
