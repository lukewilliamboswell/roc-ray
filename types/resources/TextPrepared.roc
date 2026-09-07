## Shared host-owned prepared-text value.
##
## The handle is an opaque, reference-counted native resource identity for a
## laid-out run of text. Preparing and drawing it remain platform operations;
## this value lets reusable packages retain prepared text without importing the
## platform.
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
