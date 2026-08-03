## Color module - RGBA colors for the Roc raylib platform.
##
## Channels are 8-bit sRGB values. Alpha is 0 for transparent and 255 for
## fully opaque.
Color := {
	r : U8,
	g : U8,
	b : U8,
	a : U8,
}.{

	## Construct a color from red, green, blue, and alpha channels.
	rgba : U8, U8, U8, U8 -> Color
	rgba = |r, g, b, a| { r, g, b, a }

	## Construct an opaque color from red, green, and blue channels.
	rgb : U8, U8, U8 -> Color
	rgb = |r, g, b| Color.rgba(r, g, b, 255)

	## Return a copy with a new alpha channel.
	with_alpha : Color, U8 -> Color
	with_alpha = |color, a| { r: color.r, g: color.g, b: color.b, a }

	## Decode `0xRRGGBB` into an opaque color.
	from_hex_rgb : U32 -> Color
	from_hex_rgb = |hex| {
		r = ((hex // 0x10000) % 0x100).to_u8_wrap()
		g = ((hex // 0x100) % 0x100).to_u8_wrap()
		b = (hex % 0x100).to_u8_wrap()
		Color.rgba(r, g, b, 255)
	}

	## Decode `0xRRGGBBAA` into a color.
	from_hex_rgba : U32 -> Color
	from_hex_rgba = |hex| {
		r = ((hex // 0x1000000) % 0x100).to_u8_wrap()
		g = ((hex // 0x10000) % 0x100).to_u8_wrap()
		b = ((hex // 0x100) % 0x100).to_u8_wrap()
		a = (hex % 0x100).to_u8_wrap()
		Color.rgba(r, g, b, a)
	}

	## Fully transparent black.
	transparent : Color
	transparent = Color.rgba(0, 0, 0, 0)

	## Black.
	black : Color
	black = Color.rgb(0, 0, 0)

	## Raylib's standard blue.
	blue : Color
	blue = Color.rgb(0, 121, 241)

	## Raylib's standard dark gray.
	dark_gray : Color
	dark_gray = Color.rgb(80, 80, 80)

	## Raylib's standard gray.
	gray : Color
	gray = Color.rgb(130, 130, 130)

	## Raylib's standard green.
	green : Color
	green = Color.rgb(0, 228, 48)

	## Raylib's standard light gray.
	light_gray : Color
	light_gray = Color.rgb(200, 200, 200)

	## Raylib's standard orange.
	orange : Color
	orange = Color.rgb(255, 161, 0)

	## Raylib's standard pink.
	pink : Color
	pink = Color.rgb(255, 109, 194)

	## Raylib's standard purple.
	purple : Color
	purple = Color.rgb(200, 122, 255)

	## Raylib's warm off-white background color.
	ray_white : Color
	ray_white = Color.rgb(245, 245, 245)

	## Raylib's standard red.
	red : Color
	red = Color.rgb(230, 41, 55)

	## White.
	white : Color
	white = Color.rgb(255, 255, 255)

	## Raylib's standard yellow.
	yellow : Color
	yellow = Color.rgb(253, 249, 0)

	## Compare all four color channels for equality.
	is_eq : _
}
