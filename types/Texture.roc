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
}
