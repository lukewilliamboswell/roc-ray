## Font handles, metric snapshots, and pure text measurement.
##
## A font pairs an opaque, reference-counted native resource identity with an
## immutable scalar metric snapshot. Reusable packages can retain and measure
## it without importing the platform or calling the host. The platform
## re-exports this type as `Text.Font`.
import unicode.Scalar

Font := {
	handle : Handle,
	metrics : FontMetrics,
}.{

	## Opaque native resource identity. Only a host can manufacture a live one,
	## but applications can compare and hash handles they receive.
	Handle :: Box(U64).{
		is_eq : Handle, Handle -> Bool
		is_eq = |Handle.(a), Handle.(b)| Box.unbox(a) == Box.unbox(b)

		to_hash : Handle, Hasher -> Hasher
		to_hash = |Handle.(value), hasher| U64.to_hash(Box.unbox(value), hasher)
	}

	## Scalar metrics for one glyph, in the atlas's own units.
	GlyphMetrics : {
		codepoint : U32,
		advance_x : F32,
		offset_x : F32,
		offset_y : F32,
		width : F32,
		height : F32,
	}

	## Immutable atlas and glyph metrics captured when a font is loaded.
	FontMetrics : {
		base_size : F32,
		line_spacing : F32,
		fallback_index : U64,
		glyphs : List(GlyphMetrics),
	}

	## What to measure: text, draw size, and extra spacing between codepoints.
	Measure : {
		text : Str,
		size : F32,
		spacing : F32,
	}

	## Text measurement result, in the units the requested size was given in.
	Size : {
		width : F32,
		height : F32,
	}

	## Resource-free synthetic monospace font for pure layout tests.
	##
	## Its handle never resolves to a host resource, so drawing falls back to
	## the platform's built-in font. One fallback glyph advances one unit at a
	## base size of one, making measurements deterministic. Do not use it to
	## test drawing, loading, resource lifetime, or rasterized-font parity.
	stub : Font
	stub = {
		handle: Handle.(Box.box(U64.highest)),
		metrics: {
			base_size: 1,
			line_spacing: 0,
			fallback_index: 0,
			glyphs: [{ codepoint: 0, advance_x: 1, offset_x: 0, offset_y: 0, width: 1, height: 1 }],
		},
	}

	## Measure a valid Roc string against the font's immutable metric snapshot.
	##
	## Pure: this never calls the host, so layout can run in `update!`, in a
	## package, or in an `expect`. Newlines advance by the requested size plus
	## line spacing, missing codepoints use the fallback glyph, and spacing
	## counts Unicode codepoints. U+0000 is an ordinary Roc string codepoint.
	measure : Font, Measure -> Size
	measure = |font, { text, size, spacing }| {
		if Str.is_empty(text) {
			{ width: 0, height: 0 }
		} else {
			var $state = {
				# Codepoint count on the current line.
				line_count: 0,
				# Unscaled glyph-advance total for the current line.
				line_width: 0,
				# Greatest codepoint count among completed lines.
				widest_count: 0,
				# Greatest unscaled width among completed lines.
				widest_width: 0,
				# Accumulated height across all lines.
				height: size,
			}
			$state = text_codepoints(text).fold(
				$state,
				|current, codepoint| {
					if codepoint == 10 {
						# Line Feed ("\n"):
						# - Width preserves the widest completed line.
						# - Height increases by font size plus line spacing.
						{
							line_width: 0,
							widest_width: max_f32(current.widest_width, current.line_width),
							line_count: 0,
							widest_count: max_u64(current.widest_count, current.line_count),
							height: current.height + size + font.metrics.line_spacing,
						}
					} else {
						# Other codepoints:
						# - width: accumulates glyph advance (use the fallback for a missing glyph).
						# - height: unchanged.
						glyph_result = match binary_search_by(font.metrics.glyphs, codepoint, |glyph| glyph.codepoint) {
							Ok(found) => Ok(found)
							Err(NotFound) => List.get(font.metrics.glyphs, font.metrics.fallback_index)
						}
						advance_x = match glyph_result {
							Ok(glyph) => if glyph.advance_x > 0 glyph.advance_x else glyph.width + glyph.offset_x
							Err(_) => 0
						}
						{ ..current, line_width: current.line_width + advance_x, line_count: current.line_count + 1 }
					}
				},
			)
			# Finalize width/height:
			# - width: scale the widest line and add spacing from the greatest line count.
			# - height: use the accumulated line height.
			width = max_f32($state.widest_width, $state.line_width)
			count = max_u64($state.widest_count, $state.line_count)
			spacing_width = if count > 0 (U64.to_f32(count) - 1) * spacing else 0
			{
				width: width * (size / font.metrics.base_size) + spacing_width,
				height: $state.height,
			}
		}
	}
}

## Iterate over the Unicode codepoints in a valid Roc string.
text_codepoints : Str -> Iter(U32)
text_codepoints = |text| Scalar.iter(text).map(|located| located.scalar.to_u32())

## Iterate over bytes as codepoints when the text is known to be ASCII.
text_codepoints_ascii : Str -> Iter(U32)
text_codepoints_ascii = |text| Str.to_utf8(text).iter().map(|byte| byte.to_u32())

binary_search_by : List(a), key, (a -> key) -> Try(a, [NotFound]) where [key.is_eq : key, key -> Bool, key.is_lt : key, key -> Bool]
binary_search_by = |items, needle, key_of| binary_search_range(items, needle, key_of, 0, List.len(items))

