## Host-owned textures and the store they are loaded from.
##
## Open a store, load textures from it, keep them in the model, and draw them.
## All three steps happen in `init!` in most apps:
##
## ```roc
## init! = App.init(
##     App.default,
##     |_startup| {
##         store = Assets.Store.open!(Assets.working_directory("assets"))?
##         Ok({ logo: Assets.load_texture!(store, "logo.png")?, store })
##     },
## )
##
## render! = |model, frame| {
##     frame.texture!(Draw.texture_at(model.logo, { x: 32, y: 32 }))
##     Ok({})
## }
## ```
##
## A store is an explicitly located directory the host holds a handle to, so
## every relative asset path means the same thing however the process was
## launched. The host never calls `chdir`, and a path that would escape the
## store is refused rather than rewritten.
##
## Textures are the shared texture type from the companion `roc-ray-types`
## package, re-exported here as `Assets.Texture`. Releasing the final reference
## to one unloads the native texture automatically, so there is no `unload` to
## remember.
##
## Every effect in this module changes host state: each is legal in `init!`,
## `update!`, and tasks, and refused in `render!`, where a decode or an upload
## would land in the middle of drawing a frame. Loading per frame is a cost
## rather than an error -- pay it once at startup.
##
## `ResourceLimit` on any of them means the host's fixed texture table is full.
## It is a bound on how many textures exist at once, not on how fast they are
## made, so it is answered rather than retried: release a texture the app no
## longer draws, or load fewer.
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
	## a package written against the package's own `Texture` unifies with both.
	Texture : RrtTexture.Texture

	## An opened, explicitly located disk asset store. The host retains the
	## directory handle, not the process working directory; every relative asset
	## lookup is made through that handle.
	Store :: AssetsHost.Store.{

		## Open the store described by a `StoreConfig`, checking its manifest if
		## one was required.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		##
		## The first four failures are about the root directory: `RootNotFound`
		## is nothing at that path, `RootNotDirectory` is something there that
		## is not a directory, `RootUnreadable` is a directory the process may
		## not open, and `InvalidRootPath` is a path this host will not accept
		## at all -- one holding a NUL, or a relative form that escapes.
		##
		## The rest are about the `roc-assets.manifest` a `RequireManifest`
		## config asked for. `ManifestMissing` is no manifest beside the assets,
		## `ManifestUnreadable` is one that could not be read, and
		## `ManifestMalformed` is one that is not a manifest. Of the four
		## comparisons, `AssetSetMismatch` is a manifest describing a different
		## asset set than the one expected, `SchemaMismatch` a manifest written
		## to a different schema version, `ContentVersionMismatch` a different
		## content version, and `ContentHashMismatch` a declared content hash
		## that is not the expected one. `InvalidExpectedContentHash` is the
		## expectation itself being unusable -- a `Sha256` string that is not 64
		## hexadecimal characters.
		##
		## A `Sha256` expectation compares against the manifest's declaration
		## only. Nothing walks or hashes the loose files, so opening a store
		## stays constant-time in the number of assets.
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
		## `stub` is what every host resource in the platform calls its
		## resource-free test value, so a model full of assets can be written
		## down in an `expect`.
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

	## Whether opening a store checks the asset-set manifest named
	## `roc-assets.manifest` beside it. `IgnoreManifest` does not look;
	## `RequireManifest` fails the open unless the manifest is there and matches
	## the expectation.
	ManifestPolicy := [IgnoreManifest, RequireManifest(ManifestExpectation)]

	## How closely a manifest's declared content has to match. `AnyContent`
	## deliberately leaves it unconstrained, which is what a directory of loose
	## files under development wants. `Sha256` carries the 64-character
	## hexadecimal digest the manifest must declare.
	ContentExpectation := [AnyContent, Sha256(Str)]

	## What a `RequireManifest` open expects the manifest to say: which asset
	## set it describes, which schema version it was written to, which content
	## version it is, and which content it declares.
	ManifestExpectation : { asset_set : Str, schema : U32, content_version : U32, content : ContentExpectation }

	## Where a store's root is and whether its manifest is checked. A plain
	## record; build it with `beside_executable`, `working_directory` or
	## `absolute_directory`, and add an expectation with `with_manifest`.
	StoreConfig : { root : StoreLocation, manifest : ManifestPolicy }

	## Start from an application/executable-relative asset directory. This is the
	## normal packaged-app choice: the assets travel with the executable, so the
	## store resolves the same way however the app was launched.
	beside_executable : Str -> StoreConfig
	beside_executable = |root| { root: BesideExecutable(root), manifest: IgnoreManifest }

	## Start from a directory relative to the process working directory. This is
	## what running an example from the repository root wants, and what a tool
	## invoked from a project directory wants; it moves with the shell rather
	## than with the executable.
	working_directory : Str -> StoreConfig
	working_directory = |root| { root: WorkingDirectory(root), manifest: IgnoreManifest }

	## Start from an absolute path, for a store the app was told about at
	## runtime -- a mod directory, or a content pack chosen from argv.
	absolute_directory : Str -> StoreConfig
	absolute_directory = |root| { root: AbsoluteDirectory(root), manifest: IgnoreManifest }

	## Require this store's `roc-assets.manifest` to match an expectation, so a
	## mismatched or half-updated asset set fails at startup rather than as a
	## missing texture later.
	with_manifest : StoreConfig, ManifestExpectation -> StoreConfig
	with_manifest = |cfg, expected| { ..cfg, manifest: RequireManifest(expected) }

	## Image bytes accepted by raylib's in-memory image loader.
	ImageFormat := [Png, Jpeg, Bmp, Tga, Gif, Qoi]

	## An authored image embedded with a compile-time file import, tagged with
	## its format. The format is stated rather than sniffed, so a mislabelled
	## file fails to decode instead of decoding as something else.
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

	## How many bytes an RGBA pixel list occupies on the wire: four per pixel.
	##
	## An upload borrows the list rather than copying it, so this is what an app
	## measures a `update_texture!` or `update_texture_region!` against when it
	## is budgeting per-frame pixel traffic.
	rgba_byte_size : List(Color.Rgba) -> U64
	rgba_byte_size = |pixels| List.len(pixels) * 4

	## Texture sampling filter used when an image is scaled. `Point` keeps pixel
	## art crisp; the rest smooth it.
	TextureFilter := [Point, Bilinear, Trilinear, Anisotropic4x, Anisotropic8x, Anisotropic16x].{

		## Compare two filters.
		is_eq : _
	}

	## Texture-coordinate behavior outside the normal 0-to-1 range.
	TextureWrap := [Repeat, Clamp, MirrorRepeat, MirrorClamp].{

		## Compare two wrap modes.
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
	## Legal in `init!`, `update!`, and tasks; refused in `render!`. This is one
	## of the two effects that sit outside the platform's three phase rules: it
	## loads rather than waits, reading the file on the calling thread instead
	## of parking a task, so a large load during `update!` costs that frame.
	## Prefer `init!`.
	##
	## `path` must be relative; `PathInvalid` is an absolute path, one holding a
	## NUL, or a lexical `..` escape, and is answered before any file I/O.
	## `NotFound` is no such file under the store, `ReadFailed` is a file that
	## is there and could not be read, and `TextureLoadFailed` is bytes raylib
	## would not decode as an image.
	load_texture! : Store, Str => Try(Texture, [PathInvalid, NotFound, ReadFailed, TextureLoadFailed, ResourceLimit, ..])
	load_texture! = |Store.(store), path| {
		result = AssetsHost.load_store_texture!({ store, path })
		if result.err == 1 {
			Err(PathInvalid)
		} else if result.err == 2 {
			Err(NotFound)
		} else if result.err == 3 {
			Err(ReadFailed)
		} else if result.err == 4 {
			Err(TextureLoadFailed)
		} else if result.err != 0 {
			Err(ResourceLimit)
		} else {
			Ok(result.texture)
		}
	}

	## Decode an authored image embedded with a compile-time file import.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	texture_from_bytes! : TextureBytes => Try(Texture, [TextureLoadFailed, ResourceLimit, ..])
	texture_from_bytes! = |cfg| {
		result = AssetsHost.load_texture_bytes!({ format: image_format_code(cfg.format), bytes: cfg.bytes })
		if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(TextureLoadFailed) else Ok(result.texture)
	}

	## Generate a solid-color GPU texture. The temporary CPU image is released
	## inside the host; only the host-owned texture crosses back.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	generate_color_texture! : GenerateColorTexture => Try(Texture, [TextureGenerationFailed, ResourceLimit, ..])
	generate_color_texture! = |cfg| {
		result = AssetsHost.generate_color_texture!(cfg)
		if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(TextureGenerationFailed) else Ok(result.texture)
	}

	## Generate a checkerboard GPU texture without retaining a CPU image.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	generate_checked_texture! : GenerateCheckedTexture => Try(Texture, [TextureGenerationFailed, ResourceLimit, ..])
	generate_checked_texture! = |cfg| {
		result = AssetsHost.generate_checked_texture!(cfg)
		if result.err == 2 Err(ResourceLimit) else if result.err != 0 Err(TextureGenerationFailed) else Ok(result.texture)
	}

	## Replace every pixel. The row-major RGBA list must exactly match the texture
	## dimensions and is borrowed only for this host call.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	update_texture! : Texture, List(Color.Rgba) => Try({}, [PixelCountMismatch, ..])
	update_texture! = |texture, pixels|
		whole_texture_result(AssetsHost.update_texture!({ texture, pixels }))

	## Replace one rectangle of a texture, paying only for that rectangle.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
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
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	set_texture_filter! : Texture, TextureFilter => {}
	set_texture_filter! = |texture, filter| AssetsHost.set_texture_filter!(texture, filter_code(filter))

	## Change how out-of-range texture coordinates are wrapped.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
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
