module [
    Constraint,
    Size,
    Layoutable,
    layout,
]

Constraint : {
    minWidth : F32,
    maxWidth : F32,
    minHeight : F32,
    maxHeight : F32,
}

Size : {
    width : F32,
    height : F32,
}

Layoutable implements
    layout : val, Constraint -> Size where val implements Layoutable
