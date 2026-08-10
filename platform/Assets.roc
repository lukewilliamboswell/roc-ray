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

		## Load an image relative to this opened store. `path` is portable and
		## must be relative; absolute paths, NUL, and lexical `..` escapes fail
		## before file I/O. Symlinks are deliberately not confinement boundaries.
		texture! : Store, Str => Try(Texture, [AssetPathInvalid, AssetNotFound, AssetReadFailed, TextureLoadFailed, ResourceLimit, ..])
		texture! = |Store.(store), path| {
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
				Ok(Texture.(result.texture))
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

	## Opaque, host-owned mutable GPU texture with immutable dimensions.
	Texture :: AssetsHost.Texture.{
		## Decode an authored image embedded with a compile-time file import.
		## The byte list is borrowed only while the host decodes and uploads it;
		## no payload-sized Roc copy is made and the result retains only the GPU
		## texture.
		from_bytes! : TextureBytes => Try(Texture, [TextureLoadFailed, ResourceLimit, ..])
		from_bytes! = |cfg| {
			result = AssetsHost.load_texture_bytes!({ format: image_format_code(cfg.format), bytes: cfg.bytes })
			if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(TextureLoadFailed) else Ok(Texture.(result.texture))
		}

		## Generate a solid-color GPU texture.
		generate_color! : GenerateColorTexture => Try(Texture, [TextureGenerationFailed, ResourceLimit, ..])
		generate_color! = |cfg| {
			result = AssetsHost.generate_color_texture!(cfg)
			if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(TextureGenerationFailed) else Ok(Texture.(result.texture))
		}

		## Generate a checkerboard GPU texture.
		generate_checked! : GenerateCheckedTexture => Try(Texture, [TextureGenerationFailed, ResourceLimit, ..])
		generate_checked! = |cfg| {
			result = AssetsHost.generate_checked_texture!(cfg)
			if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(TextureGenerationFailed) else Ok(Texture.(result.texture))
		}

		## Wrap the transport handle. Platform-internal, and useless outside the
		## platform: `AssetsHost` is not exposed, so an app cannot build one of
		## these to pass in. This exists so `Program.check_uploads` can be
		## tested against a texture of a known size without a GPU.
		from_host : AssetsHost.Texture -> Texture
		from_host = |raw| Texture.(raw)

		## Read-only sampling view sharing this texture's host-owned ARC resource.
		view : Texture -> TextureView
		view = |Texture.(texture)| TextureView.(texture)

		## Width in pixels.
		width : Texture -> F32
		width = |Texture.(texture)| AssetsHost.Texture.width(texture)

		## Height in pixels.
		height : Texture -> F32
		height = |Texture.(texture)| AssetsHost.Texture.height(texture)

		## Texture dimensions in pixels.
		size : Texture -> Math.Vec2
		size = |texture| { x: texture.width(), y: texture.height() }

		## Rectangle covering the complete texture in pixel coordinates.
		rect : Texture -> Math.Rect
		rect = |texture| { x: 0, y: 0, width: texture.width(), height: texture.height() }

		## Replace every pixel in row-major RGBA order.
		##
		## An upload is a synchronous call into the graphics driver whose cost
		## is proportional to the pixels handed over, so the host meters it: a
		## frame has a fixed upload budget and reports `UploadBudgetExceeded`
		## rather than spending more of the frame than it was asked to. Startup
		## is not a frame and is not metered.
		##
		## Prefer `update_region!` when only part of the texture changed. This
		## uploads all of it however little of it differs.
		##
		## Valid in `init!` and while the platform is applying an action, and
		## nowhere else. An upload is not drawing: it mutates a resource and may
		## enter the graphics driver synchronously, so a `render!` that reached
		## for it would pay for that in the middle of a frame -- which is
		## exactly the stall the budget below exists to bound.
		update! : Texture, List(Color.Rgba) => Try({}, [PixelCountMismatch, UploadBudgetExceeded, ..])
		update! = |Texture.(texture), pixels|
			whole_texture_result(AssetsHost.update_texture!({ texture, pixels }))

		## Replace every pixel in row-major RGBA order, as an action a pure
		## `update` can return. Receiver form: `texture.update(pixels)`.
		##
		## The count is checked when the platform applies the action, so a list
		## that does not match the texture fails the cycle the same way
		## `texture.update!(pixels)?` fails it inside an effectful function.
		update : Texture, List(Color.Rgba) -> [UpdateTexture({ texture : Texture, pixels : List(Color.Rgba) }), ..]
		update = |texture, pixels| UpdateTexture({ texture: texture, pixels: pixels })

		## Replace one rectangle of the texture, in row-major RGBA order.
		##
		## `pixels` describes the rectangle, not the texture, so changing one
		## cell of an atlas costs one cell. That is what makes the per-frame
		## upload budget something an app can live inside rather than a smaller
		## ceiling on the same waste.
		##
		## The rectangle must lie inside the texture: the graphics backend does
		## no bounds checking of its own, so a region that hangs over the edge
		## is refused here rather than read past the end of the list.
		##
		## Valid in `init!` and while an action is being applied, for the same
		## reason `update!` is.
		update_region! : Texture, Region => Try({}, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded, ..])
		update_region! = |Texture.(texture), region|
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

		## Replace one rectangle of the texture, as an action a pure `update`
		## can return. Receiver form: `texture.update_region(region)`.
		update_region : Texture, Region -> [UpdateTextureRegion({ texture : Texture, region : Region }), ..]
		update_region = |texture, region| UpdateTextureRegion({ texture: texture, region: region })

		## Change how this texture is sampled when scaled.
		##
		## Sampler state belongs to the texture itself, not to a draw: it is
		## stored on the GPU object, so it applies to every draw of this
		## texture and to every value that shares the resource -- including any
		## `TextureView` taken from it. Set it once, where the texture is
		## created, rather than treating it as per-draw configuration.
		set_filter! : Texture, TextureFilter => {}
		set_filter! = |Texture.(texture), filter| AssetsHost.set_texture_filter!(texture, filter_code(filter))

		## Change how out-of-range texture coordinates are wrapped.
		##
		## Texture-global, exactly as `set_filter!` is, and for the same reason.
		set_wrap! : Texture, TextureWrap => {}
		set_wrap! = |Texture.(texture), wrap| AssetsHost.set_texture_wrap!(texture, wrap_code(wrap))

	}

	## Read-only sampled texture view. It owns the same ARC reference as its
	## source but deliberately cannot change it.
	##
	## That means no pixel updates and no sampler changes. Sampler state lives
	## on the shared GPU object, so a filter set "on a view" would silently
	## change how the owning texture and every other view of it are drawn --
	## which is the one thing a value called a read-only view must not do.
	## Set it on the `Texture` the view came from.
	TextureView :: AssetsHost.Texture.{

		## Width in pixels.
		width : TextureView -> F32
		width = |TextureView.(texture)| AssetsHost.Texture.width(texture)

		## Height in pixels.
		height : TextureView -> F32
		height = |TextureView.(texture)| AssetsHost.Texture.height(texture)

		## Texture dimensions in pixels.
		size : TextureView -> Math.Vec2
		size = |texture| { x: texture.width(), y: texture.height() }

		## Rectangle covering the complete texture in pixel coordinates.
		rect : TextureView -> Math.Rect
		rect = |texture| { x: 0, y: 0, width: texture.width(), height: texture.height() }

	}

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
	## Exposed so an app that generates pixels can stay inside the budget rather
	## than discover it. `Program.check_uploads` does that check over a whole
	## cycle's actions, which is the form worth reaching for.
	##
	## Mirrors `MAX_TEXTURE_UPLOAD_BYTES_PER_FRAME` in `src/host_native.zig`.
	max_upload_bytes_per_step : U64
	max_upload_bytes_per_step = 4 * 1024 * 1024

	## What uploading these pixels costs against the budget: four bytes each.
	upload_bytes : List(Color.Rgba) -> U64
	upload_bytes = |pixels| List.len(pixels) * 4

	## Texture sampling filter used when an image is scaled.
	TextureFilter := [Point, Bilinear, Trilinear, Anisotropic4x, Anisotropic8x, Anisotropic16x]

	## Texture-coordinate behavior outside the normal 0-to-1 range.
	TextureWrap := [Repeat, Clamp, MirrorRepeat, MirrorClamp]

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

	## Load an image through an explicit store rather than process CWD.
	load_store_texture! : Store, Str => Try(Texture, [AssetPathInvalid, AssetNotFound, AssetReadFailed, TextureLoadFailed, ResourceLimit, ..])
	load_store_texture! = |store, path| store.texture!(path)

	## Generate a solid-color GPU texture. The temporary CPU image is released
	## inside the host; only the host-owned texture crosses back.
	generate_color_texture! : GenerateColorTexture => Try(Texture, [TextureGenerationFailed, ResourceLimit, ..])
	generate_color_texture! = |cfg| Texture.generate_color!(cfg)

	## Generate a checkerboard GPU texture without retaining a CPU image.
	generate_checked_texture! : GenerateCheckedTexture => Try(Texture, [TextureGenerationFailed, ResourceLimit, ..])
	generate_checked_texture! = |cfg| Texture.generate_checked!(cfg)

	## Replace every pixel. The row-major RGBA list must exactly match the
	## texture dimensions and is borrowed only for this host call.
	update_texture! : Texture, List(Color.Rgba) => Try({}, [PixelCountMismatch, UploadBudgetExceeded, ..])
	update_texture! = |texture, pixels| texture.update!(pixels)

	## Replace every pixel, as an action a pure `update` can return.
	update_texture : Texture, List(Color.Rgba) -> [UpdateTexture({ texture : Texture, pixels : List(Color.Rgba) }), ..]
	update_texture = |texture, pixels| texture.update(pixels)

	## Replace one rectangle of a texture, paying only for that rectangle.
	update_texture_region! : Texture, Region => Try({}, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded, ..])
	update_texture_region! = |texture, region| texture.update_region!(region)

	## Replace one rectangle, as an action a pure `update` can return.
	update_texture_region : Texture, Region -> [UpdateTextureRegion({ texture : Texture, region : Region }), ..]
	update_texture_region = |texture, region| texture.update_region(region)

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
