app "basic"
    packages {
        ray: "https://github.com/lukewilliamboswell/roc-ray/releases/download/test/WaRodymdcnmfXFOj0XdNV9tauWNB66qpDh51v9ab4GQ.tar.br",
    }
    imports [ray.Task.{ Task }, ray.Core]
    provides [main, Model] to ray

Program : {
    init : Task Model [],
    update : Model -> Task Model [],
}

Model : {}

main : Program
main = { init, update }

init : Task Model []
init = 

    {} <- Core.setWindowSize {width: 400, height: 400} |> Task.await

    Task.ok {}

update : Model -> Task Model []
update = \model -> 

    _ <- Core.drawGuiButton {x: 100, y: 100, width: 200, height: 100 } "DO NOTHING" |> Task.await

    {isPressed} <- Core.drawGuiButton {x: 100, y: 250, width: 200, height: 100 } "Click Me to EXIT" |> Task.await

    if isPressed then 
        {} <- Core.exit |> Task.await
        Task.ok model
    else 
        Task.ok model

    
