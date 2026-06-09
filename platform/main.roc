platform ""
	requires {
		[Model : model] for program : {
			init! : Host => Try(model, [Exit(I64), ..]),
			render! : model, Host => Try(model, [Exit(I64), ..]),
		}
	}
	exposes [Draw, Color, Host, Keys, Mouse, Time, Audio]
	packages {}
	provides {
		init_for_host!: "init_for_host",
		render_for_host!: "render_for_host",
		drop_model_for_host!: "drop_model_for_host",
	}
	targets: {
		files: "targets/",
		exe: {
			x64mac: ["libhost.a", "libraylib.a", app],
			arm64mac: ["libhost.a", "libraylib.a", app],
			x64glibc: ["Scrt1.o", "crti.o", "libhost.a", "libraylib.a", "libm.so", "libX11.so", app, "libc.so", "crtn.o"],
			x64win: ["host.lib", "raylib.lib", "gdi32.lib", "user32.lib", "winmm.lib", "opengl32.lib", "shell32.lib", app],
		},
	}

import Draw
import Color
import Host
import Keys
import Mouse
import Time
import Audio

## Internal type for host boundary - kept simple/flat for C compatibility
## Field order must match FFI struct in types.zig (alignment then alphabetical)
HostStateFromHost : {
	frame_count : U64,
	keys : List(U8), ## 349 bytes, held state, one per raylib key code 0-348
	keys_pressed : List(U8), ## 349 bytes, pressed-this-frame (edge) state
	keys_released : List(U8), ## 349 bytes, released-this-frame (edge) state
	timestamp_nanos : U64, ## monotonic clock, nanoseconds since window init
	frame_time : F32, ## seconds since previous frame (0 on first frame)
	mouse_buttons : List(U8), ## 7 bytes, held state, one per raylib mouse button code 0-6
	mouse_buttons_pressed : List(U8), ## 7 bytes, pressed-this-frame (edge) state
	mouse_buttons_released : List(U8), ## 7 bytes, released-this-frame (edge) state
	mouse_wheel : F32,
	mouse_x : F32,
	mouse_y : F32,
	mouse_left : Bool,
	mouse_middle : Bool,
	mouse_right : Bool,
}

init_for_host! : HostStateFromHost => Try(Box(Model), I64)
init_for_host! = |host_state| {
	host = {
		frame_count: host_state.frame_count,
		timestamp_nanos: host_state.timestamp_nanos,
		frame_time: host_state.frame_time,
		keys: host_state.keys,
		keys_pressed: host_state.keys_pressed,
		keys_released: host_state.keys_released,
		mouse: {
			buttons: host_state.mouse_buttons,
			buttons_pressed: host_state.mouse_buttons_pressed,
			buttons_released: host_state.mouse_buttons_released,
			x: host_state.mouse_x,
			y: host_state.mouse_y,
			left: host_state.mouse_left,
			right: host_state.mouse_right,
			middle: host_state.mouse_middle,
			wheel: host_state.mouse_wheel,
		},
	}
	match (program.init!)(host) {
		Ok(unboxed_model) => Ok(Box.box(unboxed_model))
		Err(Exit(code)) => Err(code)

		## Testing wildcard-only: should return 42 for NotFound
		Err(_) => Err(42)
	}
}

render_for_host! : Box(Model), HostStateFromHost => Try(Box(Model), I64)
render_for_host! = |boxed_model, host_state| {
	host = {
		frame_count: host_state.frame_count,
		timestamp_nanos: host_state.timestamp_nanos,
		frame_time: host_state.frame_time,
		keys: host_state.keys,
		keys_pressed: host_state.keys_pressed,
		keys_released: host_state.keys_released,
		mouse: {
			buttons: host_state.mouse_buttons,
			buttons_pressed: host_state.mouse_buttons_pressed,
			buttons_released: host_state.mouse_buttons_released,
			x: host_state.mouse_x,
			y: host_state.mouse_y,
			left: host_state.mouse_left,
			right: host_state.mouse_right,
			middle: host_state.mouse_middle,
			wheel: host_state.mouse_wheel,
		},
	}
	match (program.render!)(Box.unbox(boxed_model), host) {
		Ok(unboxed_model) => Ok(Box.box(unboxed_model))
		Err(Exit(code)) => Err(code)
		Err(_) => Err(-1)
	}
}

## Drop the final boxed model at host shutdown.
##
## The host owns the model box returned by init!/render! and must release it.
## Box refcounting depends on the Model layout (a box whose payload contains
## refcounted fields uses a wider allocation header), which only the compiler
## knows -- so we let Roc drop the box here rather than hand-rolling it in the
## host. Roc takes ownership of the unused arg and decrefs it at scope end.
## TODO: remove once roc glue emits box refcount helpers (roc#9536).
drop_model_for_host! : Box(Model) => {}
drop_model_for_host! = |_boxed_model| {}
