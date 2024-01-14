app "basic"
    packages {
        ray: "../platform/main.roc",
    }
    imports [ray.Task.{ Task }]
    provides [main, Model] to ray

Program : {
    init : Task Model [],
    update : Model -> Task Model [],
}

Model : {}

main : Program
main = { init, update }

init : Task Model []
init = Task.ok {}

update : Model -> Task Model []
update = \model -> Task.ok model
