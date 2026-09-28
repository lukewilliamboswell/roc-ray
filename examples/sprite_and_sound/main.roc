## Load a picture and a sound from files, draw the picture, and play the sound
## when you press Space. Escape quits.
##
## This example introduces three ideas, in the order `init!` uses them:
##
## 1. A permission. An app may only read the directories it declares in its
##    startup config. This one declares `examples/sprite_and_sound/assets`,
##    read-only, and nothing else.
## 2. An asset store. `Assets.open!` turns that directory into a store that
##    textures and sounds are loaded from by name.
## 3. Loaded resources. `Assets.load_texture!` reads `blob.png` into a texture
##    for drawing and `Audio.load_sound!` reads `boing.wav` into a sound.
##
## The paths are relative to the directory you run from, so run it from the
## directory that contains `examples/`. Both files were made by
## `assets/make_assets.py` and are original to this repository.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc6/7sujbfhDKezq7FAp75Nk4mTkTiPNDH36zmAMyGskmZoy.tar.zst", roc: "nightly-2026-09-27-a3ce7f1" }

import rr.App
import rr.Assets
import rr.Audio
import rr.Color
import rr.Draw
import rr.Math

## The loaded picture and sound, plus how far through its hop the blob is.
## `hop` is 0 when the blob sits still and jumps to 1 when you press Space.
Model : {
	blob : Draw.Texture,
	boing : Audio.Sound,
	hop : F32,
}

## The one directory this app reads. The config declares it and `init!` opens
## it, so both use this constant and cannot drift apart.
assets_dir = "examples/sprite_and_sound/assets"

## The picture is 16 x 16 pixels; drawing each one 8 x 8 makes it 128 wide.
scale = 8.F32

## How long a hop lasts, in seconds.
hop_seconds = 0.4.F32

program = { init!, update!, render! }

## The `_` in `App.Init(Model, _)` lets Roc work out every error that loading
## can report, such as a missing file, instead of listing them by hand. Any of
## them stops the app with a message that names it.
init! : App.Init(Model, _)
init! = App.init(
	App.default
		.with_title("RocRay Sprite and Sound")
		.with_size({ width: 800, height: 600 })
		.with_permission(Directory(assets_dir, ReadOnly)),
	|io| {
		store = Assets.open!(io.files().open_dir_read!(assets_dir)?, IgnoreManifest)?
		blob = Assets.load_texture!(store, "blob.png")?
		# Pixel art stays crisp when scaled up if each pixel is drawn as a
		# solid square instead of being blended with its neighbours.
		Assets.set_texture_filter!(blob, Point)
		boing = Audio.load_sound!(store, "boing.wav")?
		Ok({ blob, boing, hop: 0 })
	},
)

## The pure rule for the hop: Space starts a new one, and otherwise it runs
## down to 0 over `hop_seconds`. No effects, so the `expect`s below test it.
step_hop : F32, Bool, F32 -> F32
step_hop = |hop, space_pressed, dt|
	if space_pressed 1 else F32.max(hop - dt / hop_seconds, 0)

## How high the blob is above its resting place, in logical units, at a point
## in its hop: up and back down along half a sine wave.
hop_height : F32 -> F32
hop_height = |hop| 120 * F32.sin(hop * F32.pi)

Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, _io| {
	devices = input.devices
	space_pressed = devices.key_pressed(KeySpace)
	if space_pressed {
		# Playing a sound is an effect: it changes the world outside the app,
		# so it happens here in `update!`, not in the pure `step_hop`.
		model.boing.playback().play!()
	}
	dt = Math.clamp(input.time.elapsed_seconds, 0, 0.25)
	Ok({ ..model, hop: step_hop(model.hop, space_pressed, dt) })
}

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |model, frame| {
	size = frame.size!()
	width = model.blob.width * scale
	height = model.blob.height * scale
	x = (size.width - width) * 0.5
	y = size.height * 0.6 - height - hop_height(model.hop)

	frame.clear!(Color.from_hex_rgb(0x1b2136))
	# The ground, and a shadow that shrinks while the blob is in the air.
	frame.rectangle!({ x: 0, y: size.height * 0.6, width: size.width, height: size.height * 0.4, style: Draw.filled(Color.from_hex_rgb(0x2a3350)) })
	shadow = width * (0.5 - 0.2 * F32.sin(model.hop * F32.pi))
	frame.circle!({ center: { x: size.width * 0.5, y: size.height * 0.6 + 6 }, radius: shadow, style: Draw.filled(Color.with_alpha(Color.black, 70)) })

	# `source` picks the part of the texture to draw (all of it) and `dest`
	# says where on screen, and how big, to draw it.
	frame.texture!({
		texture: model.blob,
		source: { x: 0, y: 0, width: model.blob.width, height: model.blob.height },
		dest: { x, y, width, height },
		origin: Math.zero,
		rotation: 0,
		tint: Color.white,
	})

	frame.text_at!({ pos: { x: 24, y: 24 }, text: "Space  hop and play boing.wav      Escape  quit", size: 20, color: Color.from_hex_rgb(0xa8b4cc) })
	Ok({})
}

## Space always starts a full hop, even in the middle of one.
expect step_hop(0.3, Bool.True, 0.1) == 1

## Without Space, a hop runs down by how much time passed...
expect step_hop(1, Bool.False, hop_seconds / 2) == 0.5

## ...and stops at 0 rather than going below it.
expect step_hop(0.1, Bool.False, 1) == 0

## The blob is on the ground at the start and the end of a hop.
expect hop_height(0) == 0
