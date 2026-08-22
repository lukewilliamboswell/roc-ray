## UDP sockets, for multiplayer, livecoding, and streaming data.
##
## A socket is bound once and kept in the model. `bind!` and `send!` are legal
## in `init!`, `update!`, and tasks, and refused in `render!`, which draws.
## `receive!` waits: it is legal in `init!`, where it blocks startup, and in
## tasks, where it parks the task; it is refused in `update!` and `render!`.
##
## So sending belongs in `update!` beside the rest of a frame's work, and
## receiving belongs in a task:
##
## ```roc
## Msg : [Arrived(List(Udp.Datagram)), ReceiveFailed(Udp.ReceiveError)]
##
## update! = |model, input| {
##     socket = model.socket
##     if !model.listening {
##         Task.spawn!(
##             input,
##             || match Udp.Socket.receive!(socket, Udp.default_receive) {
##                 Ok(datagrams) => Arrived(datagrams)
##                 Err(err) => ReceiveFailed(err)
##             },
##         )
##     }
##     dropped = match Udp.Socket.send!(socket, model.peer, position_bytes(input)) {
##         Ok({}) => model.dropped
##         Err(_) => model.dropped + 1
##     }
##     answered = !List.is_empty(input.messages)
##     Ok({ ..model, dropped, listening: !answered })
## }
## ```
##
## `listening` is set from whether this cycle's input answered rather than
## latched to true, so the next `update!` starts the next listener. A failed
## `send!` is counted rather than propagated: `WouldBlock` is a full send
## buffer, an ordinary condition on a busy link, and a position update would
## rather skip a frame than end the app.
##
## A task delivers exactly one message, so the loop is "receive, answer, and
## let `update!` start the next one" rather than a task that loops forever. A
## task that never returns never delivers anything.
##
## That is also why `receive!` answers with a whole batch. It parks until the
## first datagram arrives and then drains what the kernel already has, so one
## message carries a frame's worth of traffic in arrival order. A receive that
## answered with a single datagram would cap a respawned listener at one
## datagram per frame, which is far below what even a small game needs.
##
## Datagrams that arrive while no `receive!` is pending are not lost: they wait
## in the operating system's own buffer, and the next `receive!` returns them
## immediately. They are lost when that buffer overflows, silently, with no
## report -- that is the UDP contract, and sequence numbers in the payload are
## the app's answer to it. Delivery, ordering, and duplication are not promised
## by the protocol and are not added here.
##
## Framing, retransmission, serialization, discovery, and session state are the
## app's or a package's. This module moves bytes and nothing else.
##
## Addresses are IPv4 literals. An IPv6 address is `InvalidAddress`, and there
## is no name resolution: `bind!` and `send!` take a dotted-quad string, never
## a hostname, because resolving a name waits and neither of these effects
## does.
##
## This grants the app the network authority the process already has: any port
## it may bind, any host it may send to. Ports below 1024 usually need
## privileges, and report `PermissionDenied` when they are missing. Broadcast
## and multicast are not enabled.
import UdpHost

