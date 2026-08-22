app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

# A connection's identity is private to the host. An application can hold and
# copy a `Db` it was given, but cannot manufacture one from a raw integer and
# so cannot name a connection the host never opened for it.
import rr.App
import rr.Draw
import rr.Sqlite

Model : {
	db : Sqlite.Db,
}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({ db: Sqlite.Db.(Box.box(0)) }))

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
