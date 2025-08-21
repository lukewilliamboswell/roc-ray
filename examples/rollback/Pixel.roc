module [
    Pixel,
    PixelVec,
    add,
    sub,
    to_vector2,
    subpixels_per_pixel,
    from_parts,
    total_subpixels,
    from_pixels,
]

import rr.RocRay exposing [Vector2]

# A 1-D integer position with a integer sub-pixel component
# Use instead of floats to avoid rounding errors
Pixel := { pixels : I64, subpixels : I64 }
    implements [
        Eq,
        Hash,
        Inspect { to_inspector: pixel_inspector },
    ]

PixelVec : { x : Pixel, y : Pixel }

subpixels_per_pixel : I64
subpixels_per_pixel = 16

to_vector2 : PixelVec -> Vector2
to_vector2 = |{ x: @Pixel(xpx), y: @Pixel(ypx) }|
    { x: Num.to_f32(xpx.pixels), y: Num.to_f32(ypx.pixels) }

add : Pixel, { pixels ?? I64, subpixels ?? I64 } -> Pixel
add = |@Pixel(px), { pixels ?? 0, subpixels ?? 0 }|
    pixel = @Pixel({ pixels: px.pixels + pixels, subpixels: px.subpixels + subpixels })
    normalize(pixel)

sub : Pixel, { pixels ?? I64, subpixels ?? I64 } -> Pixel
sub = |@Pixel(px), { pixels ?? 0, subpixels ?? 0 }|
    pixel = @Pixel({ pixels: px.pixels - pixels, subpixels: px.subpixels - subpixels })
    normalize(pixel)

normalize : Pixel -> Pixel
normalize = |@Pixel(px)|
    total = px.pixels * subpixels_per_pixel + px.subpixels

    pixels = Num.div_trunc(total, subpixels_per_pixel)
    subpixels = Num.rem(px.subpixels, subpixels_per_pixel)

    @Pixel({ pixels, subpixels })

total_subpixels : Pixel -> I64
total_subpixels = |@Pixel(px)|
    px.pixels * subpixels_per_pixel + px.subpixels

from_pixels : I64 -> Pixel
from_pixels = |pixels|
    from_parts({ pixels, subpixels: 0 })

from_parts : { pixels : I64, subpixels : I64 } -> Pixel
from_parts = |{ pixels, subpixels }|
    @Pixel({ pixels, subpixels })
    |> normalize

pixel_inspector : Pixel -> Inspector f where f implements InspectFormatter
pixel_inspector = |@Pixel(px)|
    Inspect.str(Inspect.to_str(px))

expect
    x = from_parts({ pixels: 1, subpixels: 0 })
    y = from_parts({ pixels: 2, subpixels: 2 })
    vec = { x, y }

    inspected = Inspect.to_str(vec)
    expected =
        """
        {x: "{pixels: 1, subpixels: 0}", y: "{pixels: 2, subpixels: 2}"}
        """

    inspected == expected
