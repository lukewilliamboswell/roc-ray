## Audio module - short sound effects, streamed music, and procedural tones.
##
## Load or generate resources during initialization and keep the opaque values
## in your model. Sound and music are distinct types, so they cannot be mixed by
## accident. Their final Roc reference automatically unloads the host resource.
import AudioHost

Audio := [].{

	## Host-owned short sound effect. Use receiver methods such as `sound.play!()`.
	Sound :: { resource : AudioHost.Sound }.{

		## Start playback from the beginning.
		play! : Sound => {}
		play! = |sound| AudioHost.play_sound!(sound.resource)

		## Stop playback and rewind to the beginning.
		stop! : Sound => {}
		stop! = |sound| AudioHost.stop_sound!(sound.resource)

		## Pause playback at the current position.
		pause! : Sound => {}
		pause! = |sound| AudioHost.pause_sound!(sound.resource)

		## Resume a paused sound.
		resume! : Sound => {}
		resume! = |sound| AudioHost.resume_sound!(sound.resource)

		## Whether this sound is currently playing.
		is_playing! : Sound => Bool
		is_playing! = |sound| AudioHost.is_sound_playing!(sound.resource)

		## Set volume, clamped by the host to 0 through 1.
		set_volume! : Sound, F32 => {}
		set_volume! = |sound, volume| AudioHost.set_sound_volume!(sound.resource, volume)

		## Set pitch multiplier. Non-positive values are clamped by the host.
		set_pitch! : Sound, F32 => {}
		set_pitch! = |sound, pitch| AudioHost.set_sound_pitch!(sound.resource, pitch)

		## Set stereo pan, clamped by the host to -1 through 1.
		set_pan! : Sound, F32 => {}
		set_pan! = |sound, pan| AudioHost.set_sound_pan!(sound.resource, pan)

		## Play this sound at its default volume, pitch, and pan, as an action a
		## pure `update` can return. Receiver form: `sound.play()`.
		play : Sound -> [PlaySound(Playback), ..]
		play = |sound| PlaySound(sound.playback())

		## The settings this sound plays at by default, so a `PlaySound` action
		## can adjust one of them without spelling out the rest:
		## `sound.playback().with_pitch(0.8).play()`.
		playback : Sound -> Playback
		playback = |sound| Playback.({ sound: sound, volume: 1, pitch: 1, pan: 0 })
	}

	## A sound together with the settings it should be played at.
	##
	## Volume, pitch, and pan are applied in that order before playback starts.
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

		## Turn these settings into an action. Receiver form: `settings.play()`.
		play : Playback -> [PlaySound(Playback), ..]
		play = |settings| PlaySound(settings)

		## Apply the settings and start playback.
		##
		## The platform calls this to service a `PlaySound` action; an effectful
		## context such as `init!` can call it directly.
		play! : Playback => {}
		play! = |Playback.(settings)| {
			settings.sound.set_volume!(settings.volume)
			settings.sound.set_pitch!(settings.pitch)
			settings.sound.set_pan!(settings.pan)
			settings.sound.play!()
		}
	}

	## Host-owned streamed music. The platform updates active streams each frame.
	Music :: { resource : AudioHost.Music }.{

		## Start or restart playback.
		play! : Music => {}
		play! = |music| AudioHost.play_music!(music.resource)

		## Stop playback and rewind.
		stop! : Music => {}
		stop! = |music| AudioHost.stop_music!(music.resource)

		## Pause at the current position.
		pause! : Music => {}
		pause! = |music| AudioHost.pause_music!(music.resource)

		## Resume paused playback.
		resume! : Music => {}
		resume! = |music| AudioHost.resume_music!(music.resource)

		## Set stream volume, clamped to 0 through 1.
		set_volume! : Music, F32 => {}
		set_volume! = |music, volume| AudioHost.set_music_volume!(music.resource, volume)

		## Set stream pitch multiplier.
		set_pitch! : Music, F32 => {}
		set_pitch! = |music, pitch| AudioHost.set_music_pitch!(music.resource, pitch)

		## Set stereo pan, clamped to -1 through 1.
		set_pan! : Music, F32 => {}
		set_pan! = |music, pan| AudioHost.set_music_pan!(music.resource, pan)

		## Enable or disable automatic looping.
		set_looping! : Music, Bool => {}
		set_looping! = |music, looping| AudioHost.set_music_looping!(music.resource, looping)

		## Whether this stream is currently playing.
		is_playing! : Music => Bool
		is_playing! = |music| AudioHost.is_music_playing!(music.resource)

		## Seek to seconds from the start. Negative values are clamped to zero.
		seek! : Music, F32 => {}
		seek! = |music, seconds| AudioHost.seek_music!(music.resource, seconds)

		## Total stream length in seconds, or zero for an invalid resource.
		length! : Music => F32
		length! = |music| AudioHost.music_length!(music.resource)

		## Current playback position in seconds.
		time_played! : Music => F32
		time_played! = |music| AudioHost.music_time_played!(music.resource)

		## Set stream volume as an action a pure `update` can return, clamped by
		## the host to 0 through 1. Receiver form: `music.set_volume(0.13)`.
		set_volume : Music, F32 -> [SetMusicVolume({ music : Music, volume : F32 }), ..]
		set_volume = |music, volume| SetMusicVolume({ music: music, volume: volume })
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
	load_sound! : Str => Try(Sound, [SoundLoadFailed, ResourceLimit, ..])
	load_sound! = |path| loaded_sound_from_resource(AudioHost.load_sound!(path))

	## Load a streamed music file. Keep the returned value in the app model.
	load_music! : Str => Try(Music, [MusicLoadFailed, ResourceLimit, ..])
	load_music! = |path| music_from_resource(AudioHost.load_music!(path))

	## Generate a reusable procedural sound. Generation can fail if the fixed
	## host resource heap is exhausted, so initialization should propagate the
	## returned error.
	gen_sound! : GenSound => Try(Sound, [SoundGenerationFailed, ResourceLimit, ..])
	gen_sound! = |cfg| generated_sound_from_resource(AudioHost.gen_sound!(raw_config(cfg)))

	## Generate a reusable sine tone. `freq` is Hz and `ms` is milliseconds.
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
