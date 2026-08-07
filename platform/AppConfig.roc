## Internal host transport for validated startup configuration.
##
## `App` owns the application-facing `Config` and its receivers. This module
## holds only the flattening to the native ABI record, and is deliberately
## omitted from the platform's `exposes` list so an app cannot reach it.
##
## It reads a Config through `App`'s public receivers rather than its fields:
## a `::` nominal is opaque outside the module that declares it.
import App
import Keys

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
	exit_key_code : I32,
}

AppConfig := [].{

	## Flatten validated choices to the stable native ABI record. This is a
	## module function, not a Config receiver, and AppConfig is not exposed.
	HostConfig : AppHostConfig

	to_host : {}, App.Config -> HostConfig
	to_host = |_, cfg| {
		pacing = host_pacing(cfg.frame_pacing())
		size = cfg.size()
		min_size = cfg.min_size()
		{
			title: cfg.title(),
			width: size.width,
			height: size.height,
			min_width: min_size.width,
			min_height: min_size.height,
			target_fps: pacing.target_fps,
			resizable: cfg.resizable(),
			fullscreen: cfg.fullscreen(),
			vsync: pacing.vsync,
			cursor_visible: cfg.cursor() == CursorVisible,
			exit_key_code: Keys.exit_key_code(cfg.exit_key()),
		}
	}
}

host_pacing : App.FramePacing -> { target_fps : I32, vsync : Bool }
host_pacing = |value|
	match value {
		VSync => { target_fps: 0, vsync: Bool.True }
		Capped(fps) => { target_fps: fps, vsync: Bool.False }
		Uncapped => { target_fps: 0, vsync: Bool.False }
	}

expect {
	cfg = App.default.with_title("Test").with_size({ width: 320, height: 240 })
	host = AppConfig.to_host({}, cfg)
	host.title == "Test" and host.width == 320 and host.height == 240 and host.target_fps == 240 and !(host.vsync) and host.cursor_visible
}
expect AppConfig.to_host({}, App.default.with_frame_pacing(Capped(120))) == { ..AppConfig.to_host({}, App.default), target_fps: 120 }
expect {
	host = AppConfig.to_host({}, App.default.with_resizable(Bool.True).with_fullscreen(Bool.True))
	host.resizable and host.fullscreen
}
expect AppConfig.to_host({}, App.default.with_size({ width: 0, height: -5 })) == AppConfig.to_host({}, App.default)
expect {
	host = AppConfig.to_host({}, App.default.with_min_size({ width: 640, height: -1 }))
	host.min_width == 640 and host.min_height == 0
}
expect AppConfig.to_host({}, App.default).exit_key_code == 256
expect AppConfig.to_host({}, App.default.with_exit_key(NoExitKey)).exit_key_code == 0
expect AppConfig.to_host({}, App.default.with_exit_key(ExitKey(KeyQ))).exit_key_code == 81
