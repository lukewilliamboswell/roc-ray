module [
    Pixel,
    PixelVec,
    add,
    sub,
    toVector2,
    subpixelsPerPixel,
    fromParts,
]

import rr.RocRay exposing [Vector2]

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
    totalSubpixels = px.pixels * subpixelsPerPixel + px.subpixels

    pixels = Num.divTrunc totalSubpixels subpixelsPerPixel
    subpixels = Num.rem px.subpixels subpixelsPerPixel

    @Pixel { pixels, subpixels }

fromParts : { pixels ? I64, subpixels ? I64 } -> Pixel
fromParts = \{ pixels ? 0, subpixels ? 0 } ->
    @Pixel { pixels, subpixels }

pixelInspector : Pixel -> Inspector f where f implements InspectFormatter
pixelInspector = \@Pixel px ->
    # TODO comment in zulip; this causes No borrow signature for LambdaName
    # Inspect.record [
    #     { key: "pixels", value: Inspect.i64 px.pixels },
    #     { key: "subpixels", value: Inspect.i64 px.subpixels },
    # ]
    Inspect.str (Inspect.toStr px)
