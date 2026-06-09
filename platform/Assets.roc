## Assets module - host-owned textures and other resources.
##
## A `Texture` is a refcounted `Box` containing a small handle plus metadata.
## The box memory is managed by Roc; the underlying raylib texture is owned by
## the host and unloaded at shutdown.
import Math

Assets := [].{

	TextureInfo : {
		handle : U64,
		width : F32,
		height : F32,
	}

	Texture : Box(TextureInfo)

	LoadTextureRawResult : {
		handle : U64,
		width : F32,
		height : F32,
	}

	## Raw hosted effect. The host returns handle 0 on load failure.
	load_texture_raw! : Str => LoadTextureRawResult

	## Load an image file into GPU texture memory.
	load_texture! : Str => Try(Texture, [TextureLoadFailed, ..])
	load_texture! = |path| {
		info = Assets.load_texture_raw!(path)
		if info.handle == 0 {
			Err(TextureLoadFailed)
		} else {
			Ok(Box.box(info))
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
