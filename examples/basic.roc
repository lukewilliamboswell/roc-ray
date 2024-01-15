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
render = \state ->
    Button {label: "Clicked $(Num.toStr state) times", onPress: \prev -> Action.update (prev + 1)}
    # Col [
    #     Text "Foo" { color : white },
    #     Button {label: "Click", onPress: onBtnPress}
    #     Text "Bar" { color : white },
    # ]

# white : Color
# white = {r:255, g:255, b:255, a:255}