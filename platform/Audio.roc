## Short sound effects, streamed music, and procedural tones.
##
## Load or generate resources in `init!` and keep the opaque values in the
## model. Sound and music are distinct types, so they cannot be mixed by
## accident. Their final Roc reference automatically unloads the host resource.
##
## ```roc
## init! = App.init(
##     App.default,
##     |_startup| Ok({ blip: Audio.gen_tone!({ freq: 440, ms: 120 })? }),
## )
## ```
##
## ```roc
## if input.devices.key_pressed(KeySpace) {
##     model.blip.playback().with_volume(0.4).play!()
## }
## ```
##
## `load_sound!` and `load_music!` resolve paths against the process working
## directory; they do not use or enforce an `Assets.Store` root.
##
## `Sound` is decoded into memory for short effects. `Music` streams encoded
## bytes for long tracks and is advanced automatically each frame.
##
## The two loaders read the disk, so they wait: `load_sound!` and `load_music!`
## are legal in `init!`, where they block startup, and in tasks, where they
## park the task, and are refused in `update!` and `render!`. To start a track
## or a new effect after startup, call the loader inside `Task.spawn!` and keep
## the resource the task's message carries. `gen_sound!` and `gen_tone!` build
## a `Sound` with no file behind it, so they stay legal in `init!`, `update!`,
## and tasks.
##
## Every other effect here changes what the mixer is doing and is legal in
## `init!`, `update!`, and tasks, and refused in `render!`. The four queries
## that only read a scalar the device already has -- `Sound.is_playing!`,
## `Music.is_playing!`, `Music.length!`, and `Music.time_played!` -- are legal
## in any callback, `render!` included.
import AudioHost

