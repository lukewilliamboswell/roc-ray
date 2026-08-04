## Application startup configuration and model initialization.
##
## Use `App.init` when startup needs effects such as loading host-owned assets.
## The callback runs after the window, renderer, and audio device are ready.
import Host

AppFramePacing := [VSync, Capped(I32), Uncapped].{
	is_eq : _
}

AppCursorMode := [CursorVisible, CursorHidden].{
	is_eq : _
}

AppConfigData : {
	title : Str,
	width : I32,
	height : I32,
	frame_pacing : AppFramePacing,
	resizable : Bool,
	fullscreen : Bool,
	cursor : AppCursorMode,
}

AppHostConfig : {
	title : Str,
	width : I32,
	height : I32,
	target_fps : I32,
	resizable : Bool,
	fullscreen : Bool,
	vsync : Bool,
	cursor_visible : Bool,
}

App(_field) :: { apply : AppConfigData -> AppConfigData }.{

	## Mutually exclusive frame pacing strategy. Builder normalization maps a
	## non-positive `Capped` value to `Uncapped` before a Config can be created.
	FramePacing : AppFramePacing

	## Initial native cursor mode.
	CursorMode : AppCursorMode

	## Stable flattened record consumed only by the native platform adapters.
	HostConfig : AppHostConfig

	## Validated startup configuration. Its fields cannot be updated directly;
	## use App builders so pacing and cursor invariants are preserved.
	Config :: {
		title : Str,
		width : I32,
		height : I32,
		frame_pacing : AppFramePacing,
		resizable : Bool,
		fullscreen : Bool,
		cursor : AppCursorMode,
	}.{

		## Inspect the selected frame-pacing strategy.
		frame_pacing : Config -> FramePacing
		frame_pacing = |cfg| cfg.frame_pacing

		## Inspect the selected initial cursor mode.
		cursor : Config -> CursorMode
		cursor = |cfg| cfg.cursor

		## Flatten validated public choices to the existing native ABI record.
		to_host : Config -> HostConfig
		to_host = |cfg| {
			pacing = host_pacing(cfg.frame_pacing)
			{
				title: cfg.title,
				width: cfg.width,
				height: cfg.height,
				target_fps: pacing.target_fps,
				resizable: cfg.resizable,
				fullscreen: cfg.fullscreen,
				vsync: pacing.vsync,
				cursor_visible: cfg.cursor == CursorVisible,
			}
		}
	}

	## Effectful startup callback run after the host has initialized raylib and
	## audio. Return `Ok(model)` to start the app, `Err(Exit(code))` to quit
	## before the first frame, or let other initialization errors propagate.
	InitCallback(model, errors) : Host => Try(model, [Exit(I64), ..errors])

	## Startup configuration paired with an effectful model initializer.
	Init(model, errors) : {
		config : Config,
		run! : InitCallback(model, errors),
	}

	## Default 800x600 window configuration capped at 240 FPS.
	default : Config
	default = app_default_data

	## Combine two configuration builder fields. When builders select the same
	## tagged choice, the right-hand builder wins deterministically.
	map2 : App(a), App(b), (a, b -> c) -> App(c)
	map2 = |left, right, _combine| {
		apply: |cfg| (right.apply)((left.apply)(cfg)),
	}

	## Apply another builder after this one. This is the concise choice for
	## ordinary configuration chains; use `map2` when composing record builders.
	then : App(a), App(b) -> App(b)
	then = |left, right| {
		apply: |cfg| (right.apply)((left.apply)(cfg)),
	}

	## Resolve a configuration builder against `default`.
	config : App(a) -> Config
	config = |builder| (builder.apply)(app_default_data)

	## Build app initialization from pure startup config plus the effectful
	## callback that creates the first model after raylib/audio are ready.
	init : Config, InitCallback(model, errors) -> Init(model, errors)
	init = |cfg, callback!| { config: cfg, run!: callback! }

	## Set the window title.
	title : Str -> App(Str)
	title = |value| { apply: |cfg| { ..cfg, title: value } }

	## Set the initial logical window width.
	width : I32 -> App(I32)
	width = |value| { apply: |cfg| { ..cfg, width: value } }

	## Set the initial logical window height.
	height : I32 -> App(I32)
	height = |value| { apply: |cfg| { ..cfg, height: value } }

	## Set the initial logical window dimensions.
	size : { width : I32, height : I32 } -> App({ width : I32, height : I32 })
	size = |dims| { apply: |cfg| { ..cfg, width: dims.width, height: dims.height } }

	## Select one frame-pacing mode. A non-positive `Capped` value is normalized
	## to `Uncapped`, so an invalid cap cannot enter Config.
	frame_pacing : FramePacing -> App(FramePacing)
	frame_pacing = |value| { apply: |cfg| { ..cfg, frame_pacing: normalize_pacing(value) } }

	## Compatibility builder for raylib's CPU frame-rate cap.
	target_fps : I32 -> App(I32)
	target_fps = |value| { apply: |cfg| { ..cfg, frame_pacing: normalize_pacing(Capped(value)) } }

	## Enable or disable native window resizing.
	resizable : Bool -> App(Bool)
	resizable = |value| { apply: |cfg| { ..cfg, resizable: value } }

	## Start in fullscreen mode when true.
	fullscreen : Bool -> App(Bool)
	fullscreen = |value| { apply: |cfg| { ..cfg, fullscreen: value } }

	## Compatibility builder. True selects VSync; false preserves an existing
	## capped/uncapped mode or restores the default cap when disabling VSync.
	vsync : Bool -> App(Bool)
	vsync = |value| {
		apply: |cfg| {
			..cfg,
			frame_pacing: if value {
				VSync
			} else {
				match cfg.frame_pacing {
					VSync => Capped(240)
					current => current
				}
			},
		},
	}

	## Choose the initial cursor mode directly.
	cursor : CursorMode -> App(CursorMode)
	cursor = |value| { apply: |cfg| { ..cfg, cursor: value } }

	## Compatibility builder mapping a boolean to a tagged cursor mode.
	cursor_visible : Bool -> App(Bool)
	cursor_visible = |value| { apply: |cfg| { ..cfg, cursor: if value CursorVisible else CursorHidden } }
}

