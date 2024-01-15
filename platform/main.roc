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
    }

    {} <- Core.setWindowSize { width : 400f32, height : 400f32 } |> Task.await

    Task.ok (Box.box pm)
    
update : Box ProgramModel -> Task (Box ProgramModel) []
update = \boxedPM ->

    pm = Box.unbox boxedPM

    elem = main.render pm.model

    newModel <- draw {x: 0, y: 0, width : 400, height: 400} pm.model elem |> Task.await 
    
    Task.ok (Box.box {pm & model: newModel})

draw : {x : F32, y : F32, width : F32, height : F32}, Model, Elem Model -> Task Model [] 
draw = \bb, model, elem ->
    when elem is
        Button { label, onPress } ->
            {isPressed} <- Core.button { x: bb.x, y: bb.y, width: 120, height: 20 } label |> Task.await

            if isPressed then 
                when onPress model is 
                    None -> Task.ok model
                    Update newModel -> Task.ok newModel
            else 
                Task.ok model
            
        Col children ->
            when children is 
                [first, second, third] -> 
                    firstBB = {x : bb.x, y : bb.y, width : bb.width, height : 120}
                    secondBB = {x : bb.x, y : bb.y + 50, width : bb.width, height : 120}
                    thirdBB = {x : bb.x, y : bb.y + 100, width : bb.width, height : 120}
                    model1 <- draw firstBB model first |> Task.await
                    model2 <- draw secondBB model1 second |> Task.await
                    model3 <- draw thirdBB model2 third |> Task.await
                
                    Task.ok model3                    
                _ -> Task.ok model
            
        Text { label, color } -> 
            
            {} <- Core.text label { x: bb.x, y: bb.y, size: 20, color } |> Task.await
            Task.ok model

        None -> Task.ok model

# drawThreeChildren : {x : F32, y : F32, width : F32, height : F32}, Model, Elem Model, Elem Model, Elem Model -> Task Model []
# drawThreeChildren = \bb, model, first, second, third ->

#     model1 <- draw bb model first |> Task.await
#     model2 <- draw bb model1 second |> Task.await
#     model3 <- draw bb model2 third |> Task.await

#     Task.ok model3

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
