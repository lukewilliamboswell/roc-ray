## Private host-owned prepared-text value.
##
## Internal typed ARC identity used by platform adapters and the native host.
## Applications use the corresponding public resource API.
import Handle

TextPrepared := { handle : TextPreparedHandle }.{
	TextPreparedHandle : Handle([PreparedTextResource])

	## Resource-free prepared-text value for pure tests.
	##
	## The handle never resolves to a host resource. Do not use it to test text
	## preparation, drawing, or resource lifetime.
	stub : TextPrepared
	stub = { handle: Handle.stub }
}
