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

		resource : Texture -> Box({ handle : U64, width : F32, height : F32 })
		resource = |texture| texture.resource

		handle : Texture -> U64
		handle = |texture| (Box.unbox(texture.resource)).handle

		width : Texture -> F32
		width = |texture| (Box.unbox(texture.resource)).width

		height : Texture -> F32
		height = |texture| (Box.unbox(texture.resource)).height
	}

	GenerateColorTexture : { width : I32, height : I32, color : Color }

	GenerateCheckedTexture : {
		width : I32,
		height : I32,
		checks_x : I32,
		checks_y : I32,
		color_a : Color,
		color_b : Color,
	}

	UpdateTexture : { texture : U64, pixels : List(Color) }

	load_texture! : Str => Box({ handle : U64, width : F32, height : F32 })
	generate_color_texture! : GenerateColorTexture => Box({ handle : U64, width : F32, height : F32 })
	generate_checked_texture! : GenerateCheckedTexture => Box({ handle : U64, width : F32, height : F32 })
	update_texture! : UpdateTexture => Bool
	set_texture_filter! : U64, U8 => {}
	set_texture_wrap! : U64, U8 => {}
}
