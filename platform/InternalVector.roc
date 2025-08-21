module [RocVector2, from_xy, from_vector2, to_vector2]

RocVector2 := { x : F32, y : F32, unused : I64, unused2 : I64, unused3 : I64, unused4 : I64 }

from_xy : F32, F32 -> RocVector2
from_xy = |x, y| @RocVector2({ x, y, unused: 0, unused2: 0, unused3: 0, unused4: 0 })

from_vector2 : { x : F32, y : F32 } -> RocVector2
from_vector2 = |{ x, y }| @RocVector2({ x, y, unused: 0, unused2: 0, unused3: 0, unused4: 0 })

to_vector2 : RocVector2 -> { x : F32, y : F32 }
to_vector2 = |@RocVector2(v)| { x: v.x, y: v.y }
