## Assets module - host-owned textures and other resources.
##
## Textures are opaque, host-owned GPU resources. Load or generate them during
## initialization, keep them in the model, then draw or update them through the
## operations in this module. Releasing the final Roc reference unloads the
## native texture automatically.
import Math
import Color
import AssetsHost

Assets := [].{

	## Opaque, host-owned GPU texture with immutable dimensions.
	Texture : AssetsHost.Texture

	## Texture sampling filter used when an image is scaled.
	TextureFilter := [Point, Bilinear, Trilinear, Anisotropic4x, Anisotropic8x, Anisotropic16x]

	## Texture-coordinate behavior outside the normal 0-to-1 range.
	TextureWrap := [Repeat, Clamp, MirrorRepeat, MirrorClamp]

	## Configuration for a solid-color generated texture.
	GenerateColorTexture : { width : I32, height : I32, color : Color }

	## Configuration for a generated checkerboard texture.
	GenerateCheckedTexture : {
		width : I32,
		height : I32,
		checks_x : I32,
		checks_y : I32,
		color_a : Color,
		color_b : Color,
	}

	## Load an image file into GPU texture memory. The returned value owns the
	## resource and may be safely shared between sprites, uniforms, and models.
	load_texture! : Str => Try(Texture, [TextureLoadFailed, ..])
	load_texture! = |path| {
		texture = AssetsHost.Texture.from_resource(AssetsHost.load_texture!(path))
		if AssetsHost.Texture.handle(texture) == 0 {
			Err(TextureLoadFailed)
		} else {
			Ok(texture)
		}
	}

	## Generate a solid-color GPU texture. The temporary CPU image is released
	## inside the host; only the host-owned texture crosses back.
	generate_color_texture! : GenerateColorTexture => Try(Texture, [TextureGenerationFailed, ..])
	generate_color_texture! = |cfg| {
		texture = AssetsHost.Texture.from_resource(AssetsHost.generate_color_texture!(cfg))
		if AssetsHost.Texture.handle(texture) == 0 Err(TextureGenerationFailed) else Ok(texture)
	}

	## Generate a checkerboard GPU texture without retaining a CPU image.
	generate_checked_texture! : GenerateCheckedTexture => Try(Texture, [TextureGenerationFailed, ..])
	generate_checked_texture! = |cfg| {
		texture = AssetsHost.Texture.from_resource(AssetsHost.generate_checked_texture!(cfg))
		if AssetsHost.Texture.handle(texture) == 0 Err(TextureGenerationFailed) else Ok(texture)
	}

	## Replace every pixel. The row-major RGBA list must exactly match the
	## texture dimensions and is borrowed only for this host call.
	update_texture! : Texture, List(Color) => Try({}, [PixelCountMismatch])
	update_texture! = |texture, pixels|
		if AssetsHost.update_texture!({ texture: AssetsHost.Texture.handle(texture), pixels }) Ok({}) else Err(PixelCountMismatch)

	## Change how this texture is sampled when scaled.
	set_filter! : Texture, TextureFilter => {}
	set_filter! = |texture, filter| AssetsHost.set_texture_filter!(AssetsHost.Texture.handle(texture), filter_code(filter))

	## Change how texture coordinates outside the normal range are wrapped.
	set_wrap! : Texture, TextureWrap => {}
	set_wrap! = |texture, wrap| AssetsHost.set_texture_wrap!(AssetsHost.Texture.handle(texture), wrap_code(wrap))

	## Width in pixels.
	width : Texture -> F32
	width = |texture| AssetsHost.Texture.width(texture)

	## Height in pixels.
	height : Texture -> F32
	height = |texture| AssetsHost.Texture.height(texture)

	## Texture dimensions in pixels.
	size : Texture -> Math.Vec2
	size = |texture| { x: Assets.width(texture), y: Assets.height(texture) }

	## Rectangle covering the complete texture in pixel coordinates.
	rect : Texture -> Math.Rect
	rect = |texture| { x: 0, y: 0, width: Assets.width(texture), height: Assets.height(texture) }

	expect filter_code(Bilinear) == 1
	expect wrap_code(MirrorClamp) == 3
}

filter_code : Assets.TextureFilter -> U8
filter_code = |filter|
	match filter {
		Point => 0
		Bilinear => 1
		Trilinear => 2
		Anisotropic4x => 3
		Anisotropic8x => 4
		Anisotropic16x => 5
	}

wrap_code : Assets.TextureWrap -> U8
wrap_code = |wrap|
	match wrap {
		Repeat => 0
		Clamp => 1
		MirrorRepeat => 2
		MirrorClamp => 3
	}
