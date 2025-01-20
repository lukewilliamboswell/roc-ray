module [RocColor, from_rgba]

RocColor := U64 implements [Eq]

from_rgba : { r : U8, g : U8, b : U8, a : U8 } -> RocColor
from_rgba = |{ r, g, b, a }|
    (Num.int_cast(a) |> Num.shift_left_by(24))
    |> Num.bitwise_or((Num.int_cast(b) |> Num.shift_left_by(16)))
    |> Num.bitwise_or((Num.int_cast(g) |> Num.shift_left_by(8)))
    |> Num.bitwise_or(Num.int_cast(r))
    |> @RocColor

expect
    a = from_rgba({ r: 255, g: 255, b: 255, a: 255 })
    a == @RocColor(0x00000000_FFFFFFFF)

expect
    b = from_rgba({ r: 0, g: 0, b: 0, a: 0 })
    b == @RocColor(0x00000000_00000000)

expect
    c = from_rgba({ r: 255, g: 0, b: 0, a: 0 })
    c == @RocColor(0x00000000_000000FF)

expect
    d = from_rgba({ r: 0, g: 255, b: 0, a: 0 })
    d == @RocColor(0x00000000_0000FF00)

expect
    d = from_rgba({ r: 0, g: 0, b: 255, a: 0 })
    d == @RocColor(0x00000000_00FF0000)

expect
    d = from_rgba({ r: 0, g: 0, b: 0, a: 255 })
    d == @RocColor(0x00000000_FF000000)
