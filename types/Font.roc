## Pure font metrics and raylib-compatible text measurement.
##
## A platform font can satisfy `font.Measurable` while retaining its native
## resource privately. Reusable packages need only this module and never call
## the host while laying out text.
import unicode.Scalar

font.Measurable :
	where [
		font.base_size : font -> F32,
		font.line_spacing : font -> F32,
		font.glyphs : font -> List({ codepoint : U32, advance_x : F32, offset_x : F32, offset_y : F32, width : F32, height : F32 }),
		font.get_glyph_index : font, U32 -> U64,
	]

MeasureState : {
	line_width : F32,
	widest_width : F32,
	line_count : U64,
	widest_count : U64,
	height : F32,
	seen : Bool,
}

Font := [].{

	GlyphMetrics : {
		codepoint : U32,
		advance_x : F32,
		offset_x : F32,
		offset_y : F32,
		width : F32,
		height : F32,
	}

	Measure : {
		text : Str,
		size : F32,
		spacing : F32,
	}

	Size : {
		width : F32,
		height : F32,
	}

	## Measure a valid Roc string using a scalar font snapshot.
	##
	## This follows raylib 6 `MeasureTextEx`: embedded NUL ends the input,
	## newline advances by font size plus line spacing, missing codepoints use
	## the fallback glyph, and spacing counts Unicode scalars.
	measure : font, Measure -> Size where [font.Measurable]
	measure = |font, cfg| {
		state = {
			line_width: 0,
			widest_width: 0,
			line_count: 0,
			widest_count: 0,
			height: cfg.size,
			seen: Bool.False,
		}
		Font.measure_scalars(font, cfg, font.glyphs(), Scalar.iter(cfg.text), state)
	}

	measure_scalars : font, Measure, List(GlyphMetrics), Iter(Scalar.LocatedScalar), MeasureState -> Size where [font.Measurable]
	measure_scalars = |font, cfg, glyphs, scalars, state| {
		match Iter.next(scalars) {
			Done => Font.finish(font, cfg, state)
			Skip({ rest }) => Font.measure_scalars(font, cfg, glyphs, rest, state)
			One({ item, rest }) => {
				codepoint = item.scalar.to_u32()
				if codepoint == 0 {
					Font.finish(font, cfg, state)
				} else if codepoint == 10 {
					Font.measure_scalars(
						font,
						cfg,
						glyphs,
						rest,
						{
							line_width: 0,
							widest_width: Font.max_f32(state.widest_width, state.line_width),
							line_count: 0,
							widest_count: Font.max_u64(state.widest_count, state.line_count),
							height: state.height + cfg.size + font.line_spacing(),
							seen: Bool.True,
						},
					)
				} else {
					index = font.get_glyph_index(codepoint)
					advance = match List.get(glyphs, index) {
						Ok(glyph) => if glyph.advance_x > 0 glyph.advance_x else glyph.width + glyph.offset_x
						Err(_) => 0
					}
					Font.measure_scalars(
						font,
						cfg,
						glyphs,
						rest,
						{ ..state, line_width: state.line_width + advance, line_count: state.line_count + 1, seen: Bool.True },
					)
				}
			}
		}
	}

	finish : font, Measure, MeasureState -> Size where [font.Measurable]
	finish = |font, cfg, state| {
		if !state.seen {
			{ width: 0, height: 0 }
		} else {
			width = Font.max_f32(state.widest_width, state.line_width)
			count = Font.max_u64(state.widest_count, state.line_count)
			spacing_width = if count > 0 (U64.to_f32(count) - 1) * cfg.spacing else 0
			{
				width: width * (cfg.size / font.base_size()) + spacing_width,
				height: state.height,
			}
		}
	}

	max_f32 : F32, F32 -> F32
	max_f32 = |a, b| if a > b a else b

	max_u64 : U64, U64 -> U64
	max_u64 = |a, b| if a > b a else b
}
