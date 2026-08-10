## Text module - fonts, text measurement, and prepared text drawing.
##
## `Metrics` enables pure layout measurement. Prepare text when rendering needs
## host-owned cached bytes and bounds.
import Color
import Draw
import DrawHost
import Math

Text := [].{

	## Draw owns the host resource lifecycle; prepared text retains loaded fonts
	## through the same ARC value as all other drawing APIs.
	Font : Draw.Font

	HAlign : [Left, Center, Right]

	VAlign : [Top, Middle, Bottom]

	Align : {
		horizontal : HAlign,
		vertical : VAlign,
	}

	Size : {
		width : F32,
		height : F32,
	}

	## The input to a pure metric measurement.
	Measure : {
		text : Str,
		size : F32,
		spacing : F32,
	}

	## A scalar snapshot of a font's measurement data.
	##
	## It owns no host resource, so it remains usable after its source `Font` is
	## dropped. Glyphs are sorted by codepoint for binary lookup; `fallback_advance`
	## is raylib's `?` glyph (or its first glyph when `?` is unavailable).
	Metrics :: {
		base_size : F32,
		line_spacing : F32,
		fallback_advance : F32,
		glyphs : List({ codepoint : U32, advance : F32 }),
	}.{

		## Measure UTF-8 text without a host call.
		##
		## An embedded NUL ends the input. Newlines and spacing follow raylib.
		## TODO: use a borrowed Str iterator when the compiler exposes one; current
		## `Str.to_utf8` aliases heap strings but copies short inline strings.
		measure : Metrics, Measure -> Size
		measure = |metrics, cfg| Text.measure_metrics(metrics, cfg)
	}

	Placement : {
		pos : Math.Vec2,
		color : Color.Rgba,
		align : Align,
	}

	Builder :: {
		content : Str,
		size : F32,
		spacing : F32,
		font : Font,
	}.{
		size : Builder, F32 -> Builder
		size = |builder, value| { ..builder, size: value }

		spacing : Builder, F32 -> Builder
		spacing = |builder, value| { ..builder, spacing: value }

		font : Builder, Font -> Builder
		font = |builder, value| { ..builder, font: value }

		## Cache immutable UTF-8 text, font/style, and measurement in the host.
		prepare! : Builder => Try(Prepared, [ResourceLimit, ..])
		prepare! = |builder| Text.prepare_builder!(builder)
	}

	## Host-owned immutable text. Its ARC handle retains any loaded font and its
	## cached native NUL-terminated bytes are reused by every draw.
	Prepared :: {
		resource : DrawHost.PreparedText,
		measured : Size,
	}.{
		bounds : Prepared -> Size
		bounds = |Prepared.(prepared)| prepared.measured

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
	}

	default_font : Font
	default_font = Draw.default_font

	default_spacing : F32
	default_spacing = Draw.default_spacing

	from : Str -> Builder
	from = |content| {
		content,
		size: 20,
		spacing: Text.default_spacing,
		font: Text.default_font,
	}

	## Snapshot a font's immutable scalar metrics during startup.
	##
	## Preparation allocates one ordinary Roc list with one 8-byte record per
	## glyph and sorts it once. The result retains no font handle or GPU data.
	metrics! : Font => Metrics
	metrics! = |font| {
		raw = DrawHost.font_metrics!(font)
		Metrics.(
			{
				base_size: raw.base_size,
				line_spacing: raw.line_spacing,
				fallback_advance: raw.fallback_advance,
				glyphs: raw.glyphs,
			},
		)
	}

	measure_metrics : Metrics, Measure -> Size
	measure_metrics = |metrics, cfg| {
		bytes = Str.to_utf8(cfg.text)
		if List.len(bytes) == 0 {
			{ width: 0, height: 0 }
		} else {
			Text.measure_utf8(metrics, cfg, bytes, 0, 0, 0, 0, 0, cfg.size)
		}
	}

	## `index` is always at a UTF-8 codepoint boundary in `bytes`.
	measure_utf8 : Metrics, Measure, List(U8), U64, F32, F32, U64, U64, F32 -> Size
	measure_utf8 = |metrics, cfg, bytes, index, line_width, widest_width, line_codepoints, widest_codepoints, height| {
		if index >= List.len(bytes) {
			Text.finish_measurement(metrics, cfg, line_width, widest_width, line_codepoints, widest_codepoints, height)
		} else {
			decoded = Text.decode_utf8(bytes, index)
			if decoded.codepoint == 0 {
				Text.finish_measurement(metrics, cfg, line_width, widest_width, line_codepoints, widest_codepoints, height)
			} else if decoded.codepoint == 10 {
				Text.measure_utf8(
					metrics,
					cfg,
					bytes,
					decoded.next,
					0,
					Text.max_width(line_width, widest_width),
					0,
					Text.max_count(line_codepoints, widest_codepoints),
					height + cfg.size + metrics.line_spacing,
				)
			} else {
				Text.measure_utf8(
					metrics,
					cfg,
					bytes,
					decoded.next,
					line_width + Text.glyph_advance(metrics.glyphs, metrics.fallback_advance, decoded.codepoint, 0, List.len(metrics.glyphs)),
					widest_width,
					line_codepoints + 1,
					widest_codepoints,
					height,
				)
			}
		}
	}

	finish_measurement : Metrics, Measure, F32, F32, U64, U64, F32 -> Size
	finish_measurement = |metrics, cfg, line_width, widest_width, line_codepoints, widest_codepoints, height| {
		width = Text.max_width(line_width, widest_width)
		count = Text.max_count(line_codepoints, widest_codepoints)
		{
			width: width * (cfg.size / metrics.base_size) + (U64.to_f32(count) - 1) * cfg.spacing,
			height,
		}
	}

	max_width : F32, F32 -> F32
	max_width = |first, second| if first > second first else second

	max_count : U64, U64 -> U64
	max_count = |first, second| if first > second first else second

	glyph_advance : List({ codepoint : U32, advance : F32 }), F32, U32, U64, U64 -> F32
	glyph_advance = |glyphs, fallback, codepoint, start, end| {
		if start >= end {
			fallback
		} else {
			middle = start + (end - start) / 2
			match List.get(glyphs, middle) {
				Ok(glyph) =>
					if glyph.codepoint == codepoint {
						glyph.advance
					} else if codepoint < glyph.codepoint {
						Text.glyph_advance(glyphs, fallback, codepoint, start, middle)
					} else {
						Text.glyph_advance(glyphs, fallback, codepoint, middle + 1, end)
					}
				Err(_) => fallback
			}
		}
	}

	decode_utf8 : List(U8), U64 -> { codepoint : U32, next : U64 }
	decode_utf8 = |bytes, index| {
		first = U8.to_u32(Text.byte_at(bytes, index))
		if first < 128 {
			{ codepoint: first, next: index + 1 }
		} else if first < 224 {
			second = U8.to_u32(Text.byte_at(bytes, index + 1))
			{ codepoint: (first - 192) * 64 + second - 128, next: index + 2 }
		} else if first < 240 {
			second = U8.to_u32(Text.byte_at(bytes, index + 1))
			third = U8.to_u32(Text.byte_at(bytes, index + 2))
			{ codepoint: (first - 224) * 4096 + (second - 128) * 64 + third - 128, next: index + 3 }
		} else {
			second = U8.to_u32(Text.byte_at(bytes, index + 1))
			third = U8.to_u32(Text.byte_at(bytes, index + 2))
			fourth = U8.to_u32(Text.byte_at(bytes, index + 3))
			{ codepoint: (first - 240) * 262144 + (second - 128) * 4096 + (third - 128) * 64 + fourth - 128, next: index + 4 }
		}
	}

	byte_at : List(U8), U64 -> U8
	byte_at = |bytes, index|
		match List.get(bytes, index) {
			Ok(byte) => byte
			Err(_) => 0
		}

	prepare_builder! : Builder => Try(Prepared, [ResourceLimit, ..])
	prepare_builder! = |builder| {
		result = DrawHost.prepare_text!({
			text: builder.content,
			size: builder.size,
			spacing: builder.spacing,
			font: builder.font,
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

	align_top_left : Align
	align_top_left = { horizontal: Left, vertical: Top }

	align_top_center : Align
	align_top_center = { horizontal: Center, vertical: Top }

	align_top_right : Align
	align_top_right = { horizontal: Right, vertical: Top }

	align_center : Align
	align_center = { horizontal: Center, vertical: Middle }

	align_middle_left : Align
	align_middle_left = { horizontal: Left, vertical: Middle }

	align_middle_right : Align
	align_middle_right = { horizontal: Right, vertical: Middle }

	align_bottom_left : Align
	align_bottom_left = { horizontal: Left, vertical: Bottom }

	align_bottom_center : Align
	align_bottom_center = { horizontal: Center, vertical: Bottom }

	align_bottom_right : Align
	align_bottom_right = { horizontal: Right, vertical: Bottom }

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

	origin_for : Math.Vec2, Size, Align -> Math.Vec2
	origin_for = |pos, size, align| {
		offset = Text.align_offset(size, align)
		{ x: pos.x - offset.x, y: pos.y - offset.y }
	}

	draw_prepared! : Draw.Frame, { text : Prepared, pos : Math.Vec2, color : Color.Rgba, align : Align } => {}
	draw_prepared! = |_frame, cfg| {
		Prepared.(prepared) = cfg.text
		pos = Text.origin_for(cfg.pos, prepared.measured, cfg.align)
		DrawHost.draw_prepared_text!({ prepared: prepared.resource, pos, color: cfg.color })
	}
}

expect {
	builder = Text.from("Hello").size(32).spacing(2)
	builder.size == 32 and builder.spacing == 2
}

expect Text.align_offset({ width: 100, height: 40 }, Text.align_center) == { x: 50, y: 20 }

metric_fixture : Text.Metrics
metric_fixture = Text.Metrics.(
	{
		base_size: 2,
		line_spacing: 2,
		fallback_advance: 1,
		glyphs: [
			{ codepoint: 63, advance: 1 },
			{ codepoint: 87, advance: 2 },
			{ codepoint: 105, advance: 1 },
			{ codepoint: 233, advance: 1 },
		],
	},
)

expect metric_fixture.measure({ text: "iii", size: 20, spacing: 1 }) == { width: 32, height: 20 }

expect metric_fixture.measure({ text: "WWW", size: 20, spacing: 1 }) == { width: 62, height: 20 }

expect metric_fixture.measure({ text: "é", size: 20, spacing: 1 }) == { width: 10, height: 20 }

expect metric_fixture.measure({ text: "i\nW", size: 20, spacing: 1 }) == { width: 20, height: 42 }

expect metric_fixture.measure({ text: "\u(1f600)", size: 20, spacing: 1 }) == { width: 10, height: 20 }

expect metric_fixture.measure({ text: "i\u(0)W", size: 20, spacing: 1 }) == { width: 10, height: 20 }
