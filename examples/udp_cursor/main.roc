app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Color
import rr.Draw
import rr.Task
import rr.Text
import rr.Udp

## Two instances showing each other's mouse pointer over UDP.
##
## Each instance binds a socket, sends its own pointer position from `update!`
## every frame, and draws the position the peer last sent. Sending does not
## wait, so it is an ordinary effect in `update!` beside everything else the
## frame does. Receiving waits, so it lives in a task, and `update!` starts the
## next one each time the previous answers.
##
## Run two of them:
##
##     ./main --udp-port 7001 --udp-peer 7002
##     ./main --udp-port 7002 --udp-peer 7001
##
## With no arguments the instance binds an ephemeral port and peers with
## itself, so a single run still exercises both directions -- which is what a
## headless run does.
##
## The wire format here is four bytes, and it is the app's, not the platform's:
## the platform moves payloads and never looks inside one. Two bytes of x and
## two of y, big-endian, is enough for a demo and is deliberately not a
## protocol -- there is no sequence number, no acknowledgement, and no attempt
## to detect a lost or reordered datagram, all of which a real game needs and
## all of which are the app's to add.
Model : {
	socket : Udp.Socket,
	peer : Udp.Address,
	listening : Bool,

	## The peer's last known pointer, once one has arrived.
	peer_pointer : Try({ x : F32, y : F32 }, [NothingYet]),
	received : U64,
	dropped : U64,
	title : Text.Prepared,
}

Msg : [Arrived(List(Udp.Datagram)), ReceiveFailed(Udp.ReceiveError)]

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit, BindFailed])
init! = App.init_for_args(
	|_args| App.default.with_title("RocRay UDP Cursor").with_frame_pacing(Capped(60)),
	|startup| {
		args = App.args!(startup)
		font = Draw.default_font!()
		port = flag_port(args, "--udp-port", 0)
		socket = Udp.bind!({ ip: "127.0.0.1", port }) ? |_err| BindFailed
		local = Udp.Socket.local_address(socket)

		# With no `--udp-peer`, the peer is this instance itself. The datagrams
		# make a real round trip through the operating system, so a lone run
		# exercises the same code two instances would.
		peer_port = flag_port(args, "--udp-peer", local.port)
		Ok({
			socket,
			peer: { ip: "127.0.0.1", port: peer_port },
			listening: Bool.False,
			peer_pointer: Err(NothingYet),
			received: 0,
			dropped: 0,
			title: Text.from("UDP cursor: this pointer is sent, the other is received", font).size(20).prepare!()?,
		})
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	# One listener at a time. It answered this cycle, or has never run, so
	# start the next one; in between, datagrams wait in the kernel's buffer.
	socket = model.socket
	if !model.listening {
		Task.spawn!(
			input,
			|| match Udp.Socket.receive!(socket, Udp.default_receive) {
				Ok(datagrams) => Arrived(datagrams)
				Err(err) => ReceiveFailed(err)
			},
		)
	}

	# Sending is not a waiting effect, so this is an ordinary line of `update!`
	# rather than another task. A full send buffer means this frame's position
	# never left, which for a position update is the right outcome: the next
	# frame carries a newer one anyway.
	pointer = input.devices.mouse.position()
	dropped = match Udp.Socket.send!(model.socket, model.peer, encode(pointer)) {
		Ok({}) => model.dropped
		Err(_) => model.dropped + 1
	}

	answered = !List.is_empty(input.messages)
	next = List.fold(input.messages, { ..model, dropped }, apply_message)

	if input.devices.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		Ok({ ..next, listening: !answered })
	}
}

## Fold one delivered message into the model.
##
## Only the newest datagram in a batch is kept. A pointer is a state sample,
## not an event: three positions that arrived in one frame describe one
## pointer, and the last of them is where it is now.
apply_message : Model, Msg -> Model
apply_message = |model, message|
	match message {
		ReceiveFailed(_) => model
		Arrived(datagrams) =>
			match List.last(datagrams) {
				Err(_) => model
				Ok(datagram) =>
					match decode(datagram.bytes) {
						Err(_) => { ..model, received: model.received + List.len(datagrams) }
						Ok(pointer) => {
							..model,
							peer_pointer: Ok(pointer),
							received: model.received + List.len(datagrams),
						}
					}
				}
		}

