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

	rgba : U8, U8, U8, U8 -> Color
	rgba = |r, g, b, a| { r, g, b, a }

	rgb : U8, U8, U8 -> Color
	rgb = |r, g, b| Color.rgba(r, g, b, 255)

	with_alpha : Color, U8 -> Color
	with_alpha = |color, a| { r: color.r, g: color.g, b: color.b, a }

	from_hex_rgb : U32 -> Color
	from_hex_rgb = |hex| {
		r = ((hex // 0x10000) % 0x100).to_u8_wrap()
		g = ((hex // 0x100) % 0x100).to_u8_wrap()
		b = (hex % 0x100).to_u8_wrap()
		Color.rgba(r, g, b, 255)
	}

	from_hex_rgba : U32 -> Color
	from_hex_rgba = |hex| {
		r = ((hex // 0x1000000) % 0x100).to_u8_wrap()
		g = ((hex // 0x10000) % 0x100).to_u8_wrap()
		b = ((hex // 0x100) % 0x100).to_u8_wrap()
		a = (hex % 0x100).to_u8_wrap()
		Color.rgba(r, g, b, a)
	}

	transparent : Color
	transparent = Color.rgba(0, 0, 0, 0)

	black : Color
	black = Color.rgb(0, 0, 0)

	blue : Color
	blue = Color.rgb(0, 121, 241)

	dark_gray : Color
	dark_gray = Color.rgb(80, 80, 80)

	gray : Color
	gray = Color.rgb(130, 130, 130)

	green : Color
	green = Color.rgb(0, 228, 48)

	light_gray : Color
	light_gray = Color.rgb(200, 200, 200)

	orange : Color
	orange = Color.rgb(255, 161, 0)

	pink : Color
	pink = Color.rgb(255, 109, 194)

	purple : Color
	purple = Color.rgb(200, 122, 255)

	ray_white : Color
	ray_white = Color.rgb(245, 245, 245)

	red : Color
	red = Color.rgb(230, 41, 55)

	white : Color
	white = Color.rgb(255, 255, 255)

	yellow : Color
	yellow = Color.rgb(253, 249, 0)
}
