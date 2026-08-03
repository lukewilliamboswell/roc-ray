app [Model, program] { rr: platform "../platform/main-default.roc" }

import rr.App
import rr.Assets
import rr.Audio
import rr.Color
import rr.Draw
import rr.Host
import rr.Keys
import rr.Sprite

Model : {
	texture : Assets.Texture,
	sound : Audio.Sound,
}

program = { init!, render! }

pixels : List(Color)
pixels = [
	Color.blue,
	Color.blue,
	Color.yellow,
	Color.yellow,
	Color.blue,
	Color.blue,
	Color.yellow,
	Color.yellow,
	Color.red,
	Color.red,
	Color.green,
	Color.green,
	Color.red,
	Color.red,
	Color.green,
	Color.green,
]

init! : App.Init(Model, [PixelCountMismatch, ResourceLimit, SoundGenerationFailed, TextureGenerationFailed])
init! = App.init(
	{ ..App.default, title: "Generated Assets", target_fps: 120 },
	|_host| {
		match Assets.generate_color_texture!({ width: 4, height: 4, color: Color.white }) {
			Err(_) => Err(TextureGenerationFailed)
			Ok(texture) =>
				match Assets.update_texture!(texture, pixels) {
					Err(_) => Err(PixelCountMismatch)
					Ok({}) => {
						Assets.set_filter!(texture, Bilinear)
						Assets.set_wrap!(texture, Clamp)

						sound = Audio.gen_tone!({ freq: 440, ms: 180 })?
						Audio.set_master_volume!(0.8)
						Ok({ texture, sound })
					}
				}
			}
	},
)

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	if host.key_pressed(KeySpace) model.sound.play!()
	if host.key_pressed(KeyS) model.sound.stop!()
	if host.key_pressed(KeyP) model.sound.pause!()
	if host.key_pressed(KeyR) model.sound.resume!()

	sprite = Sprite.from_texture(model.texture)
		.pos({ x: 400, y: 285 })
		.scale(64)
		.centered()

	Draw.clear!(Color.ray_white)
	sprite.draw!()
	# Keep both labels within RocStr's inline representation so this
	# example's steady-state render loop only allocates its model box.
	Draw.text_centered!({ pos: { x: 400, y: 445 }, text: "SPACE play | S stop", size: 20, color: Color.dark_gray })
	Draw.text_centered!({ pos: { x: 400, y: 475 }, text: "P pause | R resume", size: 20, color: Color.dark_gray })

	Ok(model)
}
