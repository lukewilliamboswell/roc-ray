## Application startup configuration and model initialization.
##
## Use `App.init` when startup needs effects such as loading host-owned assets.
## The callback runs after the window, renderer, and audio device are ready.
import Host
import AppConfig

App := [].{

	## Mutually exclusive frame pacing strategy.
	FramePacing : AppConfig.FramePacing

	## Initial native cursor mode.
	CursorMode : AppConfig.CursorMode

	## Which key, if any, closes the window. `NoExitKey` disables the behaviour.
	ExitKey : AppConfig.ExitKey

	## Opaque validated startup configuration. Update it through receivers.
	Config : AppConfig.Config

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
	default = AppConfig.default

	## Build app initialization from pure startup config plus the effectful
	## callback that creates the first model after raylib/audio are ready.
	init : Config, InitCallback(model, errors) -> Init(model, errors)
	init = |cfg, callback!| { config: cfg, run!: callback! }
}

expect App.default.with_frame_pacing(VSync).frame_pacing() == VSync
expect App.default.with_frame_pacing(Capped(-5)).frame_pacing() == Uncapped
expect App.default.with_cursor(CursorHidden).cursor() == CursorHidden
expect App.default.with_min_size({ width: 400, height: 300 }).min_size() == { width: 400, height: 300 }
expect App.default.with_exit_key(NoExitKey).exit_key() == NoExitKey
