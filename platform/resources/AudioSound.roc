## Private host-owned sound value.
##
## Internal typed ARC identity used by platform adapters and the native host.
## Applications use the corresponding public resource API.
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
