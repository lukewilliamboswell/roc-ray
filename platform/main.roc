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

defaultWidth = 360u32
defaultHeight = 360u32

init : Task (Box Model) []
init =

    {} <- Core.setWindowSize { width: defaultWidth, height: defaultHeight } |> Task.await

    main.init { width: Num.toF32 defaultWidth, height: Num.toF32 defaultHeight }
    |> Task.map Box.box

update : Box Model -> Task (Box Model) []
update = \boxedModel ->
    boxedModel
    |> Box.unbox
    |> \model ->
        elem <- main.render model |> Task.await

        # TODO figure out how to do layout
        draw model { x: 0, y: 0, width: Num.toF32 defaultWidth, height: Num.toF32 defaultHeight } elem
    |> Task.map Box.box

draw : Model, { x : F32, y : F32, width : F32, height : F32 }, Elem Model -> Task Model []
draw = \model, bb, elem ->

    defaultStepX = 120
    defaultStepY = 50

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
                [first] -> draw model bb first
                [first, second] ->
                    firstBB = { x: bb.x, y: bb.y + (0 * defaultStepX), width: defaultStepX, height: bb.height }
                    secondBB = { x: bb.x + (1 * defaultStepX), y: bb.y, width: defaultStepX, height: bb.height }
                    model1 <- draw model firstBB first |> Task.await
                    model2 <- draw model1 secondBB second |> Task.await

                    Task.ok model2

                [first, second, third] ->
                    firstBB = { x: bb.x, y: bb.y + (0 * defaultStepX), width: defaultStepX, height: bb.height }
                    secondBB = { x: bb.x + (1 * defaultStepX), y: bb.y, width: defaultStepX, height: bb.height }
                    thirdBB = { x: bb.x + (2 * defaultStepX), y: bb.y, width: defaultStepX, height: bb.height }
                    model1 <- draw model firstBB first |> Task.await
                    model2 <- draw model1 secondBB second |> Task.await
                    model3 <- draw model2 thirdBB third |> Task.await

                    Task.ok model3

                _ -> Task.ok model

        Col children ->
            when children is
                [first] -> draw model bb first
                [first, second] ->
                    firstBB = { x: bb.x, y: bb.y + (0 * defaultStepY), width: bb.width, height: defaultStepY }
                    secondBB = { x: bb.x, y: bb.y + (1 * defaultStepY), width: bb.width, height: defaultStepY }
                    model1 <- draw model firstBB first |> Task.await
                    model2 <- draw model1 secondBB second |> Task.await

                    Task.ok model2

                [first, second, third] ->
                    firstBB = { x: bb.x, y: bb.y + (0 * defaultStepY), width: bb.width, height: defaultStepY }
                    secondBB = { x: bb.x, y: bb.y + (1 * defaultStepY), width: bb.width, height: defaultStepY }
                    thirdBB = { x: bb.x, y: bb.y + (2 * defaultStepY), width: bb.width, height: defaultStepY }
                    model1 <- draw model firstBB first |> Task.await
                    model2 <- draw model1 secondBB second |> Task.await
                    model3 <- draw model2 thirdBB third |> Task.await

                    Task.ok model3

                _ -> Task.ok model

        Text { label, color } ->
            {} <- Core.text label { x: bb.x, y: bb.y, size: 15, color } |> Task.await
            Task.ok model

        None -> Task.ok model