binary_search_range : List(a), key, (a -> key), U64, U64 -> Try(a, [NotFound]) where [key.is_eq : key, key -> Bool, key.is_lt : key, key -> Bool]
binary_search_range = |items, needle, key_of, low, high| {
	if low >= high {
		Err(NotFound)
	} else {
		middle = low + (high - low) / 2
		match List.get(items, middle) {
			Err(_) => Err(NotFound)
			Ok(item) => {
				key = key_of(item)
				if key.is_eq(needle) {
					Ok(item)
				} else if key.is_lt(needle) {
					binary_search_range(items, needle, key_of, middle + 1, high)
				} else {
					binary_search_range(items, needle, key_of, low, middle)
				}
			}
		}
	}
}

max_f32 : F32, F32 -> F32
max_f32 = |a, b| if a > b a else b

max_u64 : U64, U64 -> U64
max_u64 = |a, b| if a > b a else b

iterator_done : Iter(a) -> Bool
iterator_done = |iter| match Iter.next(iter) {
	Done => Bool.True
	_ => Bool.False
}

test_font : Font
test_font = {
	handle: Font.stub.handle,
	metrics: {
		base_size: 10,
		line_spacing: 3,
		fallback_index: 0,
		glyphs: [
			{ codepoint: 0, advance_x: 5, offset_x: 0, offset_y: 0, width: 5, height: 10 }, # "\u(0000)"
			{ codepoint: 97, advance_x: 10, offset_x: 0, offset_y: 0, width: 10, height: 10 }, # "a"
			{ codepoint: 98, advance_x: 4, offset_x: 0, offset_y: 0, width: 4, height: 10 }, # "b"
			{ codepoint: 99, advance_x: 4, offset_x: 0, offset_y: 0, width: 4, height: 10 }, # "c"
			{ codepoint: 122, advance_x: 0, offset_x: 2, offset_y: 0, width: 6, height: 10 }, # "z"
		],
	},
}

# Font.measure

# Empty text has no bounds, regardless of requested size or spacing.
expect Font.stub.measure({ text: "", size: 20, spacing: 1 }) == { width: 0, height: 0 }

# The synthetic fallback advances once per codepoint and spaces adjacent codepoints.
expect Font.stub.measure({ text: "abc", size: 20, spacing: 1 }) == { width: 62, height: 20 }

# A newline starts another font-sized line without contributing horizontal advance.
expect Font.stub.measure({ text: "a\nb", size: 20, spacing: 0 }) == { width: 20, height: 40 }

# Raylib combines the greatest glyph width and greatest codepoint count across lines.
expect test_font.measure({ text: "a\nbc", size: 10, spacing: 3 }) == { width: 13, height: 23 }

# A present glyph is selected by codepoint while an absent glyph uses the fallback.
expect test_font.measure({ text: "a?", size: 10, spacing: 0 }) == { width: 15, height: 10 }

# A zero glyph advance falls back to glyph width plus horizontal offset.
expect test_font.measure({ text: "z", size: 10, spacing: 0 }) == { width: 8, height: 10 }

# Glyph advances scale from the font's base size before spacing is added.
expect test_font.measure({ text: "ab", size: 20, spacing: 3 }) == { width: 31, height: 20 }

# A leading newline includes an empty first line and configured line spacing.
expect test_font.measure({ text: "\na", size: 10, spacing: 0 }) == { width: 10, height: 23 }

# A trailing newline includes an empty final line and configured line spacing.
expect test_font.measure({ text: "a\n", size: 10, spacing: 0 }) == { width: 10, height: 23 }

# Consecutive newlines include every intervening empty line.
expect test_font.measure({ text: "a\n\nb", size: 10, spacing: 0 }) == { width: 10, height: 36 }

# A multibyte Unicode scalar is measured as one missing codepoint, not UTF-8 bytes.
expect test_font.measure({ text: "é", size: 10, spacing: 2 }) == { width: 5, height: 10 }

# text_codepoints

# A multibyte UTF-8 sequence produces one Unicode codepoint.
expect match Iter.next(text_codepoints("é")) {
	One({ item, rest }) => item == 233 and iterator_done(rest)
	_ => Bool.False
}

# U+0000 is an ordinary Roc string codepoint rather than a terminator.
expect match Iter.next(text_codepoints("a\u(0000)b")) {
	One({ item, rest }) =>
		item == 97 and match Iter.next(rest) {
			One({ item: nul, rest: after_nul }) => nul == 0 and match Iter.next(after_nul) {
				One({ item: final, rest: done }) => final == 98 and iterator_done(done)
				_ => Bool.False
			}
			_ => Bool.False
		}
	_ => Bool.False
}

# text_codepoints_ascii

# Known ASCII text can be iterated directly from its UTF-8 bytes.
expect match Iter.next(text_codepoints_ascii("A\n")) {
	One({ item, rest }) =>
		item == 65 and match Iter.next(rest) {
			One({ item: newline, rest: done }) => newline == 10 and iterator_done(done)
			_ => Bool.False
		}
	_ => Bool.False
}

# binary_search_by

# A sorted collection returns the element whose extracted key matches.
expect binary_search_by([{ key: 1 }, { key: 3 }, { key: 5 }], 3, |item| item.key) == Ok({ key: 3 })

# A key absent from a sorted collection reports NotFound.
expect binary_search_by([{ key: 1 }, { key: 3 }, { key: 5 }], 4, |item| item.key) == Err(NotFound)

# Font.Handle

# Handle equality and hashing support keyed collections.
expect Dict.single(Font.stub.handle, 42).get(Font.stub.handle) == Ok(42)
