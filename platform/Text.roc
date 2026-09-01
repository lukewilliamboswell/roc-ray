## Align and draw immediate text, or prepare it once to draw repeatedly without
## per-frame allocation.
##
## ```roc
## title = Text.from("Hello", font).size(38).prepare!()?
## ```
##
## ```roc
## Text.from("Score", font).size(24).draw!(frame, { pos, color: Color.white, align: (Top, Right) })
## ```
##
## ```roc
## model.title.draw!(frame, { pos: { x: 400, y: 60 }, color: Color.white, align: (Top, Center) })
## ```
##
## `Prepared.bounds` returns the measured size. `Placement.align` selects which
## point of those bounds its `pos` identifies.
##
## Preparation is legal in `init!`, `update!`, and tasks, and refused in
## `render!`. Drawing requires `Draw.Frame` and is legal only in `render!`.
## Retain repeatedly drawn `Prepared` values in the model.
import Color
import Draw
import Host
import Math
import rrt.Font as RrtFont

Text := [].{

	## A host-owned font and immutable metric snapshot. This is the shared type
	## from `roc-ray-types`, re-exported for applications that depend only on the
	## platform.
	Font : RrtFont.Font

	## Which horizontal edge or centre of the text `pos` names.
	HAlign : [Left, Center, Right]

	## Which vertical edge or centre of the text `pos` names.
	VAlign : [Top, Middle, Bottom]

	## Where `pos` sits within the text, as `(vertical, horizontal)`.
	Align : (VAlign, HAlign)

	## A measured width and height, in the same logical units as every drawing
	## call. This is `Draw.TextSize` and the types package's `Font.Size` under a
	## third name; they are one type.
	Size : RrtFont.Size

	## Resource-free synthetic monospace font for pure layout tests.
	font_stub : Font
	font_stub = RrtFont.stub

	## Everything a draw needs beyond the text itself: where to put it, what
	## colour to paint it, and which point of it `pos` names.
	Placement : {
		pos : Math.Vec2,
		color : Color.Rgba,
		align : Align ?? (Top, Left),
	}

	## A string and its drawing style. Start one with `Text.from`, adjust it with
	## the receivers below, then draw it immediately or finish it with
	## `prepare!` for repeated drawing.
	##
	## A builder is a plain description, so building and measuring one costs
	## nothing and it can be assembled anywhere. `draw!` and `prepare!` are the
	## operations that reach the host.
	Builder :: {
		content : Str,
		size : F32,
		spacing : F32,
		font : RrtFont.Font,
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
		font : Builder, RrtFont.Font -> Builder
		font = |builder, value| { ..builder, font: value }

		## Measure this description from the font's immutable metric snapshot,
		## resolve `placement.align`, and draw it immediately.
		##
		## Legal in `render!` only. This is an alignment convenience for text
		## that does not need a retained `Prepared` resource; `Draw.text!` is the
		## lower-level operation for callers that already resolved the origin.
		draw! : Builder, Draw.Frame, Placement => {}
		draw! = |builder, frame, placement| {
			measured = builder.font.measure({ text: builder.content, size: builder.size, spacing: builder.spacing })
			pos = Text.origin_for(placement.pos, measured, placement.align)
			Draw.text!(
				frame,
				{
					pos,
					text: builder.content,
					size: builder.size,
					spacing: builder.spacing,
					color: placement.color,
					font: builder.font,
				},
			)
		}

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
		resource : Host.TextPrepared,
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
				resource: Box.box(U64.highest),
				measured: { width: 0, height: 0 },
			},
		)
	}

	## The letter spacing a `Builder` starts with, and what raylib's own text
	## drawing uses.
	default_spacing : F32
	default_spacing = Draw.default_spacing

	## Start describing a string drawn in a font. Adjust the result with
	## `size`, `spacing` and `font`, then draw or prepare it.
	from : Str, RrtFont.Font -> Builder
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
		result = Host.text_prepare!({
			text: builder.content,
			size: builder.size,
			spacing: builder.spacing,
			font: builder.font.handle,
		})
		match result {
			# closed error union to open error union
			Ok(prepared_result) => Ok(
				Prepared.(
					{
						resource: prepared_result.prepared,
						measured: { width: prepared_result.width, height: prepared_result.height },
					},
				),
			)
			Err(ResourceLimit) => Err(ResourceLimit)
			Err(InvalidResource) => crash "prepared text host invariant failed"
		}
	}

	## How far the anchor named by an `Align` sits from the text's top-left
	## corner, for a text of this size. `origin_for` is what a draw uses; this
	## is the piece it is built from.
	align_offset : Size, Align -> Math.Vec2
	align_offset = |size, align| {
		vertical = align.0
		horizontal = align.1

		x = match horizontal {
			Left => 0
			Center => size.width * 0.5
			Right => size.width
		}

		y = match vertical {
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
	draw_prepared! : Draw.Frame, { text : Prepared, pos : Math.Vec2, color : Color.Rgba, align : Align ?? (Top, Left) } => {}
	draw_prepared! = |_frame, cfg| {
		Prepared.(prepared) = cfg.text
		pos = Text.origin_for(cfg.pos, prepared.measured, cfg.align)
		Host.draw_draw_prepared_text!({ prepared: prepared.resource, pos, color: cfg.color })
	}
}

expect Text.align_offset({ width: 100, height: 40 }, (Middle, Center)) == { x: 50, y: 20 }

default_placement : Text.Placement
default_placement = { pos: { x: 0, y: 0 }, color: Color.white }

expect default_placement.align == (Top, Left)

## Prepared text keeps the size the host measured while preparing it, and the
## stub has no measurement to keep. Zeroed bounds are the honest answer: they
## say the value was never measured rather than inventing a size for it.
expect Text.Prepared.stub.bounds() == { width: 0, height: 0 }

## With no bounds, every alignment resolves to the placement point itself, which
## is what makes drawing a stub harmless in a layout that does happen to run.
expect Text.origin_for({ x: 40, y: 12 }, Text.Prepared.stub.bounds(), (Middle, Center)) == { x: 40, y: 12 }
expect Text.origin_for({ x: 40, y: 12 }, Text.Prepared.stub.bounds(), (Bottom, Right)) == { x: 40, y: 12 }
