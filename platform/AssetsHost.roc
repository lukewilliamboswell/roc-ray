## Internal texture transport and hosted effects.
##
## This module is intentionally not exposed by the platform package. Public
## applications use `Assets.Texture`; other platform modules use the methods on
## this opaque nominal value to keep lifecycle tokens off the public API.
import Color

AssetsHost := [].{
	Texture :: { resource : Box({ handle : U64, width : F32, height : F32 }) }.{
		from_resource : Box({ handle : U64, width : F32, height : F32 }) -> Texture
		from_resource = |resource| { resource: resource }

		width : Texture -> F32
		width = |texture| (Box.unbox(texture.resource)).width

		height : Texture -> F32
		height = |texture| (Box.unbox(texture.resource)).height
	}

	TextureResult : { texture : Texture, err : U8 }

	GenerateColorTexture : { width : I32, height : I32, color : Color.Rgba }

	GenerateCheckedTexture : {
		width : I32,
		height : I32,
		checks_x : I32,
		checks_y : I32,
		color_a : Color.Rgba,
		color_b : Color.Rgba,
	}

	UpdateTexture : { texture : Texture, pixels : List(Color.Rgba) }

	load_texture! : Str => TextureResult
	generate_color_texture! : GenerateColorTexture => TextureResult
	generate_checked_texture! : GenerateCheckedTexture => TextureResult
	update_texture! : UpdateTexture => U8
	set_texture_filter! : Texture, U8 => {}
	set_texture_wrap! : Texture, U8 => {}
}
