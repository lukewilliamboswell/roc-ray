app [main, Model] {
    ray: platform "../platform/main.roc",
}

# https://www.raylib.com/examples/audio/loader.html?name=audio_sound_loading

import ray.RocRay exposing [Sound]
import ray.RocRay.Keys as Keys

main = { init, render }

Model : {
    wav : Sound,
    ogg : Sound,
}

init =

    RocRay.setTargetFPS! 60
    RocRay.setWindowSize! { width: 800, height: 450 }
    RocRay.setWindowTitle! "Making Sounds"

    wav =
        RocRay.loadSound "resources/sound.wav"
            |> Task.mapErr! \LoadSoundErr msg -> crash msg

    ogg =
        RocRay.loadSound "resources/target.ogg"
            |> Task.mapErr! \LoadSoundErr msg -> crash msg

    Task.ok { wav, ogg }

render : Model, RocRay.PlatformState -> Task Model []
render = \model, { keys } ->

    RocRay.beginDrawing! White

    RocRay.drawText! {
        text: "Press SPACE to PLAY the WAV sound",
        pos: { x: 200, y: 180 },
        size: 20,
        color: Gray,
    }

    RocRay.drawText! {
        text: "Press ENTER to PLAY the OGG sound",
        pos: { x: 200, y: 220 },
        size: 20,
        color: Gray,
    }

    chosenSound =
        if Keys.pressed keys KeySpace then
            Play model.wav
        else if Keys.pressed keys KeyEnter then
            Play model.ogg
        else
            None

    RocRay.endDrawing!

    when chosenSound is
        Play sound ->
            RocRay.playSound! sound
            Task.ok model

        None ->
            Task.ok model
