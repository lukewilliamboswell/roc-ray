module [Window, default]

Window : {
    fpsTarget : I32,
    fpsDisplay : [Visible I32 I32, Hidden],
    title : Str,
    width : F32,
    height : F32,
}

default : Window
default = {
    fpsTarget: 120,
    fpsDisplay: Hidden,
    title: "RocRay Graphics",
    width: 800,
    height: 600,
}
