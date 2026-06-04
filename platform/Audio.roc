## Audio module - sound playback for the Roc raylib platform.
##
## A `Sound` is a refcounted `Box` handle to a host-owned sound. Generate a
## tone once (e.g. in init!), keep the handle in your model, then `play!` it on
## game events. Because it's a Box it can be stored, copied and shared safely;
## the box memory is released by Roc's refcounting when the last copy is
## dropped. (The underlying raylib sound is freed by the host at shutdown - a
## per-handle drop hook is future work.)
Audio := [].{

	## A handle to a host-owned sound.
	Sound : Box(U64)

	## Raw hosted effects: the host deals only in a scalar handle (a sound-table
	## index). The public gen_tone!/play! wrap that scalar in a Box.
	gen_tone_raw! : { freq : F32, ms : I32 } => U64
	play_raw! : U64 => {}

	## Generate a short sine tone and return a handle to it.
	## `freq` is the pitch in Hz; `ms` is the duration in milliseconds
	## (clamped by the host to a small maximum). Call this sparingly - e.g.
	## once at startup - and reuse the handle, rather than per frame.
	gen_tone! : { freq : F32, ms : I32 } => Sound
	gen_tone! = |cfg| Box.box(gen_tone_raw!(cfg))

	## Play a previously generated sound.
	play! : Sound => {}
	play! = |sound| play_raw!(Box.unbox(sound))
}
