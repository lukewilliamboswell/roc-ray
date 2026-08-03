## Internal audio transport and hosted effects.
##
## This module is intentionally not exposed by the platform package.
AudioHost := [].{
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

	gen_tone! : { freq : F32, ms : I32 } => Box(U64)
	gen_sound! : GenSound => Box(U64)
	load_sound! : Str => Box(U64)
	load_music! : Str => Box(U64)
	play_sound! : U64 => {}
	stop_sound! : U64 => {}
	pause_sound! : U64 => {}
	resume_sound! : U64 => {}
	is_sound_playing! : U64 => Bool
	set_sound_volume! : U64, F32 => {}
	set_sound_pitch! : U64, F32 => {}
	set_sound_pan! : U64, F32 => {}
	play_music! : U64 => {}
	stop_music! : U64 => {}
	pause_music! : U64 => {}
	resume_music! : U64 => {}
	set_music_volume! : U64, F32 => {}
	set_music_pitch! : U64, F32 => {}
	set_music_pan! : U64, F32 => {}
	set_music_looping! : U64, Bool => {}
	is_music_playing! : U64 => Bool
	seek_music! : U64, F32 => {}
	music_length! : U64 => F32
	music_time_played! : U64 => F32
	set_master_volume! : F32 => {}
}
