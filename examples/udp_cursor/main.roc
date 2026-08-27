## Share mouse positions between two local instances. Run one with
## `--udp-port 7001 --udp-peer 7002` and the other with those ports reversed;
## Escape quits. With no arguments, one instance sends to itself.
##
## This example shows immediate UDP sends, a Task for receiving data that may
## wait, and Messages that carry received batches back to `update!`.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Color
import rr.Draw
import rr.Task
import rr.Text
import rr.Udp

## State retained between updates: the socket and peer address, whether a
## receive Task is active, the latest local and peer pointers, send/receive
## counts, and prepared labels. This is enough to continue one receive at a
## time and draw the most recently reported positions.
Model : {
	socket : Udp.Socket,
	peer : Udp.Address,
	listening : Bool,

	## The peer's last known pointer, once one has arrived.
	peer_pointer : Try({ x : F32, y : F32 }, [NothingYet]),
	received : U64,
	dropped : U64,

	## This instance's own pointer, kept so `render!` can draw the position
	## that was sent beside the one that arrived.
	pointer : { x : F32, y : F32 },
	title : Text.Prepared,
	subtitle : Text.Prepared,
	hint : Text.Prepared,
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
			pointer: { x: 0, y: 0 },
			title: Text.from("Two pointers, one socket", font).size(26).prepare!()?,
			subtitle: Text.from("sending is an ordinary line of update!; receiving waits, so it lives in a task", font).size(15).prepare!()?,
			hint: Text.from("--udp-port / --udp-peer  pair two instances        ESC  quit", font).size(14).spacing(2.0).prepare!()?,
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
		Ok({ ..next, listening: !answered, pointer })
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
	size = frame.size!()
	frame.rectangle_gradient_v!({ x: 0, y: 0, width: size.width, height: size.height, color_top: bg_top, color_bottom: bg_bottom })
	draw_grid!(frame, size)

	# The peer's pointer first, so this instance's own crosshair stays on top
	# of it when the two overlap -- which is exactly what a lone run looks like.
	match model.peer_pointer {
		Err(NothingYet) => draw_searching!(frame, size, model.received)
		Ok(pointer) => draw_pointer!(frame, pointer, accent_peer, "peer", 22)
	}
	draw_pointer!(frame, model.pointer, accent_local, "you", 13)

	model.title.draw!(frame, { pos: { x: 44, y: 36 }, color: ink })
	model.subtitle.draw!(frame, { pos: { x: 44, y: 72 }, color: muted })

	local = Udp.Socket.local_address(model.socket)
	frame.rounded_rectangle!({ x: 44, y: 112, width: 384, height: 96, radius: 0.12, segments: 8, style: Draw.filled_and_outlined(card, card_edge, 1) })
	frame.text_at!({ pos: { x: 64, y: 126 }, text: "bound", size: 13, color: faint })
	frame.text_at!({ pos: { x: 64, y: 144 }, text: "127.0.0.1:${U16.to_str(local.port)}", size: 17, color: accent_local })
	frame.text_at!({ pos: { x: 232, y: 126 }, text: "peer", size: 13, color: faint })
	frame.text_at!({ pos: { x: 232, y: 144 }, text: "127.0.0.1:${U16.to_str(model.peer.port)}", size: 17, color: accent_peer })
	frame.text_at!({ pos: { x: 64, y: 178 }, text: "${U64.to_str(model.received)} received", size: 14, color: muted })
	frame.text_at!({ pos: { x: 232, y: 178 }, text: "${U64.to_str(model.dropped)} not sent", size: 14, color: if model.dropped == 0 muted else accent_bad })

	model.hint.draw!(frame, { pos: { x: 44, y: size.height - 40 }, color: faint })
	Ok({})
}

## A faint square grid, so a pointer moving over it reads as motion rather than
## as a circle floating in the dark.
draw_grid! : Draw.Frame, Draw.FrameSize => {}
draw_grid! = |frame, size|
	List.for_each!(
		List.map_with_index(List.repeat({}, 32), |_unit, index| U64.to_f32(index) * 40),
		|offset| {
			if offset <= size.width {
				frame.line!({ start: { x: offset, y: 0 }, end: { x: offset, y: size.height }, stroke: Stroke({ color: grid, thickness: 1 }) })
			}
			if offset <= size.height {
				frame.line!({ start: { x: 0, y: offset }, end: { x: size.width, y: offset }, stroke: Stroke({ color: grid, thickness: 1 }) })
			}
		},
	)

## One pointer: a soft glow, a ring, and a crosshair with its name.
draw_pointer! : Draw.Frame, { x : F32, y : F32 }, Color.Rgba, Str, F32 => {}
draw_pointer! = |frame, at, color, label, radius| {
	frame.circle_gradient!({ center: at, radius: radius * 2.6, color_inner: Color.with_alpha(color, 40), color_outer: Color.with_alpha(color, 0) })
	frame.circle!({ center: at, radius: radius, style: Draw.outlined(color, 2) })
	frame.line!({ start: { x: at.x - radius - 8, y: at.y }, end: { x: at.x - radius + 2, y: at.y }, stroke: Stroke({ color: color, thickness: 1.5 }) })
	frame.line!({ start: { x: at.x + radius - 2, y: at.y }, end: { x: at.x + radius + 8, y: at.y }, stroke: Stroke({ color: color, thickness: 1.5 }) })
	frame.text_at!({ pos: { x: at.x + radius + 12, y: at.y - 8 }, text: label, size: 14, color: color })
}

## Nothing has arrived yet: a comet turning on the received count, so the
## waiting state is visibly alive rather than a line of grey text.
draw_searching! : Draw.Frame, Draw.FrameSize, U64 => {}
draw_searching! = |frame, size, received| {
	center = { x: size.width * 0.5, y: size.height * 0.55 }
	turn = U64.to_f32(received % 360) * 0.12
	frame.circle!({ center: center, radius: 26, style: Draw.outlined(Color.with_alpha(accent_peer, 50), 1.5) })
	List.for_each!(
		spinner_dots,
		|dot| {
			angle = turn - dot.lag
			frame.circle!({
				center: { x: center.x + 26 * F32.cos(angle), y: center.y + 26 * F32.sin(angle) },
				radius: dot.radius,
				style: Draw.filled(Color.with_alpha(accent_peer, dot.alpha)),
			})
		},
	)
	frame.text_at!({ pos: { x: center.x - 78, y: center.y + 44 }, text: "waiting for the peer...", size: 15, color: muted })
}

spinner_dots : List({ lag : F32, radius : F32, alpha : U8 })
spinner_dots = [
	{ lag: 0, radius: 4.0, alpha: 255 },
	{ lag: 0.3, radius: 3.4, alpha: 190 },
	{ lag: 0.6, radius: 2.8, alpha: 135 },
	{ lag: 0.9, radius: 2.2, alpha: 85 },
	{ lag: 1.2, radius: 1.7, alpha: 45 },
]

bg_top = Color.from_hex_rgb(0x0b0e17)

bg_bottom = Color.from_hex_rgb(0x151b2a)

grid = Color.from_hex_rgba(0xffffff14)

card = Color.from_hex_rgb(0x171d2b)

card_edge = Color.from_hex_rgb(0x2a3348)

ink = Color.from_hex_rgb(0xe8ecf5)

muted = Color.from_hex_rgb(0x8a97b0)

faint = Color.from_hex_rgb(0x5c6880)

accent_local = Color.from_hex_rgb(0x6fb3e0)

accent_peer = Color.from_hex_rgb(0xf2c777)

accent_bad = Color.from_hex_rgb(0xef7d7d)
