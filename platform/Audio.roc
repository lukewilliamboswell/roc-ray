## Audio module - sound and music playback for the Roc raylib platform.
##
## `Sound` and `Music` are refcounted `Box` handles to host-owned audio
## resources. Load or generate them once (e.g. in init!), keep the handles in
## your model, then play them on game events. Box memory is released by Roc's
## refcounting when the last copy is dropped. The underlying raylib resources
## are freed by the host at shutdown.
Audio := [].{

	## A handle to a host-owned sound.
	Sound : Box(U64)

	## A handle to a host-owned streaming music resource.
	Music : Box(U64)

	Waveform := [Sine, Square, Triangle, Saw, Noise]

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

	GenSoundRaw : {
		waveform : U8,
		freq_start : F32,
		freq_end : F32,
		ms : I32,
		attack_ms : I32,
		decay_ms : I32,
		sustain : F32,
		release_ms : I32,
		volume : F32,
	}

	## Raw hosted effects: the host deals only in scalar handles. Public helpers
	## wrap successful handles in Box values.
	gen_tone_raw! : { freq : F32, ms : I32 } => U64
	gen_sound_raw! : GenSoundRaw => U64
	load_sound_raw! : Str => U64
	load_music_raw! : Str => U64
	play_raw! : U64 => {}
	set_volume_raw! : U64, F32 => {}
	set_pitch_raw! : U64, F32 => {}
	set_pan_raw! : U64, F32 => {}
	play_music_raw! : U64 => {}
	stop_music_raw! : U64 => {}
	pause_music_raw! : U64 => {}
	resume_music_raw! : U64 => {}
	set_music_volume_raw! : U64, F32 => {}
	set_music_pitch_raw! : U64, F32 => {}
	set_music_pan_raw! : U64, F32 => {}
	set_music_looping_raw! : U64, Bool => {}

	waveform_code : Waveform -> U8
	waveform_code = |waveform|
		match waveform {
			Sine => 0
			Square => 1
			Triangle => 2
			Saw => 3
			Noise => 4
		}

	raw_config : GenSound -> GenSoundRaw
	raw_config = |cfg| {
		waveform: Audio.waveform_code(cfg.waveform),
		freq_start: cfg.freq_start,
		freq_end: cfg.freq_end,
		ms: cfg.ms,
		attack_ms: cfg.attack_ms,
		decay_ms: cfg.decay_ms,
		sustain: cfg.sustain,
		release_ms: cfg.release_ms,
		volume: cfg.volume,
	}

	sound_from_handle : U64 -> Try(Sound, [SoundLoadFailed, ..])
	sound_from_handle = |handle|
		if handle == 0 {
			Err(SoundLoadFailed)
		} else {
			Ok(Box.box(handle))
		}

	music_from_handle : U64 -> Try(Music, [MusicLoadFailed, ..])
	music_from_handle = |handle|
		if handle == 0 {
			Err(MusicLoadFailed)
		} else {
			Ok(Box.box(handle))
		}

	## Load a short sound effect from disk.
	load_sound! : Str => Try(Sound, [SoundLoadFailed, ..])
	load_sound! = |path| Audio.sound_from_handle(Audio.load_sound_raw!(path))

	## Load a streaming music file from disk. The host updates loaded streams
	## automatically each frame.
	load_music! : Str => Try(Music, [MusicLoadFailed, ..])
	load_music! = |path| Audio.music_from_handle(Audio.load_music_raw!(path))

	## Generate a short procedural sound and return a handle to it.
	## Call this sparingly - e.g. once at startup - and reuse the handle.
	gen_sound! : GenSound => Sound
	gen_sound! = |cfg| Box.box(Audio.gen_sound_raw!(Audio.raw_config(cfg)))

	## Generate a short sine tone and return a handle to it.
	## `freq` is the pitch in Hz; `ms` is the duration in milliseconds
	## (clamped by the host to a small maximum). Call this sparingly - e.g.
	## once at startup - and reuse the handle, rather than per frame.
	gen_tone! : { freq : F32, ms : I32 } => Sound
	gen_tone! = |cfg|
		Audio.gen_sound!(
			{
				waveform: Sine,
				freq_start: cfg.freq,
				freq_end: cfg.freq,
				ms: cfg.ms,
				attack_ms: 5,
				decay_ms: 12,
				sustain: 0.8,
				release_ms: 8,
				volume: 0.55,
			},
		)

	## Play a previously generated sound.
	play! : Sound => {}
	play! = |sound| Audio.play_raw!(Box.unbox(sound))

	## Set playback volume for a sound. The host clamps volume to [0, 1].
	set_volume! : Sound, F32 => {}
	set_volume! = |sound, volume| Audio.set_volume_raw!(Box.unbox(sound), volume)

	## Set playback pitch for a sound. The host clamps pitch to a positive range.
	set_pitch! : Sound, F32 => {}
	set_pitch! = |sound, pitch| Audio.set_pitch_raw!(Box.unbox(sound), pitch)

	## Set playback pan for a sound. The host clamps pan to [-1, 1].
	set_pan! : Sound, F32 => {}
	set_pan! = |sound, pan| Audio.set_pan_raw!(Box.unbox(sound), pan)

	play_music! : Music => {}
	play_music! = |music| Audio.play_music_raw!(Box.unbox(music))

	stop_music! : Music => {}
	stop_music! = |music| Audio.stop_music_raw!(Box.unbox(music))

	pause_music! : Music => {}
	pause_music! = |music| Audio.pause_music_raw!(Box.unbox(music))

	resume_music! : Music => {}
	resume_music! = |music| Audio.resume_music_raw!(Box.unbox(music))

	set_music_volume! : Music, F32 => {}
	set_music_volume! = |music, volume| Audio.set_music_volume_raw!(Box.unbox(music), volume)

	set_music_pitch! : Music, F32 => {}
	set_music_pitch! = |music, pitch| Audio.set_music_pitch_raw!(Box.unbox(music), pitch)

	set_music_pan! : Music, F32 => {}
	set_music_pan! = |music, pan| Audio.set_music_pan_raw!(Box.unbox(music), pan)

	set_music_looping! : Music, Bool => {}
	set_music_looping! = |music, looping| Audio.set_music_looping_raw!(Box.unbox(music), looping)

	expect waveform_code(Sine) == 0
	expect waveform_code(Noise) == 4
}
