app "basic"
    packages {
        ray: "../platform/main.roc",
    }
    imports [ray.Task.{ Task }, ray.Core]
    provides [main, Model] to ray

Program : {
    init : Task Model [],
    update : Model -> Task Model [],
}

Model : [ScreenA, ScreenB, ScreenC]

main : Program
main = { init, update }

init : Task Model []
init =

    {} <- Core.setWindowSize { width: 400, height: 400 } |> Task.await

    Task.ok ScreenA

update : Model -> Task Model []
update = \model ->
    when model is
        ScreenA ->
            { isPressed } <- Core.button { x: 100, y: 100, width: 200, height: 100 } "GO TO SCREEN B" |> Task.await

            {} <- Core.text { x: 200, y: 250 } { size: 20, color: { r: 0, g: 0, b: 255, a: 255 } } "Ahoy there" |> Task.await

            if isPressed then
                Task.ok ScreenB
            else
                Task.ok model

        ScreenB ->
            { isPressed } <- Core.button { x: 100, y: 100, width: 200, height: 100 } "GO TO SCREEN C" |> Task.await

            if isPressed then
                Task.ok ScreenC
            else
                Task.ok model

        ScreenC ->
            _ <- Core.button { x: 100, y: 100, width: 200, height: 100 } "DO NOTHING" |> Task.await

            { isPressed } <- Core.button { x: 100, y: 250, width: 200, height: 100 } "EXIT" |> Task.await

            if isPressed then
                {} <- Core.exit |> Task.await
                Task.ok model
            else
                Task.ok model

