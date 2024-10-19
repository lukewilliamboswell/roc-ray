module [RocRectangle, fromRect]

RocRectangle := {
    x : F32,
    y : F32,
    width : F32,
    height : F32,
    unused : I64,
    unused2 : I64,
    unused3 : I64,
}

fromRect : { x : F32, y : F32, width : F32, height : F32 } -> RocRectangle
fromRect = \{ x, y, width, height } ->
    @RocRectangle { x, y, width, height, unused: 0, unused2: 0, unused3: 0 }
