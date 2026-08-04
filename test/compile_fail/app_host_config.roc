app [Model, program] { rr: platform "../../platform/main-default.roc" }

import rr.App
import rr.Draw
import rr.Host

Model : {}

transport : App.HostConfig
transport = {
	title: "private",
	width: 800,
	height: 600,
	target_fps: 240,
	resizable: Bool.False,
	fullscreen: Bool.False,
	vsync: Bool.False,
	cursor_visible: Bool.True,
}

program = { init!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_host| Ok({}))

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, _host, _frame| Ok(model)
