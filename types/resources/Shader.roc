## Shared host-owned shader value.
##
## The handle is an opaque, reference-counted native resource identity. Shader
## compilation and uniform effects remain platform operations; this value lets
## reusable packages retain shader identity without importing the platform.
import Handle

Shader := { handle : ShaderHandle }.{
	ShaderHandle : Handle([ShaderResource])

	## Resource-free shader value for pure tests.
	##
	## The handle never resolves to a host resource. Do not use it to test shader
	## compilation, uniform operations, drawing scopes, or resource lifetime.
	stub : Shader
	stub = { handle: Handle.stub }
}
