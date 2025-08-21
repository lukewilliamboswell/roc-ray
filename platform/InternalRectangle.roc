module [RocRectangle, from_rect]

RocRectangle := {
    x : F32,
    y : F32,
    width : F32,
    height : F32,
    unused : I64,
    unused2 : I64,
    unused3 : I64,
}

from_rect : { x : F32, y : F32, width : F32, height : F32 } -> RocRectangle
from_rect = |{ x, y, width, height }|
    @RocRectangle({ x, y, width, height, unused: 0, unused2: 0, unused3: 0 })
