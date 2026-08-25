## Internal texture transport and hosted effects.
##
## This module is intentionally not exposed by the platform package.
import Color
import rrt.Texture

AssetsHost := [].{

	## Opaque directory store. The backing directory handle is owned by a typed
	## host ARC heap, so a copied Roc value keeps the directory open.
	Store :: Box(U64).{

		## The invalid token, as a resource-free handle. See `Assets.Store.stub`.
		stub : Store
		stub = Store.(Box.box(U64.highest))
	}

	StoreOpen : {
		location_kind : U8,
		root : Str,
		manifest_required : Bool,
		asset_set : Str,
		schema : U32,
		content_version : U32,
		content_hash_mode : U8,
		content_hash : Str,
	}

	StoreOpenResult : { store : Store, err : U8 }
	StoreLoad : { store : Store, path : Str }

	TextureResult : { texture : Texture, err : U8 }
	TextureBytes : { format : U8, bytes : List(U8) }

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

	UpdateTextureRegion : {
		texture : Texture,
		x : I32,
		y : I32,
		width : I32,
		height : I32,
		pixels : List(Color.Rgba),
	}

	open_store! : StoreOpen => StoreOpenResult
	load_store_texture! : StoreLoad => TextureResult
	load_texture_bytes! : TextureBytes => TextureResult
	generate_color_texture! : GenerateColorTexture => TextureResult
	generate_checked_texture! : GenerateCheckedTexture => TextureResult
	update_texture! : UpdateTexture => U8
	update_texture_region! : UpdateTextureRegion => U8
	set_texture_filter! : Texture, U8 => {}
	set_texture_wrap! : Texture, U8 => {}
}
