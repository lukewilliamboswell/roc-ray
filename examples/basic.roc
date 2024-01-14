app "basic"
    packages {
        ray: "../platform/main.roc",
    }
    imports [ray.Task.{ Task }, ray.Core.{Color}]
    provides [main, Model] to ray

Program : {
    init : Task Model [],
    update : Model -> Task Model [],
}

Model : {
    current : [ScreenA, ScreenB],
    textSize : I32,
    text : Str,
    width : U32, 
    height : U32, 
    showFPS : Bool,
}

main : Program
main = { init, update }

init : Task Model []
init =

    width = 400u32
    height = 400u32

    {} <- Core.setWindowSize { width, height } |> Task.await

    Task.ok {
        current: ScreenA,
        textSize : 10,
        text: "Ahoy There",
        width, 
        height,
        showFPS: Bool.true,
    }

update : Model -> Task Model []
update = \model ->
    Task.ok model 
    |> Task.await drawScreenA
    # |> Task.await decreaseBtn
    # |> Task.await drawText
    |> Task.await toggleFPSBtn
    |> Task.await exitBtn

toggleFPSBtn : Model -> Task Model []
toggleFPSBtn = \model ->

    str = if model.showFPS then "Show FPS" else "Hide FPS"
    x = model.width - 120 |> Num.toF32
    y = model.height - 24 |> Num.toF32 

    { isPressed } <- Core.button { x, y, width: 120f32, height: 24f32 } str |> Task.await

    if isPressed then 
        Task.ok {model & showFPS : !model.showFPS}
    else 
        Task.ok model
            
# increaseBtn : {textSize : I32}a -> Task {textSize : I32}a []
# increaseBtn = \model ->
#     { isPressed } <- Core.button { x: 24, y: 24, width: 120, height: 24 } "Increase Text" |> Task.await

#     if isPressed then 
#         Task.ok {model & textSize : model.textSize + 5}
#     else 
#         Task.ok model

# decreaseBtn : {textSize : I32}a -> Task {textSize : I32}a []
# decreaseBtn = \model ->
#     { isPressed } <- Core.button { x: 24, y: 48, width: 120, height: 24 } "Decrease Text" |> Task.await

#     if isPressed then 
#         Task.ok {model & textSize : model.textSize - 5}
#     else 
#         Task.ok model

# drawText : {text: Str, textSize: I32}a -> Task {text: Str, textSize: I32}a []
# drawText = \model ->
#     {} <- Core.text model.text { x : 24, y : 72, size : model.textSize, color : {r:255, g:0, b:0, a:255}} |> Task.await

#     Task.ok model

exitBtn : {}a -> Task {}a []
exitBtn = \model ->
    { isPressed } <- Core.button { x: 100, y: 250, width: 200, height: 100 } "EXIT" |> Task.await

    if isPressed then
        {} <- Core.exit |> Task.await
        Task.ok model
    else
        Task.ok model

drawScreenA : Model -> Task Model []
drawScreenA = \model ->
    if model.current != ScreenA then 
        Task.ok model
    else 
        {} <- Core.text "Screen A" { x : 10, y : 10, size : 50, color : white} |> Task.await

        Task.ok model


white : Color
white = {r:255, g:255, b:255, a:255}