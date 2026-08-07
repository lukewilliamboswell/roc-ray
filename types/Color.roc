## Color module - RGBA colors for the Roc raylib platform.
##
## Channels are 8-bit sRGB values. Alpha is 0 for transparent and 255 for
## fully opaque.
##
## The module is a namespace and the value type is `Color.Rgba`. It cannot be
## `Color.Color`: a nominal sharing its enclosing namespace's name crashes the
## compiler, and a module whose object *is* its data type cannot be re-exported
## from a package at all, because a module's own nominal cannot be an alias.
Color := [].{

	## An 8-bit sRGB color with alpha.
	##
	## `with_alpha` is deliberately a module function rather than a receiver on
	## this type: a receiver that calls its enclosing namespace's same-named
	## module function crashes the compiler. Every call site is `Color.with_alpha`
	## anyway, so the surface is unchanged.
	Rgba := {
		r : U8,
		g : U8,
		b : U8,
		a : U8,
	}.{

		## Compare all four color channels for equality.
		is_eq : _
	}

	## Construct a color from red, green, blue, and alpha channels.
	rgba : U8, U8, U8, U8 -> Rgba
	rgba = |r, g, b, a| { r, g, b, a }

	## Construct an opaque color from red, green, and blue channels.
	rgb : U8, U8, U8 -> Rgba
	rgb = |r, g, b| Color.rgba(r, g, b, 255)

	## Return a copy with a new alpha channel.
	with_alpha : Rgba, U8 -> Rgba
	with_alpha = |color, a| { r: color.r, g: color.g, b: color.b, a }

	## Decode `0xRRGGBB` into an opaque color.
	from_hex_rgb : U32 -> Rgba
	from_hex_rgb = |hex| {
		r = ((hex // 0x10000) % 0x100).to_u8_wrap()
		g = ((hex // 0x100) % 0x100).to_u8_wrap()
		b = (hex % 0x100).to_u8_wrap()
		Color.rgba(r, g, b, 255)
	}

	## Decode `0xRRGGBBAA` into a color.
	from_hex_rgba : U32 -> Rgba
	from_hex_rgba = |hex| {
		r = ((hex // 0x1000000) % 0x100).to_u8_wrap()
		g = ((hex // 0x10000) % 0x100).to_u8_wrap()
		b = ((hex // 0x100) % 0x100).to_u8_wrap()
		a = (hex % 0x100).to_u8_wrap()
		Color.rgba(r, g, b, a)
	}

	## Fully transparent black.
	transparent : Rgba
	transparent = Color.rgba(0, 0, 0, 0)

	## Black.
	black : Rgba
	black = Color.rgb(0, 0, 0)

	## Raylib's standard blue.
	blue : Rgba
	blue = Color.rgb(0, 121, 241)

	## Raylib's standard dark gray.
	dark_gray : Rgba
	dark_gray = Color.rgb(80, 80, 80)

	## Raylib's standard gray.
	gray : Rgba
	gray = Color.rgb(130, 130, 130)

	## Raylib's standard green.
	green : Rgba
	green = Color.rgb(0, 228, 48)

	## Raylib's standard light gray.
	light_gray : Rgba
	light_gray = Color.rgb(200, 200, 200)

	## Raylib's standard orange.
	orange : Rgba
	orange = Color.rgb(255, 161, 0)

	## Raylib's standard pink.
	pink : Rgba
	pink = Color.rgb(255, 109, 194)

	## Raylib's standard purple.
	purple : Rgba
	purple = Color.rgb(200, 122, 255)

	## Raylib's warm off-white background color.
	ray_white : Rgba
	ray_white = Color.rgb(245, 245, 245)

	## Raylib's standard red.
	red : Rgba
	red = Color.rgb(230, 41, 55)

	## White.
	white : Rgba
	white = Color.rgb(255, 255, 255)

	## Raylib's standard yellow.
	yellow : Rgba
	yellow = Color.rgb(253, 249, 0)
}

expect Color.rgb(1, 2, 3) == Color.rgba(1, 2, 3, 255)
expect Color.from_hex_rgb(0x0079F1) == Color.blue
expect Color.from_hex_rgba(0xFFFFFF00) == Color.with_alpha(Color.white, 0)
expect Color.with_alpha(Color.white, 55).a == 55
expect Color.transparent == Color.rgba(0, 0, 0, 0)
