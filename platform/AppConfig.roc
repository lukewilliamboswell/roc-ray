## Internal owner for validated startup configuration and its host transport.
##
## `App` exposes aliases for the application-facing types and values. This
## module is deliberately omitted from the platform's `exposes` list so only
## the platform adapters can flatten a Config to the legacy host ABI record.
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
	min_width : I32,
	min_height : I32,
	frame_pacing : AppFramePacing,
	resizable : Bool,
	fullscreen : Bool,
	cursor : AppCursorMode,
}

AppHostConfig : {
	title : Str,
	width : I32,
	height : I32,
	min_width : I32,
	min_height : I32,
	target_fps : I32,
	resizable : Bool,
	fullscreen : Bool,
	vsync : Bool,
	cursor_visible : Bool,
}

AppConfig := [].{

	## Mutually exclusive frame pacing strategy. Config normalization maps a
	## non-positive `Capped` value to `Uncapped` before a Config can be created.
	FramePacing : AppFramePacing

	## Initial native cursor mode.
	CursorMode : AppCursorMode

	## Validated startup configuration. Its fields cannot be updated directly;
	## use its receiver updates so startup invariants are preserved.
	Config :: {
		title : Str,
		width : I32,
		height : I32,
		min_width : I32,
		min_height : I32,
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

		## Return a config with a minimum window size the user cannot shrink
		## past. Each negative dimension is clamped to `0`, which means "no
		## limit" in that axis. A minimum only takes effect on a resizable
		## window, so pair this with `with_resizable(Bool.True)`.
		with_min_size : Config, { width : I32, height : I32 } -> Config
		with_min_size = |cfg, dims| {
			..cfg,
			min_width: normalize_min_dimension(dims.width),
			min_height: normalize_min_dimension(dims.height),
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

		## Inspect the minimum window size. A `0` in either axis means the
		## window is unconstrained in that direction.
		min_size : Config -> { width : I32, height : I32 }
		min_size = |cfg| { width: cfg.min_width, height: cfg.min_height }
	}

	## Default 800x600 window configuration capped at 240 FPS.
	default : Config
	default = app_default_data

	## Flatten validated choices to the stable native ABI record. This is a
	## module function, not a Config receiver, and AppConfig is not exposed.
	HostConfig : AppHostConfig

	to_host : {}, Config -> HostConfig
	to_host = |_, cfg| {
		pacing = host_pacing(cfg.frame_pacing)
		{
			title: cfg.title,
			width: cfg.width,
			height: cfg.height,
			min_width: cfg.min_width,
			min_height: cfg.min_height,
			target_fps: pacing.target_fps,
			resizable: cfg.resizable,
			fullscreen: cfg.fullscreen,
			vsync: pacing.vsync,
			cursor_visible: cfg.cursor == CursorVisible,
		}
	}
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
	min_width: 0,
	min_height: 0,
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

## Unlike `normalize_dimension`, `0` is a meaningful minimum: raylib maps it to
## GLFW_DONT_CARE, leaving that axis unconstrained. Only negatives are clamped.
normalize_min_dimension : I32 -> I32
normalize_min_dimension = |value| if value > 0 value else 0

host_pacing : AppFramePacing -> { target_fps : I32, vsync : Bool }
host_pacing = |value|
	match value {
		VSync => { target_fps: 0, vsync: Bool.True }
		Capped(fps) => { target_fps: fps, vsync: Bool.False }
		Uncapped => { target_fps: 0, vsync: Bool.False }
	}

expect {
	cfg = AppConfig.default.with_title("Test").with_size({ width: 320, height: 240 })
	host = AppConfig.to_host({}, cfg)
	host.title == "Test" and host.width == 320 and host.height == 240 and host.target_fps == 240 and !(host.vsync) and host.cursor_visible
}
expect AppConfig.to_host({}, AppConfig.default.with_frame_pacing(Capped(120))) == { ..AppConfig.to_host({}, AppConfig.default), target_fps: 120 }
expect AppConfig.default.with_frame_pacing(Capped(-5)).frame_pacing() == Uncapped
expect AppConfig.default.with_cursor(CursorHidden).cursor() == CursorHidden
expect {
	host = AppConfig.to_host({}, AppConfig.default.with_resizable(Bool.True).with_fullscreen(Bool.True))
	host.resizable and host.fullscreen
}
expect AppConfig.to_host({}, AppConfig.default.with_size({ width: 0, height: -5 })) == AppConfig.to_host({}, AppConfig.default)
expect {
	host = AppConfig.to_host({}, AppConfig.default.with_size({ width: -1, height: 720 }))
	host.width == 800 and host.height == 720
}
expect {
	host = AppConfig.to_host({}, AppConfig.default.with_size({ width: 1280, height: 0 }))
	host.width == 1280 and host.height == 600
}
expect AppConfig.default.min_size() == { width: 0, height: 0 }
expect AppConfig.default.with_min_size({ width: 320, height: 240 }).min_size() == { width: 320, height: 240 }
expect AppConfig.default.with_min_size({ width: -1, height: -20 }).min_size() == { width: 0, height: 0 }
expect {
	host = AppConfig.to_host({}, AppConfig.default.with_min_size({ width: 640, height: -1 }))
	host.min_width == 640 and host.min_height == 0
}
