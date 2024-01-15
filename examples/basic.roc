app "basic"
    packages {
        ray: "../platform/main.roc",
    }
    imports [ray.Core.{Color, Elem}, ray.Action.{Action}]
    provides [main, Model] to ray

Program : {
    init : Model,
    render : Model -> Elem Model,
}

Model : I32

main : Program
main = { init, render }

init : Model
init = 1

render : Model -> Elem Model
render = \model ->
    Col [
        increase,
        label model,
        decrease,
    ]

increase : Elem Model
increase = Button {label: "+", onPress: \prev -> Action.update (prev + 1)}

label : Model -> Elem Model
label = \model -> Text { label: "Clicked $(Num.toStr model) times", color : white }

decrease : Elem Model
decrease = Button {label: "-", onPress: \prev -> Action.update (prev - 1)}

white : Color
white = {r:255, g:255, b:255, a:255}