Udp := [].{

	## An IPv4 endpoint. `ip` is a dotted-quad literal such as `"127.0.0.1"`.
	##
	## Compare the `from` of a datagram you received rather than rebuilding it:
	## this is a plain record, so two values are equal when their text is.
	Address : { ip : Str, port : U16 }

	## One received datagram, and the address it came from. Reply to `from`:
	##
	## ```roc
	## reply! : Udp.Socket, Udp.Datagram, List(U8) => Try({}, Udp.SendError)
	## reply! = |socket, datagram, bytes| Udp.Socket.send!(socket, datagram.from, bytes)
	## ```
	Datagram : { from : Address, bytes : List(U8) }

	## Per-receive limits.
	##
	## `timeout_ms` is how long to wait for the first datagram; `0` waits
	## forever, which only makes sense in a task the app is content to leave
	## parked until shutdown. `max_datagrams` caps the batch, and the host
	## clamps it to sixty-four -- past that the rest simply stay buffered for
	## the next receive.
	##
	## A plain record; build one with `{ ..Udp.default_receive, timeout_ms: 200 }`
	## rather than a chain of `with_*` calls.
	ReceiveConfig : { timeout_ms : U64, max_datagrams : U32 }

	## One second, and up to sixty-four datagrams.
	##
	## The deadline is short enough that a listener respawned every frame keeps
	## its socket's queue drained even when a peer goes quiet, and long enough
	## not to churn tasks at idle.
	default_receive : ReceiveConfig
	default_receive = { timeout_ms: 1000, max_datagrams: 64 }

	## Why a socket was not bound.
	##
	## `AddressInUse` is another socket already holding the port,
	## `AddressUnavailable` is an address that is not one of this machine's,
	## and `ResourceLimit` is this platform's own ceiling of eight open
	## sockets. `InvalidAddress` is a string that is not a dotted-quad IPv4
	## literal.
	BindError : [InvalidAddress, AddressInUse, AddressUnavailable, PermissionDenied, ResourceLimit, Unavailable]

	## Why a datagram was not handed to the kernel.
	##
	## `WouldBlock` is the send buffer being full: the datagram was not sent,
	## and the app is producing faster than the link can carry. `TooLarge` is a
	## payload over `max_datagram_bytes`, refused rather than truncated,
	## because a truncated datagram decodes into wrong data. None of these mean
	## the peer received anything, and no code means it did -- UDP does not
	## report that.
	SendError : [InvalidAddress, TooLarge, WouldBlock, Unreachable, PermissionDenied, SendFailed, Unavailable]

	## Why a receive produced no datagrams.
	##
	## `Timeout` is the deadline expiring with nothing having arrived, which is
	## an ordinary quiet moment rather than a failure. `AlreadyReceiving` is a
	## second task trying to receive on a socket that already has one parked.
	ReceiveError : [Timeout, AlreadyReceiving, ReceiveFailed, Unavailable]

	## The largest payload one datagram may carry: 65535 bytes of IPv4 packet
	## less the 20-byte IP header and the 8-byte UDP header. A send over this
	## is `TooLarge`.
	##
	## Sending anywhere near it is unwise on a real network, where anything
	## over the path MTU is fragmented and one lost fragment loses the whole
	## datagram. Real-time protocols stay under about 1200 bytes.
	max_datagram_bytes : U64
	max_datagram_bytes = 65507

	## Bind a socket to a local address.
	##
	## `{ ip: "0.0.0.0", port: 0 }` takes any interface and lets the operating
	## system choose the port; the returned socket's `local_address` reports
	## what it chose. Bind once, in `init!` or when the app decides to start
	## networking, and keep the socket in the model -- binding per frame would
	## exhaust the eight-socket ceiling and change the port every time.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	bind! : Address => Try(Socket, BindError)
	bind! = |address| {
		result = UdpHost.bind!({ ip: address.ip, port: address.port })
		if result.err == 0 {
			Ok(Socket.({ handle: result.handle, local: { ip: format_ip(result.ip), port: result.port } }))
		} else {
			Err(bind_error(result.err))
		}
	}

	## An open datagram socket.
	##
	## The handle is reference counted: copy it freely, and when the last copy
	## goes -- out of the model, out of a task's captures, or at shutdown --
	## the socket is closed. There is nothing to remember to close.
	Socket := { handle : UdpHost.Handle, local : Address }.{

		## The address this socket is actually bound to, including the port the
		## operating system chose when `bind!` was given `0`.
		local_address : Socket -> Address
		local_address = |Socket.(socket)| socket.local

		## Send one datagram. This does not wait for anything: the payload goes
		## to the operating system and the call is over, whether or not any
		## peer is listening. Nothing here reports that a datagram arrived,
		## because UDP does not.
		##
		## It is a queued effect: the datagram is handed whole to the kernel's
		## bounded send buffer and the call returns at once, with the sending
		## itself happening off the frame thread. `WouldBlock` is that queue's
		## saturation -- the buffer was full, so this datagram was not taken --
		## and it is a typed result rather than a wait or a silent drop.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		send! : Socket, Address, List(U8) => Try({}, SendError)
		send! = |Socket.(socket), to, bytes| {
			err = UdpHost.send!({
				socket: socket.handle,
				ip: to.ip,
				port: to.port,
				bytes,
			})
			if err == 0 {
				Ok({})
			} else {
				Err(send_error(err))
			}
		}

		## Wait for datagrams, and answer with every one that was ready.
		##
		## Parks until the first datagram arrives or `timeout_ms` expires, then
		## returns it together with whatever else is already buffered, in
		## arrival order, up to `max_datagrams`. `Err(Timeout)` means nothing
		## arrived in time, which is a quiet moment rather than a failure.
		##
		## One receive at a time per socket: a second one while another task is
		## parked is `AlreadyReceiving`.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it
		## parks the task; refused in `update!` and `render!`.
		receive! : Socket, ReceiveConfig => Try(List(Datagram), ReceiveError)
		receive! = |Socket.(socket), config| {
			result = UdpHost.receive!({
				socket: socket.handle,
				timeout_ms: config.timeout_ms,
				max_datagrams: config.max_datagrams,
			})
			if result.err == 0 {
				Ok(decode_batch(result.slices, result.payload))
			} else {
				Err(receive_error(result.err))
			}
		}

		## Resource-free socket value for pure tests.
		##
		## The handle never resolves to an open socket, so every effect made
		## through it fails as `Unavailable` -- `Err(Unavailable)` from `send!`
		## and from `receive!` -- the same way a call through a closed socket
		## does. It exists for the app that keeps a socket in its model, to let
		## a pure `expect` build that model. Do not use it to test delivery or
		## resource lifetime.
		stub : Socket
		stub = Socket.({ handle: UdpHost.Handle.stub, local: { ip: "0.0.0.0", port: 0 } })
	}
}