Audio := [].{

	## Host-owned short sound effect. Use receiver methods such as `sound.play!()`.
	##
	## A sound has no volume, pitch, or pan of its own that outlives a play.
	## raylib's are sticky per resource, and every play sets all three, so there
	## is nothing to set once and inherit -- see `Playback`.
	Sound :: { resource : AudioHost.Sound }.{

		## Play this sound at its default volume, pitch, and pan.
		##
		## Equivalent to `sound.playback().play!()`, and stated the same way: the
		## three playback parameters are always set before the sound starts.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		play! : Sound => {}
		play! = |sound| sound.playback().play!()

		## Stop playback and rewind to the beginning.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		stop! : Sound => {}
		stop! = |sound| AudioHost.stop_sound!(sound.resource)

		## Pause playback at the current position.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		pause! : Sound => {}
		pause! = |sound| AudioHost.pause_sound!(sound.resource)

		## Resume a paused sound.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		resume! : Sound => {}
		resume! = |sound| AudioHost.resume_sound!(sound.resource)

		## Whether this sound is currently playing.
		##
		## Legal in any callback, `render!` included.
		is_playing! : Sound => Bool
		is_playing! = |sound| AudioHost.is_sound_playing!(sound.resource)

		## The settings this sound plays at by default, so a play can adjust one
		## of them without spelling out the rest:
		## `sound.playback().with_pitch(0.8).play!()`.
		playback : Sound -> Playback
		playback = |sound| Playback.({ sound: sound, volume: 1, pitch: 1, pan: 0 })

		## Resource-free sound value for pure tests.
		##
		## The handle never resolves to a host resource, so every host path it
		## reaches treats it as an invalid one: playing, stopping, pausing, and
		## resuming it are all no-ops, and `is_playing!` answers `Bool.False`.
		## Put it in a model to reach the app's pure update logic from an
		## `expect`. Do not use it to test playback or resource lifetime.
		stub : Sound
		stub = { resource: AudioHost.Sound.stub }
	}

	## A sound together with the settings it should be played at.
	##
	## Volume, pitch, and pan are applied in that order before playback starts.
	## Every play states all three, so a play cannot inherit what some earlier
	## play left behind on the same host resource. That is why `Sound` has no
	## `set_volume!`: raylib's setters are sticky per sound, and a `PlaySound`
	## overwriting them silently was a trap rather than a feature.
	Playback := { sound : Sound, volume : F32, pitch : F32, pan : F32 }.{

		## Volume for this play, clamped by the host to 0 through 1.
		with_volume : Playback, F32 -> Playback
		with_volume = |Playback.(settings), volume| Playback.({ ..settings, volume: volume })

		## Pitch multiplier for this play. Non-positive values are clamped.
		with_pitch : Playback, F32 -> Playback
		with_pitch = |Playback.(settings), pitch| Playback.({ ..settings, pitch: pitch })

		## Stereo pan for this play, clamped by the host to -1 through 1.
		with_pan : Playback, F32 -> Playback
		with_pan = |Playback.(settings), pan| Playback.({ ..settings, pan: pan })

		## Apply the settings and start playback.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		##
		## Volume, pitch, and pan are all set before the sound starts, so this
		## play cannot inherit what an earlier play left on the same sound.
		play! : Playback => {}
		play! = |Playback.(settings)| {
			AudioHost.set_sound_volume!(settings.sound.resource, settings.volume)
			AudioHost.set_sound_pitch!(settings.sound.resource, settings.pitch)
			AudioHost.set_sound_pan!(settings.sound.resource, settings.pan)
			AudioHost.play_sound!(settings.sound.resource)
		}
	}

	## Host-owned streamed music. The platform updates active streams each frame.
	Music :: { resource : AudioHost.Music }.{

		## Start or restart playback.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		play! : Music => {}
		play! = |music| AudioHost.play_music!(music.resource)

		## Stop playback and rewind.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		stop! : Music => {}
		stop! = |music| AudioHost.stop_music!(music.resource)

		## Pause at the current position.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		pause! : Music => {}
		pause! = |music| AudioHost.pause_music!(music.resource)

		## Resume paused playback.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		resume! : Music => {}
		resume! = |music| AudioHost.resume_music!(music.resource)

		## Set stream volume, clamped to 0 through 1.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		set_volume! : Music, F32 => {}
		set_volume! = |music, volume| AudioHost.set_music_volume!(music.resource, volume)

		## Set stream pitch multiplier.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		set_pitch! : Music, F32 => {}
		set_pitch! = |music, pitch| AudioHost.set_music_pitch!(music.resource, pitch)

		## Set stereo pan, clamped to -1 through 1.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		set_pan! : Music, F32 => {}
		set_pan! = |music, pan| AudioHost.set_music_pan!(music.resource, pan)

		## Enable or disable automatic looping.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		set_looping! : Music, Bool => {}
		set_looping! = |music, looping| AudioHost.set_music_looping!(music.resource, looping)

		## Whether this stream is currently playing.
		##
		## Legal in any callback, `render!` included.
		is_playing! : Music => Bool
		is_playing! = |music| AudioHost.is_music_playing!(music.resource)

		## Seek to seconds from the start. Negative values are clamped to zero.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		seek! : Music, F32 => {}
		seek! = |music, seconds| AudioHost.seek_music!(music.resource, seconds)

		## Total stream length in seconds, or zero for an invalid resource.
		##
		## Legal in any callback, `render!` included.
		length! : Music => F32
		length! = |music| AudioHost.music_length!(music.resource)

		## Current playback position in seconds.
		##
		## Legal in any callback, `render!` included.
		time_played! : Music => F32
		time_played! = |music| AudioHost.music_time_played!(music.resource)

		## Resource-free music value for pure tests.
		##
		## The handle never resolves to a host resource, so every host path it
		## reaches treats it as an invalid one: transport and mutation calls are
		## no-ops, `is_playing!` answers `Bool.False`, and `length!` and
		## `time_played!` answer zero. Put it in a model to reach the app's pure
		## update logic from an `expect`. Do not use it to test playback or
		## resource lifetime.
		stub : Music
		stub = { resource: AudioHost.Music.stub }
	}

	## Procedural waveform used by `gen_sound!`.
	Waveform := [Sine, Square, Triangle, Saw, Noise]

	## Envelope and pitch configuration for a generated sound.
	GenSound : {
		waveform : Waveform,
		freq_start : F32,
		freq_end : F32,
		ms : I32,
		attack_ms : I32,
		decay_ms : I32,
		sustain : F32,
		release_ms : I32,
		volume : F32,
	}

	## Load a short sound effect from disk.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`. The file is read off the
	## frame thread and decoded onto the audio device when the bytes are back.
	## `SoundLoadFailed` covers both a path with nothing behind it and bytes
	## raylib would not decode; the format is taken from the extension, and
	## `.wav`, `.ogg`, `.mp3`, `.qoa` and `.flac` are the ones it reads.
	## A headless host returns a bounded inert `Sound` without reading or
	## decoding the path; playback and queries keep their ordinary no-output
	## resource semantics.
	load_sound! : Str => Try(Sound, [SoundLoadFailed, ResourceLimit, ..])
	load_sound! = |path| loaded_sound_from_resource(AudioHost.load_sound!(path))

	## Load a streamed music file. Keep the returned value in the app model.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`. The file is read off the
	## frame thread and the host keeps those bytes for as long as the stream
	## exists, releasing them with the final reference to the `Music`.
	## `MusicLoadFailed` covers both a path with nothing behind it and bytes
	## raylib would not decode; the format is taken from the extension, and
	## `.wav`, `.ogg`, `.mp3`, `.qoa`, `.flac`, `.xm` and `.mod` are the ones it
	## reads.
	## A headless host returns a bounded inert `Music` without reading or
	## decoding the path or creating/updating a native stream.
	load_music! : Str => Try(Music, [MusicLoadFailed, ResourceLimit, ..])
	load_music! = |path| music_from_resource(AudioHost.load_music!(path))

	## Generate a reusable procedural sound. Generation can fail if the fixed host
	## resource heap is exhausted, so initialization should propagate the returned
	## error.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	gen_sound! : GenSound => Try(Sound, [SoundGenerationFailed, ResourceLimit, ..])
	gen_sound! = |cfg| generated_sound_from_resource(AudioHost.gen_sound!(raw_config(cfg)))

	## Generate a reusable sine tone. `freq` is Hz and `ms` is milliseconds.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	gen_tone! : { freq : F32, ms : I32 } => Try(Sound, [SoundGenerationFailed, ResourceLimit, ..])
	gen_tone! = |cfg|
		Audio.gen_sound!({
			waveform: Sine,
			freq_start: cfg.freq,
			freq_end: cfg.freq,
			ms: cfg.ms,
			attack_ms: 5,
			decay_ms: 12,
			sustain: 0.8,
			release_ms: 8,
			volume: 0.55,
		})

	## Set global output volume for all sounds and music, clamped to 0 through 1.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	set_master_volume! : F32 => {}
	set_master_volume! = |volume| AudioHost.set_master_volume!(volume)

	expect waveform_code(Sine) == 0
	expect waveform_code(Noise) == 4
}

