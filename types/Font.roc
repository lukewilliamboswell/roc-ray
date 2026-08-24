## Font handles, metric snapshots, and pure text measurement.
##
## `measure` follows the host renderer's layout rules without calling the host,
## so packages and tests can calculate text bounds purely.
##
## `Font` pairs an opaque host handle with immutable scalar and glyph metrics.
## Only the platform can load a live font; it re-exports this type as
## `Draw.Font`.
import unicode.Scalar

Font := {
	handle : Handle,
	base_size_value : F32,
	line_spacing_value : F32,
	fallback_index : U64,
	glyph_values : List(GlyphMetrics),
}.{

	## The native resource a loaded font holds.
	##
	## Opaque: only the host mints one, so a font value can be copied and
	## measured but a handle cannot be forged from an integer.
	Resource :: Box(U64).{

		## The invalid token, as a resource-free handle. See `Font.stub`.
		stub : Resource
		stub = Resource.(Box.box(0))
	}

	## Which font a value names: raylib's built-in one, or a loaded resource.
	Handle : [DefaultFont, LoadedFont(Resource)]

	## Scalar metrics for one glyph, in the atlas's own units.
	GlyphMetrics : {
		codepoint : U32,
		advance_x : F32,
		offset_x : F32,
		offset_y : F32,
		width : F32,
		height : F32,
	}

	## What to measure: the string, the size to draw it at, and the extra space
	## between scalars.
	Measure : {
		text : Str,
		size : F32,
		spacing : F32,
	}

	## Text measurement result, in the units the size was given in.
	Size : {
		width : F32,
		height : F32,
	}

	## The pixel size this font's glyph atlas was rasterized at.
	##
	## Drawing at this size is one atlas texel per screen pixel. Drawing much
	## larger scales the atlas up rather than re-rasterizing, so load the
	## font again at the size wanted instead.
	base_size : Font -> F32
	base_size = |font| font.base_size_value

	## Extra vertical space between lines, on top of the drawn size. Adding
	## it to the text size is the distance from one baseline to the next.
	line_spacing : Font -> F32
	line_spacing = |font| font.line_spacing_value

	## Every glyph the font rasterized, with its advance and its box. This is
	## the table `measure` walks; an app rarely needs it directly.
	glyphs : Font -> List(GlyphMetrics)
	glyphs = |font| font.glyph_values

	## Where a codepoint sits in `glyphs`, or the fallback glyph's index when
	## the font has no glyph for it. Answers an index rather than a `Try`, so
	## measurement stays total.
	get_glyph_index : Font, U32 -> U64
	get_glyph_index = |font, codepoint|
		glyph_index(font.glyph_values, codepoint, 0, List.len(font.glyph_values), font.fallback_index)

	## Measure a valid Roc string against this font's metric snapshot.
	##
	## Pure: it reads the snapshot taken when the font loaded and never calls
	## the host, so a layout pass can run in `update!`, in a helper, or in an
	## `expect`. The platform's `Text` is the fuller interface built on it.
	##
	## This follows raylib 6 `MeasureTextEx`: embedded NUL ends the input,
	## newline advances by font size plus line spacing, missing codepoints use
	## the fallback glyph, and spacing counts Unicode scalars.
	measure : Font, Measure -> Size
	measure = |font, cfg| {
		state = {
			line_width: 0,
			widest_width: 0,
			line_count: 0,
			widest_count: 0,
			height: cfg.size,
			seen: Bool.False,
		}
		# TODO(compiler): the fold takes the scalar metrics rather than the
		# `Font` itself. Passing the whole value into the recursion, while also
		# reading its glyph list, makes the compiler's ARC certification panic
		# with "consumed partially dismantled local" on the refcounted handle
		# field. The metrics are all the fold reads anyway; restore the direct
		# `Font` argument once that is fixed.
		metrics = {
			base_size: font.base_size_value,
			line_spacing: font.line_spacing_value,
			fallback_index: font.fallback_index,
		}
		measure_scalars(metrics, cfg, font.glyph_values, Scalar.iter(cfg.text), state)
	}

	## Resource-free font value for pure tests.
	##
	## The handle never resolves to a host resource, so every host path it
	## reaches treats it as an invalid one: drawing falls back to raylib's
	## built-in font, and the platform's `Text.prepare!` refuses it. Its metric
	## snapshot is a fiction rather than a measurement -- no glyphs, no line
	## spacing, and a `base_size` of 1 so that `measure` stays finite instead of
	## dividing by zero. Put it in a model to reach the app's real `update!`
	## from an `expect`. Do not use it to test drawing, layout, or resource
	## lifetime.
	stub : Font
	stub = {
		handle: LoadedFont(Resource.stub),
		base_size_value: 1,
		line_spacing_value: 0,
		fallback_index: 0,
		glyph_values: [],
	}
}

## The scalar metrics `measure` reads, without the handle beside them.
Metrics : {
	base_size : F32,
	line_spacing : F32,
	fallback_index : U64,
}

## The running line, the widest line seen, and the height accumulated so far.
MeasureState : {
	line_width : F32,
	widest_width : F32,
	line_count : U64,
	widest_count : U64,
	height : F32,
	seen : Bool,
}

