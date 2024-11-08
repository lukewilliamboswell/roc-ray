module [RocVector2, fromXY, fromVector2, toVector2]

RocVector2 := { x : F32, y : F32, unused : I64, unused2 : I64, unused3 : I64, unused4 : I64 }

fromXY : F32, F32 -> RocVector2
fromXY = \x, y -> @RocVector2 { x, y, unused: 0, unused2: 0, unused3: 0, unused4: 0 }

fromVector2 : { x : F32, y : F32 } -> RocVector2
fromVector2 = \{ x, y } -> @RocVector2 { x, y, unused: 0, unused2: 0, unused3: 0, unused4: 0 }

toVector2 : RocVector2 -> { x : F32, y : F32 }
toVector2 = \@RocVector2 v -> { x: v.x, y: v.y }
