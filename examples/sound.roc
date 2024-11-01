app [Model, init!, render!] { rr: platform "../platform/main.roc" }

# https://www.raylib.com/examples/audio/loader.html?name=audio_sound_loading

import rr.RocRay
import rr.Keys
import rr.Sound
import rr.Draw

Model : {
    wav : RocRay.Sound,
    ogg : RocRay.Sound,
}

init! : {} => Result Model _
init! = \{} ->

    RocRay.initWindow! {
        title: "Making Sounds",
        width: 800,
        height: 450,
    }

    # TODO make this more normal once we have `try`
    when (Sound.load! "examples/assets/sound/sound.wav", Sound.load! "examples/assets/sound/target.ogg") is
        (Ok wav, Ok ogg) -> Ok { wav, ogg }
        _ -> Err FailedToLoadSound

render! : Model, RocRay.PlatformState => Result Model []
render! = \model, { keys } ->

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
            Ok model

        None ->
            Ok model
