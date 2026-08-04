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

App := [].{

	## Mutually exclusive frame pacing strategy. Config normalization maps a
	## non-positive `Capped` value to `Uncapped` before a Config can be created.
	FramePacing : AppFramePacing

	## Initial native cursor mode.
	CursorMode : AppCursorMode

	## Stable flattened record consumed only by the native platform adapters.
	HostConfig : AppHostConfig

	## Validated startup configuration. Its fields cannot be updated directly;
	## use its receiver updates so startup invariants are preserved.
	Config :: {
		title : Str,
		width : I32,
		height : I32,
		frame_pacing : AppFramePacing,
		resizable : Bool,
		fullscreen : Bool,
		cursor : AppCursorMode,
	}.{

		## Return a config with a different window title.
		with_title : Config, Str -> Config
		with_title = |cfg, value| { ..cfg, title: value }

		## Return a config with different initial logical dimensions. Each
		## non-positive dimension independently falls back to the 800x600 default.
		with_size : Config, { width : I32, height : I32 } -> Config
		with_size = |cfg, dims| {
			..cfg,
			width: normalize_dimension(dims.width, default_width),
			height: normalize_dimension(dims.height, default_height),
		}

		## Return a config with a validated frame-pacing strategy.
		with_frame_pacing : Config, FramePacing -> Config
		with_frame_pacing = |cfg, value| { ..cfg, frame_pacing: normalize_pacing(value) }

		## Return a config with a different initial cursor mode.
		with_cursor : Config, CursorMode -> Config
		with_cursor = |cfg, value| { ..cfg, cursor: value }

		## Return a config that enables or disables native window resizing.
		with_resizable : Config, Bool -> Config
		with_resizable = |cfg, value| { ..cfg, resizable: value }

		## Return a config that starts in or out of fullscreen mode.
		with_fullscreen : Config, Bool -> Config
		with_fullscreen = |cfg, value| { ..cfg, fullscreen: value }

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

	## Build app initialization from pure startup config plus the effectful
	## callback that creates the first model after raylib/audio are ready.
	init : Config, InitCallback(model, errors) -> Init(model, errors)
	init = |cfg, callback!| { config: cfg, run!: callback! }
}

default_width : I32
default_width = 800

default_height : I32
default_height = 600

app_default_data : AppConfigData
app_default_data = {
	title: "Roc + Raylib",
	width: default_width,
	height: default_height,
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

normalize_dimension : I32, I32 -> I32
normalize_dimension = |value, fallback| if value > 0 value else fallback

host_pacing : AppFramePacing -> { target_fps : I32, vsync : Bool }
host_pacing = |value|
	match value {
		VSync => { target_fps: 0, vsync: Bool.True }
		Capped(fps) => { target_fps: fps, vsync: Bool.False }
		Uncapped => { target_fps: 0, vsync: Bool.False }
	}

expect {
	cfg = App.default.with_title("Test").with_size({ width: 320, height: 240 })
	host = cfg.to_host()
	host.title == "Test" and host.width == 320 and host.height == 240 and host.target_fps == 240 and !(host.vsync) and host.cursor_visible
}
expect App.default.with_frame_pacing(VSync).frame_pacing() == VSync
expect App.default.with_frame_pacing(Capped(120)).to_host() == { ..App.default.to_host(), target_fps: 120 }
expect App.default.with_frame_pacing(Capped(-5)).frame_pacing() == Uncapped
expect App.default.with_cursor(CursorHidden).cursor() == CursorHidden
expect {
	host = App.default.with_resizable(Bool.True).with_fullscreen(Bool.True).to_host()
	host.resizable and host.fullscreen
}
expect App.default.with_size({ width: 0, height: -5 }).to_host() == App.default.to_host()
expect {
	host = App.default.with_size({ width: -1, height: 720 }).to_host()
	host.width == 800 and host.height == 720
}
expect {
	host = App.default.with_size({ width: 1280, height: 0 }).to_host()
	host.width == 1280 and host.height == 600
}
