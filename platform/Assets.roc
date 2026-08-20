## Assets module - host-owned textures and other resources.
##
## Textures use the shared `rrt.Texture` representation, re-exported here as
## `Assets.Texture`. Load or generate them during initialization, keep them in
## the model, then draw or update them through this module. Releasing the final
## handle reference unloads the native texture automatically.
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

	## How many bytes of texture upload one cycle may ask for.
	##
	## A frame has a fixed upload budget because an upload enters the graphics
	## driver synchronously and a driver call is not free. `init!` is exempt:
	## startup is not a frame, and an app builds its atlases there.
	##
	## Going over is not fatal. Actions apply in order, and the first upload that
	## does not fit is skipped along with every upload after it in the same
	## cycle; those textures keep the contents they already had, and every action
	## that is not an upload still runs. So an app that guesses wrong loses a
	## frame of pixels rather than the process.
	##
	## Exposed so an app that generates pixels can stay inside the budget rather
	## than discover it a frame late. `Program.check_uploads` answers the same
	## question over a whole cycle's actions and stops exactly where the platform
	## stops, which is the form worth reaching for.
	##
	## Mirrors `MAX_TEXTURE_UPLOAD_BYTES_PER_FRAME` in `src/host_native.zig`.
	max_upload_bytes_per_step : U64
	max_upload_bytes_per_step = 4 * 1024 * 1024

	## What uploading these pixels costs against the budget: four bytes each.
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

	## Load an image relative to an explicit store. `path` must be relative;
	## absolute paths, NUL, and lexical `..` escapes fail before file I/O.
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
	update_texture! : Texture, List(Color.Rgba) => Try({}, [PixelCountMismatch, UploadBudgetExceeded, ..])
	update_texture! = |texture, pixels|
		whole_texture_result(AssetsHost.update_texture!({ texture, pixels }))

	## Replace every pixel, as an action a pure `update` can return.
	update_texture : Texture, List(Color.Rgba) -> [UpdateTexture({ texture : Texture, pixels : List(Color.Rgba) }), ..]
	update_texture = |texture, pixels| UpdateTexture({ texture, pixels })

	## Replace one rectangle of a texture, paying only for that rectangle.
	update_texture_region! : Texture, Region => Try({}, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded, ..])
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

	## Replace one rectangle, as an action a pure `update` can return.
	update_texture_region : Texture, Region -> [UpdateTextureRegion({ texture : Texture, region : Region }), ..]
	update_texture_region = |texture, region| UpdateTextureRegion({ texture, region })

	## Change how this texture is sampled when scaled.
	set_texture_filter! : Texture, TextureFilter => {}
	set_texture_filter! = |texture, filter| AssetsHost.set_texture_filter!(texture, filter_code(filter))

	## Change how this texture is sampled when scaled, as an action a pure
	## `update` can return.
	set_texture_filter : Texture, TextureFilter -> [SetTextureFilter({ texture : Texture, filter : TextureFilter }), ..]
	set_texture_filter = |texture, filter| SetTextureFilter({ texture, filter })

	## Change how out-of-range texture coordinates are wrapped.
	set_texture_wrap! : Texture, TextureWrap => {}
	set_texture_wrap! = |texture, wrap| AssetsHost.set_texture_wrap!(texture, wrap_code(wrap))

	## Change how out-of-range texture coordinates are wrapped, as an action a
	## pure `update` can return.
	set_texture_wrap : Texture, TextureWrap -> [SetTextureWrap({ texture : Texture, wrap : TextureWrap }), ..]
	set_texture_wrap = |texture, wrap| SetTextureWrap({ texture, wrap })

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
upload_err_budget : U8
upload_err_budget = 4

## Code the host returns for a region that hangs over the texture's edge.
## Mirrored in `src/host_native.zig`.
upload_err_out_of_bounds : U8
upload_err_out_of_bounds = 3

## Decode the host's code for a whole-texture upload, which has no region to
## be out of bounds.
whole_texture_result : U8 -> Try({}, [PixelCountMismatch, UploadBudgetExceeded, ..])
whole_texture_result = |code|
	if code == 0 {
		Ok({})
	} else if code == upload_err_budget {
		Err(UploadBudgetExceeded)
	} else {
		Err(PixelCountMismatch)
	}

## Decode the host's code for a region upload.
region_result : U8 -> Try({}, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded, ..])
region_result = |code|
	if code == 0 {
		Ok({})
	} else if code == upload_err_out_of_bounds {
		Err(RegionOutOfBounds)
	} else if code == upload_err_budget {
		Err(UploadBudgetExceeded)
	} else {
		Err(PixelCountMismatch)
	}
