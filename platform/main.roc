platform ""
	requires {
		[Model : model] for program : {
			init! : () => Try(model, [Exit(I64), ..]),
			render! : model, PlatformState => Try(model, [Exit(I64), ..]),
		}
	}
	exposes [Draw, Color, PlatformState]
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
		}
		static_lib: {
			wasm32: ["libhost.a", app],
		}
	}

import Draw
import Color
import PlatformState

## Internal type for host boundary - kept simple/flat for C compatibility
PlatformStateFromHost : {
	frame_count : U64,
	mouse_wheel : F32,
	mouse_x : F32,
	mouse_y : F32,
	mouse_left : Bool,
	mouse_right : Bool,
	mouse_middle : Bool,
}

init_for_host! : {} => Try(Box(Model), I64)
init_for_host! = |{}| match (program.init!)() {
	Ok(unboxed_model) => Ok(Box.box(unboxed_model))
	Err(Exit(code)) => Err(code)
	Err(_) => Err(-1)
}

render_for_host! : Box(Model), PlatformStateFromHost => Try(Box(Model), I64)
render_for_host! = |boxed_model, host_state| {
	platform_state : PlatformState
	platform_state = {
		frame_count: host_state.frame_count,
		mouse: {
			x: host_state.mouse_x,
			y: host_state.mouse_y,
			left: host_state.mouse_left,
			right: host_state.mouse_right,
			middle: host_state.mouse_middle,
			wheel: host_state.mouse_wheel,
		},
	}
	match (program.render!)(Box.unbox(boxed_model), platform_state) {
		Ok(unboxed_model) => Ok(Box.box(unboxed_model))
		Err(Exit(code)) => Err(code)
		Err(_) => Err(-1)
	}
}
