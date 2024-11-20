app [Model, init!, render!] { rr: platform "../platform/main.roc" }

import rr.RocRay
import rr.Music

Model : {}

init! : {} => Result Model _
init! = \{} ->
    RocRay.initWindow! { title: "Music Deinit" }

    _track = Music.load!? "examples/assets/music/benny-hill.mp3"

    Ok {}

render! : Model, RocRay.PlatformState => Result Model []
render! = \model, _ ->
    RocRay.exit! {}

    Ok model
