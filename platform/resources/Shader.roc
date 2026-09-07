## Private host-owned shader value.
##
## Internal typed ARC identity used by platform adapters and the native host.
## Applications use the corresponding public resource API.
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
