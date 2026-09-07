## Spark Run textures, font, music, and sound effects loaded at startup.
import rr.Assets
import rr.Audio
import rr.Draw
import rr.Text

GameAssets := {
	characters : Draw.Texture,
	tiles : Draw.Texture,
	font : Text.Font,
	sounds : Sounds,
}.{
	Sounds : {
		collect : Audio.Sound,
		hurt : Audio.Sound,
		win : Audio.Sound,
		lose : Audio.Sound,
		gate : Audio.Sound,
		dash : Audio.Sound,
		sparkle : Audio.Sound,
		music : Audio.Music,
	}

	## Loads every texture, font, sound, and music stream before the first frame.
	load! = || {
		store = Assets.Store.open!(Assets.working_directory("examples/top_down/assets"))?
		characters = Assets.load_texture!(store, "kenney-topdown/characters.png")?
		tiles = Assets.load_texture!(store, "kenney-topdown/tiles.png")?
		font = Draw.default_font!()
		sounds = load_sounds!()?
		Ok({ characters, tiles, font, sounds })
	}
}

collect_path = "examples/top_down/assets/kenney-audio/sfx/collect.ogg"

hurt_path = "examples/top_down/assets/kenney-audio/sfx/hurt.ogg"

win_path = "examples/top_down/assets/kenney-audio/sfx/win.ogg"

lose_path = "examples/top_down/assets/kenney-audio/sfx/lose.ogg"

gate_path = "examples/top_down/assets/kenney-audio/sfx/gate.ogg"

dash_path = "examples/top_down/assets/kenney-audio/sfx/dash.ogg"

music_path = "examples/top_down/assets/kenney-audio/music/spark_loop.wav"

music_volume = 0.13.F32

## Generates a compact fallback effect when an audio file cannot be loaded.
make_sound! : Audio.Waveform, F32, F32, I32, F32 => Try(Audio.Sound, [ResourceLimit, SoundGenerationFailed, ..])
make_sound! = |waveform, from, to, ms, volume|
	Audio.gen_sound!({ waveform, freq_start: from, freq_end: to, ms, attack_ms: 2, decay_ms: 24, sustain: 0.45, release_ms: 45, volume })

## Loads a sound file or retains its generated fallback.
load_sound_or! : Str, Audio.Sound => Audio.Sound
load_sound_or! = |path, fallback|
	match Audio.load_sound!(path) {
		Ok(sound) => sound
		Err(_) => fallback
	}

## Loads the complete sound set and configures looping background music.
load_sounds! = || {
	collect = load_sound_or!(collect_path, make_sound!(Sine, 880, 1160, 110, 0.55)?)
	hurt = load_sound_or!(hurt_path, make_sound!(Noise, 180, 70, 220, 0.7)?)
	win = load_sound_or!(win_path, make_sound!(Square, 640, 1280, 520, 0.45)?)
	lose = load_sound_or!(lose_path, make_sound!(Saw, 120, 45, 520, 0.5)?)
	gate = load_sound_or!(gate_path, make_sound!(Square, 220, 390, 240, 0.45)?)
	dash = load_sound_or!(dash_path, make_sound!(Noise, 520, 120, 130, 0.38)?)
	sparkle = make_sound!(Sine, 980, 1620, 140, 0.36)?
	music = Audio.load_music!(music_path)?
	music.set_volume!(music_volume)
	music.set_looping!(Bool.True)
	Ok({ collect, hurt, win, lose, gate, dash, sparkle, music })
}
