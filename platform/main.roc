platform ""
	requires {
		[Model : model] for program : {
			init! : Host => Try(model, [Exit(I64), ..]),
			render! : model, Host => Try(model, [Exit(I64), ..]),
		}
	}
	exposes [Draw, Color, Host, Keys]
	packages {}
	provides {
		init_for_host!: "init_for_host",
		render_for_host!: "render_for_host",
	}
	targets: {
		files: "targets/",
		exe: {
			x64mac: ["libhost.a", "libraylib.a", app],
			arm64mac: ["libhost.a", "libraylib.a", app],
			## libm.so must come after libraylib.a (which uses it) or --as-needed drops it
			x64glibc: ["Scrt1.o", "crti.o", "libhost.a", "libraylib.a", "libm.so", app, "libc.so", "crtn.o"],
			## arm64glibc not supported - raylib doesn't provide pre-built libraries for Linux ARM
			x64win: ["host.lib", "raylib.lib", "gdi32.lib", "user32.lib", "winmm.lib", "opengl32.lib", "shell32.lib", app],
		}
		static_lib: {
			wasm32: ["libhost.a", app],
		}
	}

import Draw
import Color
import Host
import Keys

## Internal type for host boundary - kept simple/flat for C compatibility
## Field order must match FFI struct in types.zig (alignment then alphabetical)
HostStateFromHost : {
	frame_count : U64,
	keys : List(U8),  ## 349 bytes, one per raylib key code 0-348
	mouse_wheel : F32,
	mouse_x : F32,
	mouse_y : F32,
	mouse_left : Bool,
	mouse_middle : Bool,
	mouse_right : Bool,
}

init_for_host! : HostStateFromHost => Try(Box(Model), I64)
init_for_host! = |host_state| {
	host : Host
	host = {
		frame_count: host_state.frame_count,
		keys: Keys.pack(host_state.keys),
		mouse: {
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
	host : Host
	host = {
		frame_count: host_state.frame_count,
		keys: Keys.pack(host_state.keys),
		mouse: {
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
