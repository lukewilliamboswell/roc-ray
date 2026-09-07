## Shared host-owned music-stream value.
##
## The handle is an opaque, reference-counted native resource identity for a
## streamed music track. Loading and playback remain platform operations; this
## value lets reusable packages retain music identity without importing the
## platform.
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
