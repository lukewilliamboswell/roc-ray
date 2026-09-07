## Shared host-owned UDP socket value.
##
## The handle is an opaque, reference-counted native resource identity for a
## bound socket. Binding, sending, and receiving remain platform operations;
## this value lets reusable packages retain socket identity without importing
## the platform.
import Handle

UdpSocket := { handle : UdpSocketHandle }.{
	UdpSocketHandle : Handle([UdpSocketResource])

	## Resource-free socket value for pure tests.
	##
	## The handle never resolves to a bound socket. Do not use it to test
	## binding, datagram transfer, or resource lifetime.
	stub : UdpSocket
	stub = { handle: Handle.stub }
}
