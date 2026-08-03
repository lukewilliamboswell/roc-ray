## Assets module - host-owned textures and other resources.
##
## A `Texture` is a host-backed ARC box containing its lifecycle token and
## immutable dimensions. Final Roc ARC release unloads the native texture and
## makes its typed host heap slot reusable.
import Math

Assets := [].{

	TextureInfo : {
		handle : U64,
		width : F32,
		height : F32,
	}

	Texture : Box(TextureInfo)

	LoadTextureRawResult : Texture

	## Raw hosted effect. The host returns a static handle with token 0 on failure.
	load_texture_raw! : Str => LoadTextureRawResult

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
}
