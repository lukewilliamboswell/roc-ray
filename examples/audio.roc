app [Model, init, render] { rr: platform "../platform/main.roc" }

# https://www.raylib.com/examples/audio/loader.html?name=audio_sound_loading

import rr.RocRay
import rr.Keys
import rr.Sound
import rr.Draw

Model : {
    wav : RocRay.Sound,
    ogg : RocRay.Sound,
}

init : Task Model []
init =

    RocRay.initWindow! {
        title: "Making Sounds",
        width: 800,
        height: 450,
    }

    wav = Sound.load! "resources/sound.wav"
    ogg = Sound.load! "resources/target.ogg"

    Task.ok { wav, ogg }

render : Model, RocRay.PlatformState -> Task Model []
render = \model, { keys } ->

    Draw.draw! White \{} ->

        Draw.text! {
            text: "Press SPACE to PLAY the WAV sound",
            pos: { x: 200, y: 180 },
            size: 20,
            color: Gray,
        }

        Draw.text! {
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

    when chosenSound is
        Play sound ->
            Sound.play! sound
            Task.ok model

        None ->
            Task.ok model
