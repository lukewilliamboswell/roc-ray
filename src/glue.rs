use crate::bindings;

#[derive(Clone, Copy, Default, Debug, PartialEq, PartialOrd)]
#[repr(C)]
pub struct Rectangle {
    pub height: f32,
    pub width: f32,
    pub x: f32,
    pub y: f32,
}

impl From<&Rectangle> for bindings::Rectangle {
    fn from(rectangle: &Rectangle) -> bindings::Rectangle {
        bindings::Rectangle {
            height: rectangle.height,
            width: rectangle.width,
            x: rectangle.x,
            y: rectangle.y,
        }
    }
}

#[derive(Clone, Copy, Default, Debug, PartialEq, PartialOrd)]
#[repr(C)]
pub struct Vector2 {
    pub x: f32,
    pub y: f32,
}

impl From<&Vector2> for bindings::Vector2 {
    fn from(vector2: &Vector2) -> bindings::Vector2 {
        bindings::Vector2 {
            x: vector2.x,
            y: vector2.y,
        }
    }
}

#[derive(Clone, Copy, Default, Debug, PartialEq, PartialOrd, Eq, Ord, Hash)]
#[repr(C)]
pub struct HostColor {
    // this is a hack to work around https://github.com/roc-lang/roc/issues/7142
    pub unused: i64,
    pub unused2: i64,
    pub a: u8,
    pub b: u8,
    pub g: u8,
    pub r: u8,
}

impl HostColor {
    pub const BLACK: HostColor = HostColor {
        unused: 0,
        unused2: 0,
        r: 0,
        g: 0,
        b: 0,
        a: 255,
    };
}

impl From<&HostColor> for bindings::Color {
    fn from(color: &HostColor) -> bindings::Color {
        bindings::Color {
            a: color.a,
            b: color.b,
            g: color.g,
            r: color.r,
        }
    }
}
