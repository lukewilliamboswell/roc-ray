## Mouse helpers for `input.devices.mouse`.
##
## Pass `input.devices.mouse` directly to these helpers; there is nothing to
## construct, and the receivers read the same either way:
## `input.devices.mouse.position()`.
##
## The types and pure helpers live in the companion `roc-ray-types` package so
## reusable packages can depend on them without depending on this platform.
## This module re-exports them, so `Snapshot` here and in the package are the same
## nominal type and its receivers are available either way.
import rrt.Mouse as RrtMouse
import MouseHost
import CaptureHost

Mouse := [].{

	## Mouse input sampled once at the start of the current frame.
	##
	## Declared in the `roc-ray-types` package's `Mouse` and re-exported here,
	## which is also where its receivers are documented.
	Snapshot : RrtMouse.Snapshot

	## Native operating-system cursor shapes.
	Cursor : RrtMouse.Cursor

	## Standard mouse buttons sampled by the platform.
	Button : RrtMouse.Button

	## Where pointer input comes from: `Hardware`, or a `Virtual` pointer whose
	## position and buttons the app states itself.
	##
	## A virtual source is how a run drives its own pointer -- a scripted demo,
	## a recorded walkthrough, a headless test that has to click something. The
	## host reports it through `input.devices.mouse` exactly as it reports the
	## hardware one, so nothing downstream can tell the difference.
	Source : RrtMouse.Source

	## A virtual pointer at a position, with no button held.
	virtual_at : { x : F32, y : F32 } -> Source
	virtual_at = RrtMouse.virtual_at

	## A virtual pointer at a position with the left button held, so the next
	## input reports a press there.
	virtual_click_at : { x : F32, y : F32 } -> Source
	virtual_click_at = RrtMouse.virtual_click_at

	## Hand pointer input to a scripted source, or back to the hardware mouse.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	set_source! : Source => {}
	set_source! = |source|
		match source {
			Hardware => CaptureHost.set_virtual_mouse!({ active: Bool.False, x: 0, y: 0, left: Bool.False, middle: Bool.False, right: Bool.False, wheel: 0 })
			Virtual(state) => CaptureHost.set_virtual_mouse!({ active: Bool.True, x: state.x, y: state.y, left: state.left, middle: state.middle, right: state.right, wheel: state.wheel })
		}

	## Cursor visibility and capture policy, applied atomically as one tagged
	## operation by `Mouse.set_cursor_mode!`.
	CursorMode : [Visible, Hidden, Locked]

	## Flatten a cursor shape to the raylib code the host passes to
	## `SetMouseCursor`, the way `Keys.exit_key_code` flattens an exit key.
	##
	## Apps do not need this: `Mouse.set_cursor!(shape)` takes the shape
	## itself. The platform uses it to flatten the shape for the host without
	## keeping a second copy of the numbering.
	cursor_code : Cursor -> U8
	cursor_code = |cursor|
		match cursor {
			Default => 0
			Arrow => 1
			IBeam => 2
			Crosshair => 3
			PointingHand => 4
			ResizeEastWest => 5
			ResizeNorthSouth => 6
			ResizeNorthwestSoutheast => 7
			ResizeNortheastSouthwest => 8
			ResizeAll => 9
			NotAllowed => 10
		}

	expect Mouse.cursor_code(Default) == 0
	expect Mouse.cursor_code(PointingHand) == 4
	expect Mouse.cursor_code(NotAllowed) == 10

	## Flatten a cursor mode to the code the host applies. Apps take the tag
	## itself; the platform uses this for `Mouse.set_cursor_mode!`.
	cursor_mode_code : CursorMode -> U8
	cursor_mode_code = |mode|
		match mode {
			Visible => 0
			Hidden => 1
			Locked => 2
		}

	expect Mouse.cursor_mode_code(Visible) == 0
	expect Mouse.cursor_mode_code(Locked) == 2

	## Set the native cursor shape.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	set_cursor! : Cursor => {}
	set_cursor! = |cursor| MouseHost.set_cursor!(cursor_code(cursor))

	## Set cursor visibility and capture, applied atomically as one operation.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	set_cursor_mode! : CursorMode => {}
	set_cursor_mode! = |mode| MouseHost.set_cursor_mode!(cursor_mode_code(mode))

	## Current cursor position in logical drawing coordinates.
	position : { x : F32, y : F32, ..state } -> { x : F32, y : F32 }
	position = RrtMouse.position

	## Cursor movement since the previous frame, sampled once by the host.
	delta : { delta_x : F32, delta_y : F32, ..state } -> { x : F32, y : F32 }
	delta = RrtMouse.delta

	## Horizontal and vertical wheel movement since the previous input: every
	## scroll event in the interval summed, so notches turned between two
	## cycles are all counted rather than only the last. Each notch is also a
	## `Wheel` entry in `input.devices.events`, in order with the clicks and
	## keys around it.
	wheel_delta : { wheel_x : F32, wheel_y : F32, ..state } -> { x : F32, y : F32 }
	wheel_delta = RrtMouse.wheel_delta

	## Check if a mouse button is held down at this cycle's boundary. A state
	## sample.
	button_down : { buttons : List(U8), ..state }, Button -> Bool
	button_down = RrtMouse.button_down

	## Check if a mouse button is up at this cycle's boundary.
	button_up : { buttons : List(U8), ..state }, Button -> Bool
	button_up = RrtMouse.button_up

	## Check if a mouse button was pressed at least once since the previous
	## input.
	##
	## An interval event recorded from the window system, so a click that
	## began and ended between two cycles is still pressed (and released) in
	## the next input. This is the coalesced view: presses of one button
	## inside one interval answer once, and `position` is where the pointer
	## was at the cycle boundary. For a drag that ended and began again inside
	## one frame, a double click, or the exact spot each click landed at,
	## walk `input.devices.events`: every `ButtonPressed` and `ButtonReleased`
	## is there in order, each with its own position.
	button_pressed : { buttons : List(U8), ..state }, Button -> Bool
	button_pressed = RrtMouse.button_pressed

	## Check if a mouse button was released at least once since the previous
	## input, with the same guarantee as `button_pressed`.
	button_released : { buttons : List(U8), ..state }, Button -> Bool
	button_released = RrtMouse.button_released
}
