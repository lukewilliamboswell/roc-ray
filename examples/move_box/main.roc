## Move a box around the window with the arrow keys. Escape quits.
##
## This example sits between `hello_world` and `pong`, and adds one idea: move
## things by *speed times time*. `update!` is told how many seconds passed
## since the previous host cycle, so the box covers the same distance each
## second however fast or slow the computer draws. The rules live in pure functions that the
## `expect`s at the bottom test without opening a window.
app [Model, program] { rr: platform "../../platform/main.roc" }

import rr.App
import rr.Color
import rr.Devices
import rr.Draw
import rr.Math

## Everything the app remembers between host cycles: where the box's top-left
## corner is, in logical units from the top-left of the window.
Model : { box : Math.Vec2 }

## The box is a square this many logical units wide.
box_size = 60.F32

## How far the box moves in one second while a key is held, in logical units.
speed = 300.F32

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default.with_title("RocRay Move Box").with_size({ width: 800, height: 600 }),
	|_io| Ok({ box: { x: 370, y: 270 } }),
)

## Turn two opposite keys into one number: -1, 0, or 1. Holding both cancels.
axis : Bool, Bool -> F32
axis = |negative, positive|
	if negative and !positive -1 else if positive and !negative 1 else 0

## Which way the arrow keys point. Up is negative because screen y grows
## downwards.
direction : Devices.Snapshot -> Math.Vec2
direction = |devices| {
	x: axis(devices.key_down(KeyLeft), devices.key_down(KeyRight)),
	y: axis(devices.key_down(KeyUp), devices.key_down(KeyDown)),
}

## The time step to move by. A stall, such as dragging the window, can report a
## whole second or more; moving by all of it at once would make the box jump.
## Clamping keeps every step small.
clamp_dt : F32 -> F32
clamp_dt = |seconds| Math.clamp(seconds, 0, 0.25)

## The rule of the game: move by direction x speed x time, then keep the whole
## box inside the window.
step_box : Math.Vec2, Math.Vec2, F32, { width : F32, height : F32 } -> Math.Vec2
step_box = |box, dir, dt, window| {
	x: Math.clamp(box.x + dir.x * speed * dt, 0, window.width - box_size),
	y: Math.clamp(box.y + dir.y * speed * dt, 0, window.height - box_size),
}

Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, _io| {
	devices = input.devices
	dt = clamp_dt(input.time.elapsed_seconds)
	window = { width: I32.to_f32(input.window.size.width), height: I32.to_f32(input.window.size.height) }
	Ok({ ..model, box: step_box(model.box, direction(devices), dt, window) })
}

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x101828))
	frame.rectangle!({ x: model.box.x, y: model.box.y, width: box_size, height: box_size, style: Draw.filled(Color.from_hex_rgb(0x2f80ed)) })
	frame.text_at!({ pos: { x: 20, y: 20 }, text: "Arrow keys move the box  -  Escape quits", size: 20, color: Color.from_hex_rgb(0xa8b4cc) })
	Ok({})
}

window_800x600 = { width: 800, height: 600 }

## Half a second of holding Right moves the box half of `speed` to the right.
expect step_box({ x: 100, y: 100 }, { x: 1, y: 0 }, 0.5, window_800x600) == { x: 250, y: 100 }

## The box stops at the right edge instead of leaving the window.
expect step_box({ x: 730, y: 100 }, { x: 1, y: 0 }, 0.5, window_800x600).x == 800 - box_size

## ...and at the top edge.
expect step_box({ x: 100, y: 10 }, { x: 0, y: -1 }, 0.5, window_800x600).y == 0

## Holding Left and Right together cancels out.
expect direction(Devices.none.with_key_down(KeyLeft).with_key_down(KeyRight)).x == 0
expect direction(Devices.none.with_key_down(KeyUp)).y == -1

## A long stall moves the box by a quarter of a second at most.
expect clamp_dt(3) == 0.25
