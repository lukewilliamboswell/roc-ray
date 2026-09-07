## Pure helpers in an application module use the complete platform API.
## The app retains their output in its model and draws with it on later cycles.
import rr.Assets
import rr.Audio
import rr.Sqlite
import rr.Text
import rr.Udp
import rr.Draw
import rr.App
import rr.Keys
import rr.Mouse
import rr.Gamepad
import rr.Texture
import rr.Time
import rr.Devices

Api := [].{
	Event : [KeyDown(Keys.Key), Click({ x : F32, y : F32 }), Pad(Gamepad.Id), Nothing]
	Pulse : { cycle : U64, messages : U64, clicked : Bool }
	pulse : App.Input(msg) -> Pulse
	pulse = |input| {
		cycle: input.time.cycle_count,
		messages: List.len(input.messages),
		clicked: Mouse.button_pressed(input.devices.mouse, Left),
	}
	key_event : { keys : List(U8), ..state }, Keys.Key -> Event
	key_event = |input, key| if Keys.key_down(input, key) KeyDown(key) else Nothing
	click_event : Mouse.Snapshot -> Event
	click_event = |mouse| if Mouse.button_pressed(mouse, Left) Click(Mouse.position(mouse)) else Nothing
	pad_event : Gamepad.Snapshot, Gamepad.Id -> Event
	pad_event = |snapshot, id| if Gamepad.available(snapshot, id) Pad(id) else Nothing
	age_seconds : U64, U64 -> F32
	age_seconds = |started, now| Time.delta_seconds(started, now)
	Sized : { texture : Texture, aspect : F32 }
	describe : Texture -> Sized
	describe = |texture| { texture, aspect: texture.width / texture.height }
	retained : Sized -> Texture
	retained = |sized| sized.texture
	Resources : {
		store : Assets.Store,
		sound : Audio.Sound,
		music : Audio.Music,
		db : Sqlite.Db,
		stmt : Sqlite.Stmt,
		text : Text.Prepared,
		socket : Udp.Socket,
		shader : Draw.Shader,
		target : Draw.RenderTexture,
	}

	resource_stubs : Resources
	resource_stubs = {
		store: Assets.Store.stub,
		sound: Audio.Sound.stub,
		music: Audio.Music.stub,
		db: Sqlite.Db.stub,
		stmt: Sqlite.Stmt.stub,
		text: Text.Prepared.stub,
		socket: Udp.Socket.stub,
		shader: Draw.Shader.stub,
		target: Draw.RenderTexture.stub,
	}

	retain_resources : Resources -> Resources
	retain_resources = |resources| resources

}