## Rebuild the datagrams from the flat batch the host delivered.
decode_batch : List(UdpHost.DatagramSlice), List(U8) -> List(Udp.Datagram)
decode_batch = |slices, payload|
	List.map(
		slices,
		|slice| {
			from: { ip: format_ip(slice.ip), port: slice.port },
			bytes: List.sublist(payload, { start: slice.start, len: slice.len }),
		},
	)

## Format a host-order IPv4 word as a dotted quad.
format_ip : U32 -> Str
format_ip = |ip| {
	octet = |shift| U8.to_str(U32.to_u8_wrap(U32.shr_zf_wrap(ip, shift)))
	"${octet(24)}.${octet(16)}.${octet(8)}.${octet(0)}"
}

## Name a failed bind. Mirrors the `ERR_*` codes in `src/udp_effect.zig`.
bind_error : U8 -> Udp.BindError
bind_error = |code|
	match code {
		2 => InvalidAddress
		4 => ResourceLimit
		8 => AddressInUse
		9 => AddressUnavailable
		10 => PermissionDenied
		_ => Unavailable
	}

## Name a failed send. Mirrors the `ERR_*` codes in `src/udp_effect.zig`.
send_error : U8 -> Udp.SendError
send_error = |code|
	match code {
		1 => Unavailable
		2 => InvalidAddress
		10 => PermissionDenied
		11 => TooLarge
		12 => WouldBlock
		13 => Unreachable
		_ => SendFailed
	}

## Name a failed receive. Mirrors the `ERR_*` codes in `src/udp_effect.zig`.
receive_error : U8 -> Udp.ReceiveError
receive_error = |code|
	match code {
		1 => Unavailable
		14 => Timeout
		15 => AlreadyReceiving
		_ => ReceiveFailed
	}

expect format_ip(0x7f000001) == "127.0.0.1"
expect format_ip(0) == "0.0.0.0"
expect format_ip(0xffffffff) == "255.255.255.255"
expect format_ip(0xc0a80101) == "192.168.1.1"
expect format_ip(0x08080808) == "8.8.8.8"

expect bind_error(2) == InvalidAddress
expect bind_error(8) == AddressInUse
expect bind_error(1) == Unavailable
expect send_error(12) == WouldBlock
expect send_error(11) == TooLarge
expect send_error(3) == SendFailed
expect receive_error(14) == Timeout
expect receive_error(15) == AlreadyReceiving
expect receive_error(3) == ReceiveFailed

## Each datagram in a batch keeps its own bytes and its own sender: a decode
## that shared one slice, or lost the address, would make every reply go to the
## wrong peer.
expect {
	batch = decode_batch(
		[
			{ ip: 0x7f000001, port: 5000, start: 0, len: 4 },
			{ ip: 0xc0a80102, port: 5001, start: 4, len: 3 },
		],
		[112, 105, 110, 103, 112, 111, 110],
	)
	batch
		== [
			{ from: { ip: "127.0.0.1", port: 5000 }, bytes: [112, 105, 110, 103] },
			{ from: { ip: "192.168.1.2", port: 5001 }, bytes: [112, 111, 110] },
		]
}

expect decode_batch([], []) == []
