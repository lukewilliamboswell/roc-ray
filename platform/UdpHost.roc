## Internal datagram-socket transport and hosted effects.
##
## This module is intentionally not exposed by the platform package. Public
## applications use `Udp`, which maps these flat primitive codes onto tag
## unions and hides the numbering.
##
## `bind!` and `send!` change host state without waiting, so they carry the
## `during_load` and `during_update` phase sets in `src/host_native.zig`.
## `receive!` waits: on a task the host parks the coroutine on its event loop
## and the frame loop keeps drawing, and in `init!` the same call blocks.
##
## Addresses cross this boundary as a host-order IPv4 word rather than a
## string. `Udp` formats it back to dotted quad in pure Roc. A received batch
## can hold sixty-four datagrams, and sixty-four strings per receive would be
## sixty-four allocations a frame for something the app usually only compares.
##
## The batch itself is one flat byte list plus an index of scalars, rather than
## a `List` of records each holding its own `List(U8)`. A list whose elements
## carry refcounted fields is the shape `roc glue` still renders with the wrong
## header -- see the `TODO(compiler)` note in `TaskHost.roc`, and `FilesHost`'s
## `list!`, which encodes its entries into bytes for the same reason.
UdpHost := [].{

	## Opaque bound socket. The descriptor is owned by a typed host ARC heap,
	## so a copied Roc value keeps the socket open and the last one closes it.
	Handle :: Box(U64).{

		## The invalid token, as a resource-free handle. See `Udp.Socket.stub`.
		stub : Handle
		stub = Handle.(Box.box(U64.highest))
	}

	## A request to bind. `ip` is a dotted-quad IPv4 literal, which the host
	## parses; a port of `0` asks the operating system to choose one.
	BindArgs : {
		ip : Str,
		port : U16,
	}

	## The bound socket, or the reason there is none. `ip` and `port` are the
	## address the kernel actually assigned, which differs from the requested
	## one whenever the app passed port `0`.
	BindResult : {
		handle : Handle,
		ip : U32,
		port : U16,
		err : U8,
	}

	## One outgoing datagram. `ip` is a dotted-quad IPv4 literal.
	SendArgs : {
		socket : Handle,
		ip : Str,
		port : U16,
		bytes : List(U8),
	}

	## A request to receive. `timeout_ms` of `0` means no deadline;
	## `max_datagrams` is clamped by the host to its own batch ceiling.
	ReceiveArgs : {
		socket : Handle,
		timeout_ms : U64,
		max_datagrams : U32,
	}

	## Where one datagram came from, and where its bytes sit in the batch's
	## shared `payload`.
	DatagramSlice : {
		ip : U32,
		port : U16,
		start : U64,
		len : U64,
	}

	## A finished batch. `err` is `0` when `slices` and `payload` are
	## meaningful, and both are empty otherwise.
	ReceiveResult : {
		err : U8,
		slices : List(DatagramSlice),
		payload : List(U8),
	}

	## Open and bind one IPv4 UDP socket.
	bind! : BindArgs => BindResult

	## Hand one datagram to the kernel. `0` means it was accepted for sending;
	## anything else is an error code `Udp` names.
	send! : SendArgs => U8

	## Wait for at least one datagram, then drain what is already buffered.
	receive! : ReceiveArgs => ReceiveResult
}
