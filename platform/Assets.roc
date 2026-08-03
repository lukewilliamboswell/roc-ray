## Assets module - host-owned textures and other resources.
##
## A `Texture` is a host-backed ARC box containing its lifecycle token and
## immutable dimensions. Final Roc ARC release unloads the native texture and
## makes its typed host heap slot reusable.
import Math
import Color

Assets := [].{

	TextureInfo : {
		handle : U64,
		width : F32,
		height : F32,
	}

	Texture : Box(TextureInfo)

	LoadTextureRawResult : Texture

	TextureFilter := [Point, Bilinear, Trilinear, Anisotropic4x, Anisotropic8x, Anisotropic16x]

	TextureWrap := [Repeat, Clamp, MirrorRepeat, MirrorClamp]

	GenerateColorTexture : { width : I32, height : I32, color : Color }

	GenerateCheckedTexture : {
		width : I32,
		height : I32,
		checks_x : I32,
		checks_y : I32,
		color_a : Color,
		color_b : Color,
	}

	UpdateTextureRaw : { texture : U64, pixels : List(Color) }

	## Raw hosted effect. The host returns a static handle with token 0 on failure.
	load_texture_raw! : Str => LoadTextureRawResult
	generate_color_texture_raw! : GenerateColorTexture => Texture
	generate_checked_texture_raw! : GenerateCheckedTexture => Texture
	update_texture_raw! : UpdateTextureRaw => Bool
	set_texture_filter_raw! : U64, U8 => {}
	set_texture_wrap_raw! : U64, U8 => {}

	## Load an image file into GPU texture memory.
	load_texture! : Str => Try(Texture, [TextureLoadFailed, ..])
	load_texture! = |path| {
		texture = Assets.load_texture_raw!(path)
		if (Box.unbox(texture)).handle == 0 {
			Err(TextureLoadFailed)
		} else {
			Ok(texture)
		}
	}

	## Generate a solid-color GPU texture. The temporary CPU image is released
	## inside the host; only the ARC-owned texture crosses back.
	generate_color_texture! : GenerateColorTexture => Try(Texture, [TextureGenerationFailed, ..])
	generate_color_texture! = |cfg| {
		texture = Assets.generate_color_texture_raw!(cfg)
		if (Box.unbox(texture)).handle == 0 Err(TextureGenerationFailed) else Ok(texture)
	}

	## Generate a checkerboard GPU texture without retaining a CPU image.
	generate_checked_texture! : GenerateCheckedTexture => Try(Texture, [TextureGenerationFailed, ..])
	generate_checked_texture! = |cfg| {
		texture = Assets.generate_checked_texture_raw!(cfg)
		if (Box.unbox(texture)).handle == 0 Err(TextureGenerationFailed) else Ok(texture)
	}

	## Replace every pixel. The row-major RGBA list must exactly match the
	## texture dimensions and is borrowed only for this host call.
	update_texture! : Texture, List(Color) => Try({}, [PixelCountMismatch])
	update_texture! = |texture, pixels|
		if Assets.update_texture_raw!({ texture: (Assets.info(texture)).handle, pixels }) Ok({}) else Err(PixelCountMismatch)

	filter_code : TextureFilter -> U8
	filter_code = |filter|
		match filter {
			Point => 0
			Bilinear => 1
			Trilinear => 2
			Anisotropic4x => 3
			Anisotropic8x => 4
			Anisotropic16x => 5
		}

	wrap_code : TextureWrap -> U8
	wrap_code = |wrap|
		match wrap {
			Repeat => 0
			Clamp => 1
			MirrorRepeat => 2
			MirrorClamp => 3
		}

	set_filter! : Texture, TextureFilter => {}
	set_filter! = |texture, filter| Assets.set_texture_filter_raw!((Assets.info(texture)).handle, Assets.filter_code(filter))

	set_wrap! : Texture, TextureWrap => {}
	set_wrap! = |texture, wrap| Assets.set_texture_wrap_raw!((Assets.info(texture)).handle, Assets.wrap_code(wrap))

	info : Texture -> TextureInfo
	info = |texture| Box.unbox(texture)

	width : Texture -> F32
	width = |texture| (Assets.info(texture)).width

	height : Texture -> F32
	height = |texture| (Assets.info(texture)).height

	size : Texture -> Math.Vec2
	size = |texture| {
		texture_info = Assets.info(texture)
		{ x: texture_info.width, y: texture_info.height }
	}

	rect : Texture -> Math.Rect
	rect = |texture| {
		texture_info = Assets.info(texture)
		{ x: 0, y: 0, width: texture_info.width, height: texture_info.height }
	}

	expect Assets.filter_code(Bilinear) == 1
	expect Assets.wrap_code(MirrorClamp) == 3
}
