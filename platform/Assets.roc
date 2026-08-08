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

	## Opaque, host-owned mutable GPU texture with immutable dimensions.
	Texture :: AssetsHost.Texture.{

		## Load an image file into GPU texture memory.
		load! : Str => Try(Texture, [TextureLoadFailed, ResourceLimit, ..])
		load! = |path| {
			result = AssetsHost.load_texture!(path)
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

	## Load an image file into GPU texture memory. The returned value owns the
	## resource and may be safely shared between sprites, uniforms, and models.
	load_texture! : Str => Try(Texture, [TextureLoadFailed, ResourceLimit, ..])
	load_texture! = |path| Texture.load!(path)

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
