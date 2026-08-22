app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Task
import rr.Udp

## Do datagrams make the round trip, from the right address, without stalling
## the frame?
##
## A headless run only asserts an exit code, so an app whose datagrams never
## arrive still passes the suite. This probe asserts on the values themselves.
## It binds two sockets on loopback ephemeral ports, sends `ping` from A to B
## and `pong` back from B to whatever address B says the ping came from, and
## exits non-zero unless both hops carried the right bytes *and* named the right
## sender. The reply deliberately goes to `from` rather than to A's known
## address: a receive that reported the wrong peer would still deliver the right
## bytes, and only this catches it.
##
## `--udp-expect-timeout` runs the other half: one socket, nothing sent, and a
## receive that must report `Timeout`. It also checks that several frames went
## by while that task was parked, which is what distinguishes a waiting effect
## that parked its task from one that blocked the frame loop.
##
## Exit codes: 0 every property held, 3 one did not, 4 nothing arrived in time.
##
## Usage:
##     --udp-expect-timeout        run the timeout half instead of the round trip
Model : {
	mode : Mode,
	socket_a : Udp.Socket,
	socket_b : Udp.Socket,

	## Cycle the parked receive was started on, for the park assertion.
	started_cycle : U64,
	state : State,
	outcome : Outcome,
}

Mode : [RoundTrip, ExpectTimeout]

## Where the exchange has got to.
State : [Idle, AwaitingPing, AwaitingPong, AwaitingTimeout]

Outcome : [Pending, Passed, FailedWith(Str)]

Msg : [
	Received(Udp.Address, List(Udp.Datagram)),
	ReceiveFailed(Udp.Address, Udp.ReceiveError, U64),
]

## Far longer than a loopback round trip at the headless pace, and long enough
## that the 200 ms timeout half has room to expire and be judged.
deadline_cycles : U64
deadline_cycles = 240

## The receive deadline for the timeout half. Short enough to expire well
## inside `deadline_cycles`, long enough that several frames must pass while
## the task is parked.
timeout_ms : U64
timeout_ms = 200

## The fewest frames that must be drawn while a task is parked in `receive!`.
##
## This is the assertion that the effect parks its task rather than blocking:
## a `receive!` that held the frame thread for its whole deadline would let no
## frame through at all, and the run would fail here rather than passing for
## the wrong reason.
min_parked_cycles : U64
min_parked_cycles = 3

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init_for_args(
	|_args| App.default,
	|startup| {
		args = App.args!(startup)
		mode = if List.contains(args, "--udp-expect-timeout") ExpectTimeout else RoundTrip
		match (Udp.bind!(loopback(0)), Udp.bind!(loopback(0))) {
			(Ok(socket_a), Ok(socket_b)) =>
				Ok({
					mode,
					socket_a,
					socket_b,
					started_cycle: 0,
					state: Idle,
					outcome: Pending,
				})

			_ => Err(Exit(3))
		}
	},
)

## A loopback address with the given port. Port 0 asks for an ephemeral one.
loopback : U16 -> Udp.Address
loopback = |port| { ip: "127.0.0.1", port }

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	cycle = input.time.cycle_count
	started = if model.state == Idle {
		start!(model, input, cycle)
	} else {
		model.started_cycle
	}
	state = if model.state == Idle {
		pending_state(model.mode)
	} else {
		model.state
	}

	# Effects and verdict together: replying to a ping is an effect, and the
	# address to reply to is only in the message that just arrived.
	var $outcome = model.outcome
	var $state = state
	for message in input.messages {
		result = react!(model, input, message, cycle, $outcome)
		$outcome = result.outcome
		$state = result.state
	}

	next = { ..model, started_cycle: started, state: $state, outcome: $outcome }
	match next.outcome {
		Passed => Err(Exit(0))
		FailedWith(_) => Err(Exit(3))
		Pending =>
			if cycle > deadline_cycles {
				Err(Exit(4))
			} else {
				Ok(next)
			}
		}
}

## What the run is waiting for once its first task is in flight.
pending_state : Mode -> State
pending_state = |mode|
	match mode {
		RoundTrip => AwaitingPing
		ExpectTimeout => AwaitingTimeout
	}

## Start the exchange: park a listener, and for the round trip also send the
## ping that will wake it.
##
## The send is made from `update!` on purpose. It is not a waiting effect, so
## putting it in a task would prove nothing about where it is legal; sending it
## here is what shows a game can answer input with a datagram in the same frame.
start! : Model, App.Input(Msg), U64 => U64
start! = |model, input, cycle| {
	match model.mode {
		RoundTrip => {
			listen!(input, model.socket_b, cycle)
			# The task has not run yet, so nothing is parked on B when this
			# datagram is sent. It waits in the kernel until the task does run,
			# which is exactly what the module documents.
			_ = Udp.Socket.send!(model.socket_a, Udp.Socket.local_address(model.socket_b), ping_bytes)
			{}
		}

		ExpectTimeout => listen!(input, model.socket_a, cycle)
	}
	cycle
}

