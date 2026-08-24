## Internal audio transport and hosted effects.
##
## This module is intentionally not exposed by the platform package. Every
## resource operation transfers an owning nominal Box to the host so ARC keeps
## the native resource live through the complete call.
AudioHost := [].{
	Sound :: Box(U64).{

		## The invalid token, as a resource-free handle. See `Audio.Sound.stub`.
		stub : Sound
		stub = Sound.(Box.box(U64.highest))
	}

	Music :: Box(U64).{

		## The invalid token, as a resource-free handle. See `Audio.Music.stub`.
		stub : Music
		stub = Music.(Box.box(U64.highest))
	}

	SoundResult : { sound : Sound, err : U8 }

	MusicResult : { music : Music, err : U8 }

	GenSound : {
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

	gen_tone! : { freq : F32, ms : I32 } => SoundResult
	gen_sound! : GenSound => SoundResult
	load_sound! : Str => SoundResult
	load_music! : Str => MusicResult
	play_sound! : Sound => {}
	stop_sound! : Sound => {}
	pause_sound! : Sound => {}
	resume_sound! : Sound => {}
	is_sound_playing! : Sound => Bool
	set_sound_volume! : Sound, F32 => {}
	set_sound_pitch! : Sound, F32 => {}
	set_sound_pan! : Sound, F32 => {}
	play_music! : Music => {}
	stop_music! : Music => {}
	pause_music! : Music => {}
	resume_music! : Music => {}
	set_music_volume! : Music, F32 => {}
	set_music_pitch! : Music, F32 => {}
	set_music_pan! : Music, F32 => {}
	set_music_looping! : Music, Bool => {}
	is_music_playing! : Music => Bool
	seek_music! : Music, F32 => {}
	music_length! : Music => F32
	music_time_played! : Music => F32
	set_master_volume! : F32 => {}
}
