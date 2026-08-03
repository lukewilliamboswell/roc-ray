## Audio module - short sound effects, streamed music, and procedural tones.
##
## Load or generate resources during initialization and keep the opaque values
## in your model. Sound and music are distinct types, so they cannot be mixed by
## accident. Their final Roc reference automatically unloads the host resource.
import AudioHost

Audio := [].{

	## Host-owned short sound effect. Use receiver methods such as `sound.play!()`.
	Sound :: { resource : Box(U64) }.{

		## Start playback from the beginning.
		play! : Sound => {}
		play! = |sound| AudioHost.play_sound!(sound_handle(sound))

		## Stop playback and rewind to the beginning.
		stop! : Sound => {}
		stop! = |sound| AudioHost.stop_sound!(sound_handle(sound))

		## Pause playback at the current position.
		pause! : Sound => {}
		pause! = |sound| AudioHost.pause_sound!(sound_handle(sound))

		## Resume a paused sound.
		resume! : Sound => {}
		resume! = |sound| AudioHost.resume_sound!(sound_handle(sound))

		## Whether this sound is currently playing.
		is_playing! : Sound => Bool
		is_playing! = |sound| AudioHost.is_sound_playing!(sound_handle(sound))

		## Set volume, clamped by the host to 0 through 1.
		set_volume! : Sound, F32 => {}
		set_volume! = |sound, volume| AudioHost.set_sound_volume!(sound_handle(sound), volume)

		## Set pitch multiplier. Non-positive values are clamped by the host.
		set_pitch! : Sound, F32 => {}
		set_pitch! = |sound, pitch| AudioHost.set_sound_pitch!(sound_handle(sound), pitch)

		## Set stereo pan, clamped by the host to -1 through 1.
		set_pan! : Sound, F32 => {}
		set_pan! = |sound, pan| AudioHost.set_sound_pan!(sound_handle(sound), pan)
	}

	## Host-owned streamed music. The platform updates active streams each frame.
	Music :: { resource : Box(U64) }.{

		## Start or restart playback.
		play! : Music => {}
		play! = |music| AudioHost.play_music!(music_handle(music))

		## Stop playback and rewind.
		stop! : Music => {}
		stop! = |music| AudioHost.stop_music!(music_handle(music))

		## Pause at the current position.
		pause! : Music => {}
		pause! = |music| AudioHost.pause_music!(music_handle(music))

		## Resume paused playback.
		resume! : Music => {}
		resume! = |music| AudioHost.resume_music!(music_handle(music))

		## Set stream volume, clamped to 0 through 1.
		set_volume! : Music, F32 => {}
		set_volume! = |music, volume| AudioHost.set_music_volume!(music_handle(music), volume)

		## Set stream pitch multiplier.
		set_pitch! : Music, F32 => {}
		set_pitch! = |music, pitch| AudioHost.set_music_pitch!(music_handle(music), pitch)

		## Set stereo pan, clamped to -1 through 1.
		set_pan! : Music, F32 => {}
		set_pan! = |music, pan| AudioHost.set_music_pan!(music_handle(music), pan)

		## Enable or disable automatic looping.
		set_looping! : Music, Bool => {}
		set_looping! = |music, looping| AudioHost.set_music_looping!(music_handle(music), looping)

		## Whether this stream is currently playing.
		is_playing! : Music => Bool
		is_playing! = |music| AudioHost.is_music_playing!(music_handle(music))

		## Seek to seconds from the start. Negative values are clamped to zero.
		seek! : Music, F32 => {}
		seek! = |music, seconds| AudioHost.seek_music!(music_handle(music), seconds)

		## Total stream length in seconds, or zero for an invalid resource.
		length! : Music => F32
		length! = |music| AudioHost.music_length!(music_handle(music))

		## Current playback position in seconds.
		time_played! : Music => F32
		time_played! = |music| AudioHost.music_time_played!(music_handle(music))
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
	load_sound! : Str => Try(Sound, [SoundLoadFailed, ..])
	load_sound! = |path| loaded_sound_from_resource(AudioHost.load_sound!(path))

	## Load a streamed music file. Keep the returned value in the app model.
	load_music! : Str => Try(Music, [MusicLoadFailed, ..])
	load_music! = |path| music_from_resource(AudioHost.load_music!(path))

	## Generate a reusable procedural sound. Generation can fail if the fixed
	## host resource heap is exhausted, so initialization should propagate the
	## returned error.
	gen_sound! : GenSound => Try(Sound, [SoundGenerationFailed, ..])
	gen_sound! = |cfg| generated_sound_from_resource(AudioHost.gen_sound!(raw_config(cfg)))

	## Generate a reusable sine tone. `freq` is Hz and `ms` is milliseconds.
	gen_tone! : { freq : F32, ms : I32 } => Try(Sound, [SoundGenerationFailed, ..])
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

loaded_sound_from_resource : Box(U64) -> Try(Audio.Sound, [SoundLoadFailed, ..])
loaded_sound_from_resource = |resource|
	if Box.unbox(resource) == 0 Err(SoundLoadFailed) else Ok({ resource: resource })

generated_sound_from_resource : Box(U64) -> Try(Audio.Sound, [SoundGenerationFailed, ..])
generated_sound_from_resource = |resource|
	if Box.unbox(resource) == 0 Err(SoundGenerationFailed) else Ok({ resource: resource })

music_from_resource : Box(U64) -> Try(Audio.Music, [MusicLoadFailed, ..])
music_from_resource = |resource|
	if Box.unbox(resource) == 0 Err(MusicLoadFailed) else Ok({ resource: resource })

sound_handle : Audio.Sound -> U64
sound_handle = |sound| Box.unbox(sound.resource)

music_handle : Audio.Music -> U64
music_handle = |music| Box.unbox(music.resource)

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