## Park one task on a socket, remembering which socket it was so the judgement
## can tell the two apart, and which cycle it started on so the park itself can
## be measured.
listen! : App.Input(Msg), Udp.Socket, U64 => {}
listen! = |input, socket, cycle| {
	local = Udp.Socket.local_address(socket)
	Task.spawn!(
		input,
		|| match Udp.Socket.receive!(socket, { timeout_ms, max_datagrams: 16 }) {
			Ok(datagrams) => Received(local, datagrams)
			Err(err) => ReceiveFailed(local, err, cycle)
		},
	)
}

## What is sent, and -- separately -- what must arrive.
##
## The two are deliberately not the same constant. An oracle that compared a
## received payload against the very expression that produced it would agree
## with any payload at all: change the bytes and both sides move together. The
## `expected_*` values are written out again so that they cannot.
ping_bytes : List(U8)
ping_bytes = Str.to_utf8("ping")

pong_bytes : List(U8)
pong_bytes = Str.to_utf8("pong")

expected_ping : List(U8)
expected_ping = [112, 105, 110, 103]

expected_pong : List(U8)
expected_pong = [112, 111, 110, 103]

expect expected_ping == Str.to_utf8("ping")
expect expected_pong == Str.to_utf8("pong")

## Act on one delivered message and say where the run stands afterwards.
##
## A message that has already decided the run is not acted on again: the first
## verdict is the verdict.
react! : Model, App.Input(Msg), Msg, U64, Outcome => { outcome : Outcome, state : State }
react! = |model, input, message, cycle, current|
	match current {
		Passed => { outcome: Passed, state: model.state }
		FailedWith(reason) => { outcome: FailedWith(reason), state: model.state }
		Pending =>
			match (model.mode, message) {
				(ExpectTimeout, ReceiveFailed(_, Timeout, started)) =>
				# The park assertion. A `receive!` that blocked the frame
				# thread for its whole deadline would let no frame through,
				# so this is what tells a parked task from a stalled loop.
					if cycle >= started + min_parked_cycles {
						{ outcome: Passed, state: model.state }
					} else {
						{
							outcome: FailedWith("only ${U64.to_str(cycle - started)} cycle(s) passed while the task was parked"),
							state: model.state,
						}
					}

				(ExpectTimeout, ReceiveFailed(_, err, _)) => {
					outcome: FailedWith("expected Timeout, got ${Str.inspect(err)}"),
					state: model.state,
				}

				(ExpectTimeout, Received(_, _)) => {
					outcome: FailedWith("a socket nobody sent to received something"),
					state: model.state,
				}

				(RoundTrip, ReceiveFailed(_, err, _)) => {
					outcome: FailedWith("receive failed: ${Str.inspect(err)}"),
					state: model.state,
				}

				(RoundTrip, Received(local, datagrams)) => reply!(model, input, local, datagrams, cycle)
			}
		}

## Check one delivered batch and, when it was the ping, answer it.
reply! : Model, App.Input(Msg), Udp.Address, List(Udp.Datagram), U64 => { outcome : Outcome, state : State }
reply! = |model, input, local, datagrams, cycle| {
	address_a = Udp.Socket.local_address(model.socket_a)
	address_b = Udp.Socket.local_address(model.socket_b)
	match List.first(datagrams) {
		Err(_) => { outcome: FailedWith("a receive answered Ok with no datagrams"), state: model.state }
		Ok(datagram) =>
			if List.len(datagrams) != 1 {
				{ outcome: FailedWith("expected exactly one datagram in the batch"), state: model.state }
			} else if local == address_b {
				if datagram.bytes != expected_ping {
					{ outcome: FailedWith("B received the wrong bytes"), state: model.state }
				} else if datagram.from != address_a {
					{
						outcome: FailedWith("B was told the ping came from ${datagram.from.ip}:${U16.to_str(datagram.from.port)}"),
						state: model.state,
					}
				} else {
					# Reply to the address the datagram claims to come from,
					# not to A's known address: a receive that reported the
					# wrong sender would still have carried the right bytes,
					# and only a reply that has to use `from` catches it.
					listen!(input, model.socket_a, cycle)
					_ = Udp.Socket.send!(model.socket_b, datagram.from, pong_bytes)
					{ outcome: Pending, state: AwaitingPong }
				}
			} else if datagram.bytes != expected_pong {
				{ outcome: FailedWith("A received the wrong bytes"), state: model.state }
			} else if datagram.from != address_b {
				{
					outcome: FailedWith("A was told the pong came from ${datagram.from.ip}:${U16.to_str(datagram.from.port)}"),
					state: model.state,
				}
			} else {
				{ outcome: Passed, state: model.state }
			}
		}
}

render! : Model, _ => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
