import Host

AppConfig : {
	title : Str,
	width : I32,
	height : I32,
	target_fps : I32,
	resizable : Bool,
	fullscreen : Bool,
	vsync : Bool,
	cursor_visible : Bool,
}

App(_field) := { apply : AppConfig -> AppConfig }.{
	Config : AppConfig

	## TODO: allow init callbacks to expose extra errors once Roc can carry
	## open error rows through this init record shape without breaking fmt/glue.
	InitCallback(model) : Host => Try(model, [Exit(I64)])

	Init(model) : {
		config : Config,
		run! : InitCallback(model),
	}

	default : Config
	default = {
		title: "Roc + Raylib",
		width: 800,
		height: 600,
		target_fps: 240,
		resizable: Bool.False,
		fullscreen: Bool.False,
		vsync: Bool.False,
		cursor_visible: Bool.True,
	}

	map2 : App(a), App(b), (a, b -> c) -> App(c)
	map2 = |left, right, _combine| {
		apply: |cfg| (right.apply)((left.apply)(cfg)),
	}

	config : App(a) -> Config
	config = |builder| (builder.apply)(App.default)

	## Build app initialization from pure startup config plus the effectful
	## callback that creates the first model after raylib/audio are ready.
	init : Config, InitCallback(model) -> Init(model)
	init = |cfg, callback!| { config: cfg, run!: callback! }

	title : Str -> App(Str)
	title = |value| {
		apply: |cfg| { title: value, width: cfg.width, height: cfg.height, target_fps: cfg.target_fps, resizable: cfg.resizable, fullscreen: cfg.fullscreen, vsync: cfg.vsync, cursor_visible: cfg.cursor_visible },
	}

	width : I32 -> App(I32)
	width = |value| {
		apply: |cfg| { title: cfg.title, width: value, height: cfg.height, target_fps: cfg.target_fps, resizable: cfg.resizable, fullscreen: cfg.fullscreen, vsync: cfg.vsync, cursor_visible: cfg.cursor_visible },
	}

	height : I32 -> App(I32)
	height = |value| {
		apply: |cfg| { title: cfg.title, width: cfg.width, height: value, target_fps: cfg.target_fps, resizable: cfg.resizable, fullscreen: cfg.fullscreen, vsync: cfg.vsync, cursor_visible: cfg.cursor_visible },
	}

	size : { width : I32, height : I32 } -> App({ width : I32, height : I32 })
	size = |dims| {
		apply: |cfg| { title: cfg.title, width: dims.width, height: dims.height, target_fps: cfg.target_fps, resizable: cfg.resizable, fullscreen: cfg.fullscreen, vsync: cfg.vsync, cursor_visible: cfg.cursor_visible },
	}

	target_fps : I32 -> App(I32)
	target_fps = |value| {
		apply: |cfg| { title: cfg.title, width: cfg.width, height: cfg.height, target_fps: value, resizable: cfg.resizable, fullscreen: cfg.fullscreen, vsync: cfg.vsync, cursor_visible: cfg.cursor_visible },
	}

	resizable : Bool -> App(Bool)
	resizable = |value| {
		apply: |cfg| { title: cfg.title, width: cfg.width, height: cfg.height, target_fps: cfg.target_fps, resizable: value, fullscreen: cfg.fullscreen, vsync: cfg.vsync, cursor_visible: cfg.cursor_visible },
	}

	fullscreen : Bool -> App(Bool)
	fullscreen = |value| {
		apply: |cfg| { title: cfg.title, width: cfg.width, height: cfg.height, target_fps: cfg.target_fps, resizable: cfg.resizable, fullscreen: value, vsync: cfg.vsync, cursor_visible: cfg.cursor_visible },
	}

	vsync : Bool -> App(Bool)
	vsync = |value| {
		apply: |cfg| { title: cfg.title, width: cfg.width, height: cfg.height, target_fps: cfg.target_fps, resizable: cfg.resizable, fullscreen: cfg.fullscreen, vsync: value, cursor_visible: cfg.cursor_visible },
	}

	cursor_visible : Bool -> App(Bool)
	cursor_visible = |value| {
		apply: |cfg| { title: cfg.title, width: cfg.width, height: cfg.height, target_fps: cfg.target_fps, resizable: cfg.resizable, fullscreen: cfg.fullscreen, vsync: cfg.vsync, cursor_visible: value },
	}
}

## TODO(roc#9581): switch examples to imported record-builder syntax once
## `{ ... }.App` can find App.map2 across platform module imports.
expect App.map2(App.title("Test"), App.size({ width: 320, height: 240 }), |_, _| {}).config() == {
	title: "Test",
	width: 320,
	height: 240,
	target_fps: 240,
	resizable: Bool.False,
	fullscreen: Bool.False,
	vsync: Bool.False,
	cursor_visible: Bool.True,
}
