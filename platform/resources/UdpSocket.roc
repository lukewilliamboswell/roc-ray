## Private host-owned UDP socket value.
##
## Internal typed ARC identity used by platform adapters and the native host.
## Applications use the corresponding public resource API.
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
