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

Model : {}

main : Program
main = { init, update }

init : Task Model []
init = 

    {} <- Core.setWindowSize {width: 400, height: 200} |> Task.await

    Task.ok {}

update : Model -> Task Model []
update = \model -> Task.ok model