## One step of `measure`, folding the next Unicode scalar into the running
## line and answering the finished `Size` when the string runs out.
measure_scalars : Metrics, Font.Measure, List(Font.GlyphMetrics), Iter(Scalar.LocatedScalar), MeasureState -> Font.Size
measure_scalars = |metrics, cfg, glyphs, scalars, state| {
	match Iter.next(scalars) {
		Done => finish(metrics, cfg, state)
		Skip({ rest }) => measure_scalars(metrics, cfg, glyphs, rest, state)
		One({ item, rest }) => {
			codepoint = item.scalar.to_u32()
			if codepoint == 0 {
				finish(metrics, cfg, state)
			} else if codepoint == 10 {
				measure_scalars(
					metrics,
					cfg,
					glyphs,
					rest,
					{
						line_width: 0,
						widest_width: max_f32(state.widest_width, state.line_width),
						line_count: 0,
						widest_count: max_u64(state.widest_count, state.line_count),
						height: state.height + cfg.size + metrics.line_spacing,
						seen: Bool.True,
					},
				)
			} else {
				index = glyph_index(glyphs, codepoint, 0, List.len(glyphs), metrics.fallback_index)
				advance = match List.get(glyphs, index) {
					Ok(glyph) => if glyph.advance_x > 0 glyph.advance_x else glyph.width + glyph.offset_x
					Err(_) => 0
				}
				measure_scalars(
					metrics,
					cfg,
					glyphs,
					rest,
					{ ..state, line_width: state.line_width + advance, line_count: state.line_count + 1, seen: Bool.True },
				)
			}
		}
	}
}

## Turn `measure`'s accumulated state into the `Size` it answers with, once
## every scalar has been folded in.
finish : Metrics, Font.Measure, MeasureState -> Font.Size
finish = |metrics, cfg, state| {
	if !state.seen {
		{ width: 0, height: 0 }
	} else {
		width = max_f32(state.widest_width, state.line_width)
		count = max_u64(state.widest_count, state.line_count)
		spacing_width = if count > 0 (U64.to_f32(count) - 1) * cfg.spacing else 0
		{
			width: width * (cfg.size / metrics.base_size) + spacing_width,
			height: state.height,
		}
	}
}

## The larger of two `F32` values, used to keep the widest line seen so far.
max_f32 : F32, F32 -> F32
max_f32 = |a, b| if a > b a else b

## The larger of two `U64` values, used to keep the longest line seen so far.
max_u64 : U64, U64 -> U64
max_u64 = |a, b| if a > b a else b

## Binary search the glyph table, which the host builds sorted by codepoint.
##
## Answers the fallback index rather than a `Try` for a codepoint the font has
## no glyph for, which is what keeps `measure` total.
glyph_index : List(Font.GlyphMetrics), U32, U64, U64, U64 -> U64
glyph_index = |glyphs, codepoint, start, end, fallback| {
	if start >= end {
		fallback
	} else {
		middle = start + (end - start) / 2
		match List.get(glyphs, middle) {
			Err(_) => fallback
			Ok(glyph) => if glyph.codepoint == codepoint {
				middle
			} else if codepoint < glyph.codepoint {
				glyph_index(glyphs, codepoint, start, middle, fallback)
			} else {
				glyph_index(glyphs, codepoint, middle + 1, end, fallback)
			}
		}
	}
}

## A synthetic font, which is what a layout package's own tests are written
## against: real-looking metrics, no host, and a handle that resolves to
## nothing.
sample : Font
sample = {
	handle: DefaultFont,
	base_size_value: 10,
	line_spacing_value: 2,
	fallback_index: 0,
	glyph_values: [
		{ codepoint: 32, advance_x: 4, offset_x: 0, offset_y: 0, width: 0, height: 0 },
		{ codepoint: 97, advance_x: 6, offset_x: 0, offset_y: 0, width: 5, height: 7 },
		{ codepoint: 98, advance_x: 8, offset_x: 0, offset_y: 0, width: 7, height: 7 },
	],
}

expect Font.base_size(Font.stub) == 1
expect Font.line_spacing(Font.stub) == 0
expect List.is_empty(Font.glyphs(Font.stub))

## A font with no glyphs measures every string as zero-wide. The height is the
## requested size because that is one line of it, and the `base_size` of 1 is
## what keeps the scale factor finite rather than dividing by zero.
expect Font.measure(Font.stub, { text: "", size: 20, spacing: 1 }) == { width: 0, height: 0 }
expect Font.measure(Font.stub, { text: "inert", size: 20, spacing: 0 }) == { width: 0, height: 20 }

## The glyph table is searched by codepoint, and a codepoint the font does not
## have measures as the fallback glyph rather than as an error.
expect Font.get_glyph_index(sample, 97) == 1
expect Font.get_glyph_index(sample, 98) == 2
expect Font.get_glyph_index(sample, 9731) == 0

## Drawn at the atlas's own base size, a string is exactly the sum of its
## advances plus one gap per pair of scalars.
expect Font.measure(sample, { text: "ab", size: 10, spacing: 0 }) == { width: 14, height: 10 }
expect Font.measure(sample, { text: "ab", size: 10, spacing: 3 }) == { width: 17, height: 10 }

## Drawn at twice the base size, the advances scale but the spacing does not.
expect Font.measure(sample, { text: "ab", size: 20, spacing: 0 }) == { width: 28, height: 20 }

## A newline starts a second line: the width is the widest of the two, and the
## height is two sizes plus one line spacing.
expect Font.measure(sample, { text: "a\nab", size: 10, spacing: 0 }) == { width: 14, height: 22 }
