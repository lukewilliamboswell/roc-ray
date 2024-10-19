app [main, Model] {
    ray: platform "../platform/main.roc",
}

# https://www.raylib.com/examples/audio/loader.html?name=audio_sound_loading

import ray.Effect
import ray.RocRay
import ray.RocRay.Keys as Keys
import ray.RocRay.Sound as Sound exposing [Sound]

main = { init, render }

Model : {
    wav : Sound,
    ogg : Sound,
}

init : Task Model []
init =
    RocRay.log! "in init" LogFatal

    # FIXME
    # The "in init" above gets logged, but nothing later does.

    RocRay.setTargetFPS! 60

    RocRay.log! "after setTargetFPS" LogFatal

    RocRay.setBackgroundColor! White
    RocRay.setWindowSize! { width: 800, height: 450 }
    RocRay.setWindowTitle! "Sound Loading"

    RocRay.log! "before load wav" LogFatal

    wav = Sound.load! "resources/sound.wav"

    RocRay.log! "after load wav" LogFatal

    ogg = Sound.load! "resources/target.ogg"

    RocRay.log! "after load ogg" LogFatal

    Task.ok { wav, ogg }

render : Model, RocRay.PlatformState -> Task Model []
render = \model, { keys } ->
    RocRay.log! "in render" LogFatal

    RocRay.drawText! {
        text: "Press SPACE to PLAY the WAV sound",
        x: 200,
        y: 180,
        size: 20,
        color: Gray,
    }

    RocRay.drawText! {
        text: "Press ENTER to PLAY the OGG sound",
        x: 200,
        y: 220,
        size: 20,
        color: Gray,
    }

    RocRay.log! "choosing sound" LogFatal

    chosenSound =
        if Keys.pressed keys KeySpace then
            Play model.wav
        else if Keys.pressed keys KeyEnter then
            Play model.ogg
        else
            None

    RocRay.log! "chose sound" LogFatal

    when chosenSound is
        Play sound ->
            Sound.play! sound
            Task.ok model

        None ->
            Task.ok model

