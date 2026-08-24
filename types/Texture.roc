## Shared host-owned texture value.
##
## The handle is an opaque, reference-counted native resource identity. Width
## and height are descriptive pixel metadata kept directly on the value for
## pure layout and source-rectangle calculations.
Texture := {
	handle : Handle,
	width : F32,
	height : F32,
}.{
	Handle :: Box(U64)

	## Resource-free texture value for pure tests.
	##
	## The handle never resolves to a host resource. Copy this value with the
	## dimensions needed by the test. Do not use it to test drawing, mutation,
	## sampling configuration, or resource lifetime.
	stub : Texture
	stub = {
		handle: Handle.(Box.box(U64.highest)),
		width: 0,
		height: 0,
	}
}
