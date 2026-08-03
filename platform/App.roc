## Application startup configuration and model initialization.
##
## Use `App.init` when startup needs effects such as loading host-owned assets.
## The callback runs after the window, renderer, and audio device are ready.
import Host

AppConfig : {

	## Set the window title.
	title : Str,

	## Set the initial logical window width.
	width : I32,

	## Set the initial logical window height.
	height : I32,

	## Set the requested render-loop frame rate.
	target_fps : I32,

	## Enable or disable native window resizing.
	resizable : Bool,

	## Start in fullscreen mode when true.
	fullscreen : Bool,

	## Enable or disable vertical synchronization.
	vsync : Bool,

	## Choose whether the native cursor starts visible.
	cursor_visible : Bool,
}

App(_field) := { apply : AppConfig -> AppConfig }.{

	## Window, renderer, timing, and cursor settings applied at startup.
	Config : AppConfig

	## Effectful startup callback run after the host has initialized raylib and
	## audio. Return `Ok(model)` to start the app, `Err(Exit(code))` to quit
	## before the first frame, or let other initialization errors propagate.
	InitCallback(model, errors) : Host => Try(model, [Exit(I64), ..errors])

	## Startup configuration paired with an effectful model initializer.
	Init(model, errors) : {
		config : Config,
		run! : InitCallback(model, errors),
	}

	## Default 800x600 window configuration.
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

	## Combine two configuration builder fields.
	map2 : App(a), App(b), (a, b -> c) -> App(c)
	map2 = |left, right, _combine| {
		apply: |cfg| (right.apply)((left.apply)(cfg)),
	}

	## Resolve a configuration builder against `default`.
	config : App(a) -> Config
	config = |builder| (builder.apply)(App.default)

	## Build app initialization from pure startup config plus the effectful
	## callback that creates the first model after raylib/audio are ready.
	init : Config, InitCallback(model, errors) -> Init(model, errors)
	init = |cfg, callback!| { config: cfg, run!: callback! }

	## Set the window title.
	title : Str -> App(Str)
	title = |value| {
		apply: |cfg| { ..cfg, title: value },
	}

	## Set the initial logical window width.
	width : I32 -> App(I32)
	width = |value| {
		apply: |cfg| { ..cfg, width: value },
	}

	## Set the initial logical window height.
	height : I32 -> App(I32)
	height = |value| {
		apply: |cfg| { ..cfg, height: value },
	}

	## Set the initial logical window dimensions.
	size : { width : I32, height : I32 } -> App({ width : I32, height : I32 })
	size = |dims| {
		apply: |cfg| { ..cfg, width: dims.width, height: dims.height },
	}

	## Set the requested render-loop frame rate.
	target_fps : I32 -> App(I32)
	## Set raylib's CPU-side frame-rate cap. Values at or below zero render
	## uncapped. This neither selects a software renderer nor controls VSync.
	target_fps = |value| {
		apply: |cfg| { ..cfg, target_fps: value },
	}

	## Enable or disable native window resizing.
	resizable : Bool -> App(Bool)
	resizable = |value| {
		apply: |cfg| { ..cfg, resizable: value },
	}

	## Start in fullscreen mode when true.
	fullscreen : Bool -> App(Bool)
	fullscreen = |value| {
		apply: |cfg| { ..cfg, fullscreen: value },
	}

	## Enable or disable vertical synchronization.
	vsync : Bool -> App(Bool)
	## Request synchronized buffer presentation from the graphics driver.
	## Actual pacing depends on the driver, window system, and compositor.
	vsync = |value| {
		apply: |cfg| { ..cfg, vsync: value },
	}

	## Choose whether the native cursor starts visible.
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
