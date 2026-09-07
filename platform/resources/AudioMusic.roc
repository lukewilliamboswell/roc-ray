## Private host-owned music-stream value.
##
## Internal typed ARC identity used by platform adapters and the native host.
## Applications use the corresponding public resource API.
import Handle

AudioMusic := { handle : AudioMusicHandle }.{
	AudioMusicHandle : Handle([MusicResource])

	## Resource-free music value for pure tests.
	##
	## The handle never resolves to a host resource. Do not use it to test
	## loading, playback, seeking, or resource lifetime.
	stub : AudioMusic
	stub = { handle: Handle.stub }
}
