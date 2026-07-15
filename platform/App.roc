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

	## Effectful startup callback run after the host has initialized raylib and
	## audio. Return `Ok(model)` to start the app, or `Err(Exit(code))` to quit
	## before the first frame.
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
		apply: |cfg| { ..cfg, title: value },
	}

	width : I32 -> App(I32)
	width = |value| {
		apply: |cfg| { ..cfg, width: value },
	}

	height : I32 -> App(I32)
	height = |value| {
		apply: |cfg| { ..cfg, height: value },
	}

	size : { width : I32, height : I32 } -> App({ width : I32, height : I32 })
	size = |dims| {
		apply: |cfg| { ..cfg, width: dims.width, height: dims.height },
	}

	target_fps : I32 -> App(I32)
	target_fps = |value| {
		apply: |cfg| { ..cfg, target_fps: value },
	}

	resizable : Bool -> App(Bool)
	resizable = |value| {
		apply: |cfg| { ..cfg, resizable: value },
	}

	fullscreen : Bool -> App(Bool)
	fullscreen = |value| {
		apply: |cfg| { ..cfg, fullscreen: value },
	}

	vsync : Bool -> App(Bool)
	vsync = |value| {
		apply: |cfg| { ..cfg, vsync: value },
	}

	cursor_visible : Bool -> App(Bool)
	cursor_visible = |value| {
		apply: |cfg| { ..cfg, cursor_visible: value },
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
