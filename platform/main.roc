platform "roc-ray"
    requires { Model } { main : _ }
    exposes [Core]
    packages {}
    imports [Task.{ Task }, Core.{Color, Elem}]
    provides [mainForHost]

# Program : {
#     init : Model,
#     render : Model -> Elem Model,
# }

ProgramModel : {
    width : F32,
    height : F32,
    model : Model,
}

ProgramForHost : {
    init : Task (Box ProgramModel) [],
    update : Box ProgramModel -> Task (Box ProgramModel) [],
}

mainForHost : ProgramForHost
mainForHost = { init, update }

init : Task (Box ProgramModel) []
init = 
    
    pm : ProgramModel
    pm = { 
        model: main.init,
        width : 800f32,
        height : 800f32,
    }

    {} <- Core.setWindowSize { width : pm.width, height : pm.height } |> Task.await

    Task.ok (Box.box pm)
    
update : Box ProgramModel -> Task (Box ProgramModel) []
update = \boxedPM ->

    pm = Box.unbox boxedPM

    elem = main.render pm.model

    newModel <- draw {x: 0, y: 0, width : 800, height: 800} pm.model elem |> Task.await 
    
    Task.ok (Box.box {pm & model: newModel})

draw : {x : F32, y : F32, width : F32, height : F32}, Model, Elem Model -> Task Model [] 
draw = \boundingBox, model, elem ->
    when elem is
        Button { label, onPress } ->
            {isPressed} <- Core.button { x: 20, y: 20, width: 120, height: 50 } label |> Task.await

            if isPressed then 
                when onPress model is 
                    None -> Task.ok model
                    Update newModel -> Task.ok newModel
            else 
                Task.ok model
            
        Col _ -> Task.ok model # drawCols boundingBox children
            
        Text str { color } -> 
            
            {} <- Core.text str { x: boundingBox.x, y: boundingBox.y, size: 20, color } |> Task.await
            Task.ok model

        None -> Task.ok model

# drawCols : {x : F32, y : F32, width : F32, height : F32}, List Elem -> Task {} []
# drawCols = \boundingBox, children ->
    
#     count = List.len children 

#     if count == 2 then 
#         aT = List.get children 0 |> Result.withDefault None
#         bT = List.get children 1 |> Result.withDefault None
        
#         {} <- draw boundingBox aT |> Task.await

#         newBB = {boundingBox & y : (boundingBox.y + 20)}

#         {} <- draw newBB bT |> Task.await

#         Task.ok {}

#     else 
#         Task.ok {}

    # count = List.len children |> Num.toF32
    # delta = boundingBox.height / count
    
    # List.range {start: At 0, end: Before count}
    # |> List.map \i -> boundingBox.y + (Num.toF32 i) * 10
    # |> List.map2 children \newY, child -> 
    #     draw {x: newY , y: newY, width: boundingBox.width, height: 24} child
    # |> List.walk (Task.ok {}) \_, task -> 
    #     {} <- task |> Task.await

    #     Task.ok {}
