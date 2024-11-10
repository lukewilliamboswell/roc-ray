module [
    Pixel,
    PixelVec,
    add,
    sub,
    toVector2,
    subpixelsPerPixel,
    fromParts,
    totalSubpixels,
]

import rr.RocRay exposing [Vector2]

# TODO get rid of subpixels altogether
# A 1-D integer position with a integer sub-pixel component
# Use instead of floats to avoid rounding errors
Pixel := { pixels : I64, subpixels : I64 }
    implements [
        Eq,
        Hash,
        Inspect { toInspector: pixelInspector },
    ]

PixelVec : { x : Pixel, y : Pixel }

subpixelsPerPixel : I64
subpixelsPerPixel = 16

toVector2 : PixelVec -> Vector2
toVector2 = \{ x: @Pixel xpx, y: @Pixel ypx } ->
    { x: Num.toF32 xpx.pixels, y: Num.toF32 ypx.pixels }

add : Pixel, { pixels ? I64, subpixels ? I64 } -> Pixel
add = \@Pixel px, { pixels ? 0, subpixels ? 0 } ->
    pixel = @Pixel { pixels: px.pixels + pixels, subpixels: px.subpixels + subpixels }
    normalize pixel

sub : Pixel, { pixels ? I64, subpixels ? I64 } -> Pixel
sub = \@Pixel px, { pixels ? 0, subpixels ? 0 } ->
    pixel = @Pixel { pixels: px.pixels - pixels, subpixels: px.subpixels - subpixels }
    normalize pixel

normalize : Pixel -> Pixel
normalize = \@Pixel px ->
    total = px.pixels * subpixelsPerPixel + px.subpixels

    pixels = Num.divTrunc total subpixelsPerPixel
    subpixels = Num.rem px.subpixels subpixelsPerPixel

    @Pixel { pixels, subpixels }

totalSubpixels : Pixel -> I64
totalSubpixels = \@Pixel px ->
    px.pixels * subpixelsPerPixel + px.subpixels

fromParts : { pixels ? I64, subpixels ? I64 } -> Pixel
fromParts = \{ pixels ? 0, subpixels ? 0 } ->
    @Pixel { pixels, subpixels }

pixelInspector : Pixel -> Inspector f where f implements InspectFormatter
pixelInspector = \@Pixel px ->
    Inspect.str (Inspect.toStr px)

expect
    x = fromParts { pixels: 1 }
    y = fromParts { pixels: 2 }
    vec = { x, y }

    inspected = Inspect.toStr vec
    expected =
        """
        {x: "{pixels: 1, subpixels: 0}", y: "{pixels: 2, subpixels: 0}"}
        """

    inspected == expected
