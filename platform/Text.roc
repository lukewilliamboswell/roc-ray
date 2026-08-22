## Fonts, text measurement, and prepared text drawing.
##
## A string is described once and drawn many times. `Text.from` starts a
## `Builder`, the `size`, `spacing` and `font` receivers adjust it, and
## `prepare!` hands the host the UTF-8 bytes, the style, and the measured
## bounds. What comes back is a `Prepared`, which every later frame draws with
## no encoding, no measuring, and no allocation:
##
## ```roc
## title = Text.from("Hello", font).size(38).prepare!()?
## ```
##
## ```roc
## model.title.draw!(frame, { pos: { x: 400, y: 60 }, color: Color.white, align: Text.align_top_center })
## ```
##
## `align` says which point of the text `pos` names, so centring a title needs
## no measurement at the call site. When one is wanted anyway -- to size a
## panel around the text, or to hit-test it -- `prepared.bounds()`
## answers the size the host measured, and `Draw.Font.measure` answers the same
## question for a string that was never prepared. Both are pure, so layout can
## be decided in `update!` and kept in the model.
##
## Most calls have a receiver form and a free-function form:
## `prepared.draw!(frame, placement)` and `Text.draw_prepared!(frame, cfg)` are
## the same drawing call, and `builder.prepare!()` and
## `Text.prepare_builder!(builder)` are the same preparation. Prefer the
## receiver. Note that the two draw forms take the frame in different
## positions: the receiver's own value comes first, so the frame is its second
## argument, while the free function takes the frame first as every other free
## drawing function does.
##
## The two halves live in different phases. Preparing text allocates a host
## resource: it is legal in `init!`, `update!`, and tasks, and refused in
## `render!`. Drawing prepared text is legal in `render!` only, inside the
## frame scope the host opens around it. Prepare the strings an app draws
## repeatedly once, in `init!`, and keep the `Prepared` values in the model.
import Color
import Draw
import DrawHost
import Math
import rrt.Font as RrtFont