loaded_sound_from_resource : AudioHost.SoundResult -> Try(Audio.Sound, [SoundLoadFailed, ResourceLimit, ..])
loaded_sound_from_resource = |result|
	if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(SoundLoadFailed) else Ok({ resource: result.sound })

generated_sound_from_resource : AudioHost.SoundResult -> Try(Audio.Sound, [SoundGenerationFailed, ResourceLimit, ..])
generated_sound_from_resource = |result|
	if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(SoundGenerationFailed) else Ok({ resource: result.sound })

music_from_resource : AudioHost.MusicResult -> Try(Audio.Music, [MusicLoadFailed, ResourceLimit, ..])
music_from_resource = |result|
	if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(MusicLoadFailed) else Ok({ resource: result.music })

waveform_code : Audio.Waveform -> U8
waveform_code = |waveform|
	match waveform {
		Sine => 0
		Square => 1
		Triangle => 2
		Saw => 3
		Noise => 4
	}

raw_config : Audio.GenSound -> AudioHost.GenSound
raw_config = |cfg| {
	waveform: waveform_code(cfg.waveform),
	freq_start: cfg.freq_start,
	freq_end: cfg.freq_end,
	ms: cfg.ms,
	attack_ms: cfg.attack_ms,
	decay_ms: cfg.decay_ms,
	sustain: cfg.sustain,
	release_ms: cfg.release_ms,
	volume: cfg.volume,
}
