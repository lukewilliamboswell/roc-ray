## Host-owned textures and the store they are loaded from.
##
## Textures use the shared `rrt.Texture` representation, re-exported here as
## `Assets.Texture`. Load or generate them in `init!`, keep them in the model,
## then draw or update them through this module. Releasing the final handle
## reference unloads the native texture automatically, so there is no `unload`
## to remember.
##
## Every effect in this module changes host state: each is legal in `init!`,
## `update!`, and tasks, and refused in `render!`, where a decode or an upload
## would land in the middle of drawing a frame. Loading per frame is a cost
## rather than an error -- pay it once at startup.
import Color
import AssetsHost
import rrt.Texture as RrtTexture

Assets := [].{

	## A host-owned GPU texture: an opaque, reference-counted native handle plus
	## the pixel width and height, kept on the value so layout and
	## source-rectangle math stays pure.
	##
	## This is the shared texture type from the companion `roc-ray-types`
	## package, re-exported so an app can name it without depending on that
	## package as well. `Draw.Texture` is the same type under a second name, and
	## a package written against `rrt.Texture` unifies with both.
	Texture : RrtTexture.Texture

	## An opened, explicitly located disk asset store. The host retains the
	## directory handle, not the process working directory; every relative asset
	## lookup is made through that handle.
	Store :: AssetsHost.Store.{
		open! : StoreConfig => Try(Store, [RootNotFound, RootNotDirectory, RootUnreadable, InvalidRootPath, InvalidExpectedContentHash, ManifestMissing, ManifestUnreadable, ManifestMalformed, AssetSetMismatch, SchemaMismatch, ContentVersionMismatch, ContentHashMismatch, ResourceLimit, ..])
		open! = |cfg| {
			result = AssetsHost.open_store!(store_open_config(cfg))
			match result.err {
				0 => Ok(Store.(result.store))
				1 => Err(RootNotFound)
				2 => Err(RootNotDirectory)
				3 => Err(RootUnreadable)
				4 => Err(InvalidRootPath)
				5 => Err(InvalidExpectedContentHash)
				6 => Err(ManifestMissing)
				7 => Err(ManifestUnreadable)
				8 => Err(ManifestMalformed)
				9 => Err(AssetSetMismatch)
				10 => Err(SchemaMismatch)
				11 => Err(ContentVersionMismatch)
				12 => Err(ContentHashMismatch)
				_ => Err(ResourceLimit)
			}
		}

		## Resource-free store value for pure tests.
		##
		## The handle never resolves to an open directory, so every load made
		## through it fails the way a load through a released store does. It
		## exists for the app that keeps a store in its model, to let a pure
		## `expect` build that model. Do not use it to test asset resolution or
		## resource lifetime.
		stub : Store
		stub = Store.(AssetsHost.Store.stub)
	}

	## How a disk store root is resolved. These choices are explicit so moving an
	## executable, changing CWD, and selecting a mod directory cannot silently
	## change one another's meaning. The host never calls `chdir`.
	StoreLocation := [BesideExecutable(Str), WorkingDirectory(Str), AbsoluteDirectory(Str)]

	## Optional startup validation for an asset-set manifest named
	## `roc-assets.manifest`. `Sha256` asks the host to compare this expected
	## SHA-256 with the manifest declaration only; it does not walk or hash loose
	## files at startup. `AnyContent` deliberately leaves the declaration
	## unconstrained.
	ManifestPolicy := [IgnoreManifest, RequireManifest(ManifestExpectation)]
	ContentExpectation := [AnyContent, Sha256(Str)]
	ManifestExpectation : { asset_set : Str, schema : U32, content_version : U32, content : ContentExpectation }
	StoreConfig : { root : StoreLocation, manifest : ManifestPolicy }

	## Start from an application/executable-relative asset directory. This is the
	## normal packaged-app choice.
	beside_executable : Str -> StoreConfig
	beside_executable = |root| { root: BesideExecutable(root), manifest: IgnoreManifest }

	working_directory : Str -> StoreConfig
	working_directory = |root| { root: WorkingDirectory(root), manifest: IgnoreManifest }

	absolute_directory : Str -> StoreConfig
	absolute_directory = |root| { root: AbsoluteDirectory(root), manifest: IgnoreManifest }

	with_manifest : StoreConfig, ManifestExpectation -> StoreConfig
	with_manifest = |cfg, expected| { ..cfg, manifest: RequireManifest(expected) }

	## Image bytes accepted by raylib's in-memory image loader.
	ImageFormat := [Png, Jpeg, Bmp, Tga, Gif, Qoi]
	TextureBytes : { format : ImageFormat, bytes : List(U8) }

	## A rectangle of a texture and the pixels to put in it, in row-major RGBA
	## order. `pixels` must hold exactly `width * height` entries.
	Region : {
		x : I32,
		y : I32,
		width : I32,
		height : I32,
		pixels : List(Color.Rgba),
	}

	## The byte size of an RGBA pixel list: four bytes per pixel.
	upload_bytes : List(Color.Rgba) -> U64
	upload_bytes = |pixels| List.len(pixels) * 4

	## Texture sampling filter used when an image is scaled.
	TextureFilter := [Point, Bilinear, Trilinear, Anisotropic4x, Anisotropic8x, Anisotropic16x].{
		is_eq : _
	}

	## Texture-coordinate behavior outside the normal 0-to-1 range.
	TextureWrap := [Repeat, Clamp, MirrorRepeat, MirrorClamp].{
		is_eq : _
	}

	## Configuration for a solid-color generated texture.
	GenerateColorTexture : { width : I32, height : I32, color : Color.Rgba }

	## Configuration for a generated checkerboard texture.
	GenerateCheckedTexture : {
		width : I32,
		height : I32,
		checks_x : I32,
		checks_y : I32,
		color_a : Color.Rgba,
		color_b : Color.Rgba,
	}

	## Load an image relative to an explicit store.
	##
	## `path` must be relative; absolute paths, NUL, and lexical `..` escapes
	## fail before file I/O. This reads the file on the calling thread rather
	## than parking, so a large load during `update!` costs that frame; prefer
	## `init!`.
	load_texture! : Store, Str => Try(Texture, [AssetPathInvalid, AssetNotFound, AssetReadFailed, TextureLoadFailed, ResourceLimit, ..])
	load_texture! = |Store.(store), path| {
		result = AssetsHost.load_store_texture!({ store, path })
		if result.err == 1 {
			Err(AssetPathInvalid)
		} else if result.err == 2 {
			Err(AssetNotFound)
		} else if result.err == 3 {
			Err(AssetReadFailed)
		} else if result.err == 4 {
			Err(TextureLoadFailed)
		} else if result.err != 0 {
			Err(ResourceLimit)
		} else {
			Ok(result.texture)
		}
	}

	## Decode an authored image embedded with a compile-time file import.
	texture_from_bytes! : TextureBytes => Try(Texture, [TextureLoadFailed, ResourceLimit, ..])
	texture_from_bytes! = |cfg| {
		result = AssetsHost.load_texture_bytes!({ format: image_format_code(cfg.format), bytes: cfg.bytes })
		if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(TextureLoadFailed) else Ok(result.texture)
	}

	## Generate a solid-color GPU texture. The temporary CPU image is released
	## inside the host; only the host-owned texture crosses back.
	generate_color_texture! : GenerateColorTexture => Try(Texture, [TextureGenerationFailed, ResourceLimit, ..])
	generate_color_texture! = |cfg| {
		result = AssetsHost.generate_color_texture!(cfg)
		if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(TextureGenerationFailed) else Ok(result.texture)
	}

	## Generate a checkerboard GPU texture without retaining a CPU image.
	generate_checked_texture! : GenerateCheckedTexture => Try(Texture, [TextureGenerationFailed, ResourceLimit, ..])
	generate_checked_texture! = |cfg| {
		result = AssetsHost.generate_checked_texture!(cfg)
		if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(TextureGenerationFailed) else Ok(result.texture)
	}

	## Replace every pixel. The row-major RGBA list must exactly match the
	## texture dimensions and is borrowed only for this host call.
	update_texture! : Texture, List(Color.Rgba) => Try({}, [PixelCountMismatch, ..])
	update_texture! = |texture, pixels|
		whole_texture_result(AssetsHost.update_texture!({ texture, pixels }))

	## Replace one rectangle of a texture, paying only for that rectangle.
	update_texture_region! : Texture, Region => Try({}, [PixelCountMismatch, RegionOutOfBounds, ..])
	update_texture_region! = |texture, region|
		region_result(
			AssetsHost.update_texture_region!({
				texture,
				x: region.x,
				y: region.y,
				width: region.width,
				height: region.height,
				pixels: region.pixels,
			}),
		)

	## Change how this texture is sampled when scaled.
	set_texture_filter! : Texture, TextureFilter => {}
	set_texture_filter! = |texture, filter| AssetsHost.set_texture_filter!(texture, filter_code(filter))

	## Change how out-of-range texture coordinates are wrapped.
	set_texture_wrap! : Texture, TextureWrap => {}
	set_texture_wrap! = |texture, wrap| AssetsHost.set_texture_wrap!(texture, wrap_code(wrap))

	expect filter_code(Bilinear) == 1
	expect wrap_code(MirrorClamp) == 3
}