Text := [].{

	## Which horizontal edge or centre of the text `pos` names.
	HAlign : [Left, Center, Right]

	## Which vertical edge or centre of the text `pos` names.
	VAlign : [Top, Middle, Bottom]

	## Where `pos` sits within the text, in both axes at once. The nine
	## `align_*` values below are every combination, named.
	Align : {
		horizontal : HAlign,
		vertical : VAlign,
	}

	## A measured width and height, in the same logical units as every drawing
	## call. This is `Draw.TextSize` and the types package's `Font.Size` under a
	## third name; they are one type.
	Size : RrtFont.Size

	## Everything a draw needs beyond the text itself: where to put it, what
	## colour to paint it, and which point of it `pos` names.
	Placement : {
		pos : Math.Vec2,
		color : Color.Rgba,
		align : Align,
	}

	## A string and the style to prepare it with. Start one with `Text.from`,
	## adjust it with the receivers below, and finish it with `prepare!`.
	##
	## A builder is a plain description, so building one costs nothing and it
	## can be assembled anywhere. Only `prepare!` reaches the host.
	Builder :: {
		content : Str,
		size : F32,
		spacing : F32,
		font : Draw.Font,
	}.{

		## Draw this text at a different pixel size. The default is `20`.
		##
		## Sizes far above the font's own `base_size` scale its glyph atlas up
		## rather than re-rasterizing, so load the font at the size wanted when
		## the difference shows.
		size : Builder, F32 -> Builder
		size = |builder, value| { ..builder, size: value }

		## Change the space added between glyphs. The default is
		## `Text.default_spacing`.
		spacing : Builder, F32 -> Builder
		spacing = |builder, value| { ..builder, spacing: value }

		## Draw this text in a different font.
		font : Builder, Draw.Font -> Builder
		font = |builder, value| { ..builder, font: value }

		## Cache immutable UTF-8 text, font and style, and measurement in the
		## host.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		prepare! : Builder => Try(Prepared, [ResourceLimit, ..])
		prepare! = |builder| Text.prepare_builder!(builder)
	}

	## Host-owned immutable text. Its ARC handle retains any loaded font and its
	## cached native NUL-terminated bytes are reused by every draw.
	Prepared :: {
		resource : DrawHost.PreparedText,
		measured : Size,
	}.{

		## The size the host measured while preparing this text.
		##
		## Pure, and free: the measurement was taken once, at preparation. Use
		## it to size a panel around the text or to hit-test it, in `update!` as
		## readily as in `render!`.
		bounds : Prepared -> Size
		bounds = |Prepared.(prepared)| prepared.measured

		## Draw this prepared text at a placement.
		##
		## Legal in `render!` only.
		##
		## The frame is the second argument here because the prepared text is
		## the receiver; `Text.draw_prepared!` is the same call with the frame
		## first.
		draw! : Prepared, Draw.Frame, Placement => {}
		draw! = |prepared, frame, placement|
			Text.draw_prepared!(
				frame,
				{
					text: prepared,
					pos: placement.pos,
					color: placement.color,
					align: placement.align,
				},
			)

		## Resource-free prepared text for pure tests.
		##
		## Prepared text carries more than a handle: the host measured it once
		## while preparing it, and the value keeps that size. A stub has no
		## measurement to keep, so its `measured` bounds are zeroed -- `bounds()`
		## answers `{ width: 0, height: 0 }` and every alignment therefore
		## resolves to the placement point itself. Copy this value with the
		## bounds a test needs, the way the `roc-ray-types` package's
		## `Texture.stub` is copied with dimensions.
		##
		## The handle never resolves to a host resource, so drawing it is skipped
		## the way a released one is. Do not use it to test drawing, measurement,
		## or resource lifetime.
		stub : Prepared
		stub = Prepared.(
			{
				resource: DrawHost.PreparedText.stub,
				measured: { width: 0, height: 0 },
			},
		)
	}

	## The letter spacing a `Builder` starts with, and what raylib's own text
	## drawing uses.
	default_spacing : F32
	default_spacing = Draw.default_spacing

	## Start describing a string drawn in a font. Adjust the result with
	## `size`, `spacing` and `font`, then call `prepare!`.
	from : Str, Draw.Font -> Builder
	from = |content, font| {
		content,
		size: 20,
		spacing: Text.default_spacing,
		font,
	}

	## Prepare a builder's text, as `Builder.prepare!` does.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	prepare_builder! : Builder => Try(Prepared, [ResourceLimit, ..])
	prepare_builder! = |builder| {
		result = DrawHost.prepare_text!({
			text: builder.content,
			size: builder.size,
			spacing: builder.spacing,
			font: builder.font.for_host(),
		})
		if result.err == 2 {
			Err(ResourceLimit)
		} else if result.err != 0 {
			crash "prepared text host invariant failed"
		} else {
			Ok(
				Prepared.(
					{
						resource: result.prepared,
						measured: { width: result.width, height: result.height },
					},
				),
			)
		}
	}

	## Anchor `pos` at the top-left corner of the text.
	##
	## These nine constants are the ones to use with `Placement`. `Draw` has a
	## set under the same names for `Draw.text_at!`, which draws an unprepared
	## string.
	align_top_left : Align
	align_top_left = { horizontal: Left, vertical: Top }

	## Anchor `pos` at the top edge, centred horizontally.
	align_top_center : Align
	align_top_center = { horizontal: Center, vertical: Top }

	## Anchor `pos` at the top-right corner of the text.
	align_top_right : Align
	align_top_right = { horizontal: Right, vertical: Top }

	## Anchor `pos` at the centre of the text, in both axes.
	align_center : Align
	align_center = { horizontal: Center, vertical: Middle }

	## Anchor `pos` at the left edge, centred vertically.
	align_middle_left : Align
	align_middle_left = { horizontal: Left, vertical: Middle }

	## Anchor `pos` at the right edge, centred vertically.
	align_middle_right : Align
	align_middle_right = { horizontal: Right, vertical: Middle }

	## Anchor `pos` at the bottom-left corner of the text.
	align_bottom_left : Align
	align_bottom_left = { horizontal: Left, vertical: Bottom }

	## Anchor `pos` at the bottom edge, centred horizontally.
	align_bottom_center : Align
	align_bottom_center = { horizontal: Center, vertical: Bottom }

	## Anchor `pos` at the bottom-right corner of the text.
	align_bottom_right : Align
	align_bottom_right = { horizontal: Right, vertical: Bottom }

	## How far the anchor named by an `Align` sits from the text's top-left
	## corner, for a text of this size. `origin_for` is what a draw uses; this
	## is the piece it is built from.
	align_offset : Size, Align -> Math.Vec2
	align_offset = |size, align| {
		x = match align.horizontal {
			Left => 0
			Center => size.width * 0.5
			Right => size.width
		}

		y = match align.vertical {
			Top => 0
			Middle => size.height * 0.5
			Bottom => size.height
		}

		{ x, y }
	}

	## The top-left corner a text of this size must be drawn at for its `align`
	## anchor to land on `pos`. Pure, so an app can compute the same box a draw
	## will occupy without drawing anything.
	origin_for : Math.Vec2, Size, Align -> Math.Vec2
	origin_for = |pos, size, align| {
		offset = Text.align_offset(size, align)
		{ x: pos.x - offset.x, y: pos.y - offset.y }
	}

	## Draw prepared text, as `Prepared.draw!` does.
	##
	## Legal in `render!` only.
	##
	## Prefer the receiver. This form takes the frame first, like every other
	## free drawing function, and takes the text as a field of its config
	## record rather than as its own argument.
	draw_prepared! : Draw.Frame, { text : Prepared, pos : Math.Vec2, color : Color.Rgba, align : Align } => {}
	draw_prepared! = |_frame, cfg| {
		Prepared.(prepared) = cfg.text
		pos = Text.origin_for(cfg.pos, prepared.measured, cfg.align)
		DrawHost.draw_prepared_text!({ prepared: prepared.resource, pos, color: cfg.color })
	}
}

expect Text.align_offset({ width: 100, height: 40 }, Text.align_center) == { x: 50, y: 20 }

## Prepared text keeps the size the host measured while preparing it, and the
## stub has no measurement to keep. Zeroed bounds are the honest answer: they
## say the value was never measured rather than inventing a size for it.
expect Text.Prepared.stub.bounds() == { width: 0, height: 0 }

## With no bounds, every alignment resolves to the placement point itself, which
## is what makes drawing a stub harmless in a layout that does happen to run.
expect Text.origin_for({ x: 40, y: 12 }, Text.Prepared.stub.bounds(), Text.align_center) == { x: 40, y: 12 }
expect Text.origin_for({ x: 40, y: 12 }, Text.Prepared.stub.bounds(), Text.align_bottom_right) == { x: 40, y: 12 }
