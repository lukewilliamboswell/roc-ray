## Shared host-owned texture value.
##
## The handle is an opaque, reference-counted native resource identity. Width
## and height are descriptive pixel metadata kept directly on the value for
## pure layout and source-rectangle calculations.
import Handle

Texture := {
	handle : TextureHandle,
	width : F32,
	height : F32,
}.{
	TextureHandle : Handle([TextureResource])

	## Resource-free texture value for pure tests.
	##
	## The handle never resolves to a host resource. Copy this value with the
	## dimensions needed by the test. Do not use it to test drawing, mutation,
	## sampling configuration, or resource lifetime.
	stub : Texture
	stub = {
		handle: Handle.stub,
		width: 0,
		height: 0,
	}
}