store_open_config : Assets.StoreConfig -> AssetsHost.StoreOpen
store_open_config = |cfg| {
	location = match cfg.root {
		BesideExecutable(path) => { kind: 0, path }
		WorkingDirectory(path) => { kind: 1, path }
		AbsoluteDirectory(path) => { kind: 2, path }
	}
	manifest = match cfg.manifest {
		IgnoreManifest => { required: Bool.False, asset_set: "", schema: 0, content_version: 0, content_hash_mode: 0, content_hash: "" }
		RequireManifest(expected) => {
			content = match expected.content {
				AnyContent => { mode: 0, hash: "" }
				Sha256(hash) => { mode: 1, hash }
			}
			{ required: Bool.True, asset_set: expected.asset_set, schema: expected.schema, content_version: expected.content_version, content_hash_mode: content.mode, content_hash: content.hash }
		}
	}
	{
		location_kind: location.kind,
		root: location.path,
		manifest_required: manifest.required,
		asset_set: manifest.asset_set,
		schema: manifest.schema,
		content_version: manifest.content_version,
		content_hash_mode: manifest.content_hash_mode,
		content_hash: manifest.content_hash,
	}
}

image_format_code : Assets.ImageFormat -> U8
image_format_code = |format|
	match format {
		Png => 0
		Jpeg => 1
		Bmp => 2
		Tga => 3
		Gif => 4
		Qoi => 5
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

## Code the host returns when an upload exceeded the frame's budget.
## Mirrored in `src/host_native.zig`.
## Code the host returns for a region that hangs over the texture's edge.
## Mirrored in `src/host_native.zig`.
upload_err_out_of_bounds : U8
upload_err_out_of_bounds = 3

## Decode the host's code for a whole-texture upload, which has no region to
## be out of bounds.
whole_texture_result : U8 -> Try({}, [PixelCountMismatch, ..])
whole_texture_result = |code|
	if code == 0 {
		Ok({})
	} else {
		Err(PixelCountMismatch)
	}

## Decode the host's code for a region upload.
region_result : U8 -> Try({}, [PixelCountMismatch, RegionOutOfBounds, ..])
region_result = |code|
	if code == 0 {
		Ok({})
	} else if code == upload_err_out_of_bounds {
		Err(RegionOutOfBounds)
	} else {
		Err(PixelCountMismatch)
	}