## Two big-endian `U16`s. Negative or off-screen coordinates clamp rather than
## wrap, so a pointer dragged off the window edge stops at it.
encode : { x : F32, y : F32 } -> List(U8)
encode = |pointer| {
	coordinate = |value| {
		clamped = F32.min(F32.max(value, 0), 65535)
		whole = F32.to_u64_try(clamped) ?? 0
		U64.to_u16_wrap(whole)
	}
	x = coordinate(pointer.x)
	y = coordinate(pointer.y)
	[U16.to_u8_wrap(x / 256), U16.to_u8_wrap(x), U16.to_u8_wrap(y / 256), U16.to_u8_wrap(y)]
}

## The inverse. A payload that is not four bytes is not ours: the socket is
## reachable by anything on the machine, so a malformed datagram is ordinary
## input to be refused, not an error.
decode : List(U8) -> Try({ x : F32, y : F32 }, [Malformed])
decode = |bytes|
	if List.len(bytes) != 4 {
		Err(Malformed)
	} else {
		byte = |index| U8.to_f32(List.get(bytes, index) ?? 0)
		Ok({ x: byte(0) * 256 + byte(1), y: byte(2) * 256 + byte(3) })
	}

expect decode(encode({ x: 0, y: 0 })) == Ok({ x: 0, y: 0 })
expect decode(encode({ x: 640, y: 360 })) == Ok({ x: 640, y: 360 })
expect decode(encode({ x: 1919, y: 1079 })) == Ok({ x: 1919, y: 1079 })

## Sub-pixel positions truncate; the pointer is drawn on a whole pixel anyway.
expect decode(encode({ x: 12.75, y: 4.25 })) == Ok({ x: 12, y: 4 })

## Off-screen clamps instead of wrapping, so a pointer never jumps to the far side.
expect decode(encode({ x: -50, y: 999999 })) == Ok({ x: 0, y: 65535 })
expect decode([1, 2, 3]) == Err(Malformed)
expect decode([]) == Err(Malformed)

## The decimal argument following `flag`, or `fallback` when it is absent or is
## not a port number.
flag_port : List(Str), Str, U16 -> U16
flag_port = |args, flag, fallback| {
	var $found = fallback
	var $index = 0
	for arg in args {
		if arg == flag and $index + 1 < List.len(args) {
			text = List.get(args, $index + 1) ?? ""
			bytes = Str.to_utf8(text)
			if !List.is_empty(bytes) and List.all(bytes, |byte| byte >= 48 and byte <= 57) {
				digits = List.fold(bytes, 0, |acc, byte| acc * 10 + U8.to_u64(byte - 48))
				if digits <= 65535 {
					$found = U64.to_u16_wrap(digits)
				}
			}
		}
		$index = $index + 1
	}
	$found
}

expect flag_port(["--udp-port", "7001"], "--udp-port", 0) == 7001
expect flag_port(["--udp-port", "70000"], "--udp-port", 0) == 0
expect flag_port(["--udp-port", "x"], "--udp-port", 5) == 5
expect flag_port(["--udp-port"], "--udp-port", 5) == 5
expect flag_port([], "--udp-port", 5) == 5

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x14161f))
	model.title.draw!(frame, { pos: { x: 32, y: 28 }, color: Color.white, align: Text.align_top_left })
	local = Udp.Socket.local_address(model.socket)
	frame.text_at!({
		pos: { x: 32, y: 64 },
		text: "bound 127.0.0.1:${U16.to_str(local.port)}  peer 127.0.0.1:${U16.to_str(model.peer.port)}",
		size: 18,
		color: Color.from_hex_rgb(0x88c0d0),
	})
	frame.text_at!({
		pos: { x: 32, y: 90 },
		text: "${U64.to_str(model.received)} received, ${U64.to_str(model.dropped)} not sent",
		size: 18,
		color: Color.from_hex_rgb(0xa3be8c),
	})
	match model.peer_pointer {
		Err(NothingYet) =>
			frame.text_at!({
				pos: { x: 32, y: 116 },
				text: "waiting for the peer...",
				size: 18,
				color: Color.from_hex_rgb(0x6c7086),
			})

		Ok(pointer) =>
			frame.circle!({
				center: pointer,
				radius: 18,
				style: Draw.filled(Color.from_hex_rgba(0xebcb8b80)),
			})
		}
	Ok({})
}
