module [RocColor, fromRGBA]

RocColor := U64 implements [Eq]

fromRGBA : { r : U8, g : U8, b : U8, a : U8 } -> RocColor
fromRGBA = \{ r, g, b, a } ->
    (Num.intCast a |> Num.shiftLeftBy 24)
    |> Num.bitwiseOr (Num.intCast b |> Num.shiftLeftBy 16)
    |> Num.bitwiseOr (Num.intCast g |> Num.shiftLeftBy 8)
    |> Num.bitwiseOr (Num.intCast r)
    |> @RocColor

expect
    a = fromRGBA { r: 255, g: 255, b: 255, a: 255 }
    a == @RocColor 0x00000000_FFFFFFFF

expect
    b = fromRGBA { r: 0, g: 0, b: 0, a: 0 }
    b == @RocColor 0x00000000_00000000

expect
    c = fromRGBA { r: 255, g: 0, b: 0, a: 0 }
    c == @RocColor 0x00000000_000000FF

expect
    d = fromRGBA { r: 0, g: 255, b: 0, a: 0 }
    d == @RocColor 0x00000000_0000FF00

expect
    d = fromRGBA { r: 0, g: 0, b: 255, a: 0 }
    d == @RocColor 0x00000000_00FF0000

expect
    d = fromRGBA { r: 0, g: 0, b: 0, a: 255 }
    d == @RocColor 0x00000000_FF000000
