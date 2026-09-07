## Shared host-owned sound value.
##
## The handle is an opaque, reference-counted native resource identity for a
## decoded short sound effect. Loading and playback remain platform operations;
## this value lets reusable packages retain sound identity without importing
## the platform.
import Handle

AudioSound := { handle : AudioSoundHandle }.{
	AudioSoundHandle : Handle([SoundResource])

	## Resource-free sound value for pure tests.
	##
	## The handle never resolves to a host resource. Do not use it to test
	## loading, playback, or resource lifetime.
	stub : AudioSound
	stub = { handle: Handle.stub }
}