app_default_data : AppConfigData
app_default_data = {
	title: "Roc + Raylib",
	width: 800,
	height: 600,
	frame_pacing: Capped(240),
	resizable: Bool.False,
	fullscreen: Bool.False,
	cursor: CursorVisible,
}

normalize_pacing : AppFramePacing -> AppFramePacing
normalize_pacing = |value|
	match value {
		Capped(fps) => if fps <= 0 Uncapped else value
		_ => value
	}

host_pacing : AppFramePacing -> { target_fps : I32, vsync : Bool }
host_pacing = |value|
	match value {
		VSync => { target_fps: 0, vsync: Bool.True }
		Capped(fps) => { target_fps: fps, vsync: Bool.False }
		Uncapped => { target_fps: 0, vsync: Bool.False }
	}

expect {
	cfg = App.map2(App.title("Test"), App.size({ width: 320, height: 240 }), |_, _| {}).config()
	host = cfg.to_host()
	host.title == "Test" and host.width == 320 and host.height == 240 and host.target_fps == 240 and !(host.vsync) and host.cursor_visible
}
expect App.map2(App.target_fps(120), App.vsync(Bool.True), |_, _| {}).config().frame_pacing() == VSync
expect App.map2(App.vsync(Bool.True), App.target_fps(120), |_, _| {}).config().frame_pacing() == Capped(120)
expect App.title("Chained").then(App.frame_pacing(Capped(60))).config().to_host().target_fps == 60
expect App.frame_pacing(Capped(-5)).config().frame_pacing() == Uncapped
expect App.cursor_visible(Bool.False).config().cursor() == CursorHidden
