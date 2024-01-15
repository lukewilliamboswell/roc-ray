platform "roc-ray"
    requires { Model } { main : _ }
    exposes [Core]
    packages {}
    imports [Task.{ Task }, Core.{ Color, Elem }]
    provides [mainForHost]

ProgramForHost : {
    init : Task (Box Model) [],
    update : Box Model -> Task (Box Model) [],
}

mainForHost : ProgramForHost
mainForHost = { init, update }

init : Task (Box Model) []
init =

    defaultWidth = 800f32
    defaultHeight = 600f32

    {} <- Core.setWindowSize { width: defaultWidth, height: defaultHeight } |> Task.await

    main.init { width: defaultWidth, height: defaultHeight } 
    |> Task.map Box.box

update : Box Model -> Task (Box Model) []
update = \boxedModel ->
    boxedModel
    |> Box.unbox
    |> \model -> 
        elem <- main.render model |> Task.await 
        draw model { x: 0, y: 0, width: 360, height: 120 } elem
    |> Task.map Box.box

draw : Model, { x : F32, y : F32, width : F32, height : F32 }, Elem Model -> Task Model []
draw = \model, bb, elem ->
    when elem is
        Button { label, onPress } ->
            { isPressed } <- Core.button { x: bb.x, y: bb.y, width: 120, height: 20 } label |> Task.await

            if isPressed then
                when onPress model is
                    None -> Task.ok model
                    Update newModel -> Task.ok newModel
            else
                Task.ok model

        Row children ->
            when children is
                [first, second, third] ->
                    firstBB = { x: bb.x, y: bb.y, width: 120, height: bb.height }
                    secondBB = { x: bb.x + 120, y: bb.y, width: 120, height: bb.height }
                    thirdBB = { x: bb.x + 240, y: bb.y, width: 120, height: bb.height }
                    model1 <- draw model firstBB first |> Task.await
                    model2 <- draw model1 secondBB second |> Task.await
                    model3 <- draw model2 thirdBB third |> Task.await

                    Task.ok model3

                _ -> Task.ok model

        Col children ->
            when children is
                [first, second, third] ->
                    firstBB = { x: bb.x, y: bb.y, width: bb.width, height: 120 }
                    secondBB = { x: bb.x, y: bb.y + 50, width: bb.width, height: 120 }
                    thirdBB = { x: bb.x, y: bb.y + 100, width: bb.width, height: 120 }
                    model1 <- draw model firstBB first |> Task.await
                    model2 <- draw model1 secondBB second |> Task.await
                    model3 <- draw model2 thirdBB third |> Task.await

                    Task.ok model3

                _ -> Task.ok model

        Text { label, color } ->
            {} <- Core.text label { x: bb.x, y: bb.y, size: 15, color } |> Task.await
            Task.ok model

        None -> Task.ok model
