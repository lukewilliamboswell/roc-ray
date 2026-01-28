//! Type definitions for the roc-ray platform.
//!
//! This module contains both safe Zig types for internal use and FFI-compatible
//! extern structs that match Roc's memory layout exactly. The safe types provide
//! compile-time safety, while nested FFI structs handle Roc interop and serialization.
//!
//! IMPORTANT: FFI struct field ordering must match Roc's layout rules:
//! 1. Fields sorted by alignment (descending)
//! 2. Within same alignment, sorted alphabetically by field name

const std = @import("std");
const builtins = @import("builtins");

// Roc Builtins Re-exports

pub const RocStr = builtins.str.RocStr;
pub const RocList = builtins.list.RocList;

// Host ABI types
pub const RocOps = builtins.host_abi.RocOps;
pub const HostedFn = builtins.host_abi.HostedFn;
pub const RocAlloc = builtins.host_abi.RocAlloc;
pub const RocDealloc = builtins.host_abi.RocDealloc;
pub const RocRealloc = builtins.host_abi.RocRealloc;
pub const RocDbg = builtins.host_abi.RocDbg;
pub const RocExpectFailed = builtins.host_abi.RocExpectFailed;
pub const RocCrashed = builtins.host_abi.RocCrashed;

/// Boxed value - opaque pointer to heap-allocated Roc data
pub const RocBox = *anyopaque;

// Color

/// Color enum with compile-time safety.
/// Values match Roc's Color tag union discriminants (alphabetically sorted).
pub const Color = enum(u8) {
    black = 0,
    blue = 1,
    dark_gray = 2,
    gray = 3,
    green = 4,
    light_gray = 5,
    orange = 6,
    pink = 7,
    purple = 8,
    ray_white = 9,
    red = 10,
    white = 11,
    yellow = 12,

    /// Convert from raw u8 discriminant, returning white for invalid values.
    /// This is the default safe API for FFI boundaries.
    pub fn fromU8(value: u8) Color {
        return fromU8Checked(value) orelse .white;
    }

    /// Convert from raw u8 discriminant with validation.
    /// Returns null if the value is not a valid color discriminant.
    pub fn fromU8Checked(value: u8) ?Color {
        return std.meta.intToEnum(Color, value) catch null;
    }

    /// Convert to raw u8 discriminant (for serialization).
    pub fn toU8(self: Color) u8 {
        return @intFromEnum(self);
    }
};

// Vector2

/// 2D vector with x and y components.
pub const Vector2 = struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) Vector2 {
        return .{ .x = x, .y = y };
    }

    pub fn zero() Vector2 {
        return .{ .x = 0, .y = 0 };
    }

    /// FFI-compatible layout matching Roc's Vector2.
    pub const FFI = extern struct {
        x: f32,
        y: f32,

        pub fn toVector2(self: FFI) Vector2 {
            return .{ .x = self.x, .y = self.y };
        }
    };

    pub fn toFfi(self: Vector2) FFI {
        return .{ .x = self.x, .y = self.y };
    }
};

// Circle

/// Circle shape with center point, radius, and color.
pub const Circle = struct {
    center: Vector2,
    radius: f32,
    color: Color,

    /// FFI-compatible layout matching Roc's Circle.
    /// Field order: center (align 4), radius (align 4), color (align 1)
    pub const FFI = extern struct {
        center: Vector2.FFI,
        radius: f32,
        color: u8,

        pub fn toCircle(self: FFI) Circle {
            return .{
                .center = self.center.toVector2(),
                .radius = self.radius,
                .color = Color.fromU8(self.color),
            };
        }
    };

    pub fn toFfi(self: Circle) FFI {
        return .{
            .center = self.center.toFfi(),
            .radius = self.radius,
            .color = self.color.toU8(),
        };
    }
};

// Rectangle

/// Rectangle shape with position, dimensions, and color.
pub const Rectangle = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    color: Color,

    /// FFI-compatible layout matching Roc's Rectangle.
    /// Field order (alphabetical among f32s): height, width, x, y, then color
    pub const FFI = extern struct {
        height: f32,
        width: f32,
        x: f32,
        y: f32,
        color: u8,

        pub fn toRectangle(self: FFI) Rectangle {
            return .{
                .x = self.x,
                .y = self.y,
                .width = self.width,
                .height = self.height,
                .color = Color.fromU8(self.color),
            };
        }
    };

    pub fn toFfi(self: Rectangle) FFI {
        return .{
            .height = self.height,
            .width = self.width,
            .x = self.x,
            .y = self.y,
            .color = self.color.toU8(),
        };
    }
};

// RectangleGradientV

/// Rectangle with vertical gradient (top to bottom).
pub const RectangleGradientV = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    color_top: Color,
    color_bottom: Color,

    /// FFI-compatible layout matching Roc's RectangleGradientV.
    /// Field order: f32s alphabetically (height, width, x, y), then u8s alphabetically (color_bottom, color_top)
    pub const FFI = extern struct {
        height: f32,
        width: f32,
        x: f32,
        y: f32,
        color_bottom: u8,
        color_top: u8,

        pub fn toRectangleGradientV(self: FFI) RectangleGradientV {
            return .{
                .x = self.x,
                .y = self.y,
                .width = self.width,
                .height = self.height,
                .color_top = Color.fromU8(self.color_top),
                .color_bottom = Color.fromU8(self.color_bottom),
            };
        }
    };

    pub fn toFfi(self: RectangleGradientV) FFI {
        return .{
            .height = self.height,
            .width = self.width,
            .x = self.x,
            .y = self.y,
            .color_bottom = self.color_bottom.toU8(),
            .color_top = self.color_top.toU8(),
        };
    }
};

// RectangleGradientH

/// Rectangle with horizontal gradient (left to right).
pub const RectangleGradientH = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    color_left: Color,
    color_right: Color,

    /// FFI-compatible layout matching Roc's RectangleGradientH.
    /// Field order: f32s alphabetically (height, width, x, y), then u8s alphabetically (color_left, color_right)
    pub const FFI = extern struct {
        height: f32,
        width: f32,
        x: f32,
        y: f32,
        color_left: u8,
        color_right: u8,

        pub fn toRectangleGradientH(self: FFI) RectangleGradientH {
            return .{
                .x = self.x,
                .y = self.y,
                .width = self.width,
                .height = self.height,
                .color_left = Color.fromU8(self.color_left),
                .color_right = Color.fromU8(self.color_right),
            };
        }
    };

    pub fn toFfi(self: RectangleGradientH) FFI {
        return .{
            .height = self.height,
            .width = self.width,
            .x = self.x,
            .y = self.y,
            .color_left = self.color_left.toU8(),
            .color_right = self.color_right.toU8(),
        };
    }
};

// CircleGradient

/// Circle with radial gradient (inner to outer).
pub const CircleGradient = struct {
    center: Vector2,
    radius: f32,
    color_inner: Color,
    color_outer: Color,

    /// FFI-compatible layout matching Roc's CircleGradient.
    /// Field order: center (align 4), radius (align 4), then u8s alphabetically (color_inner, color_outer)
    pub const FFI = extern struct {
        center: Vector2.FFI,
        radius: f32,
        color_inner: u8,
        color_outer: u8,

        pub fn toCircleGradient(self: FFI) CircleGradient {
            return .{
                .center = self.center.toVector2(),
                .radius = self.radius,
                .color_inner = Color.fromU8(self.color_inner),
                .color_outer = Color.fromU8(self.color_outer),
            };
        }
    };

    pub fn toFfi(self: CircleGradient) FFI {
        return .{
            .center = self.center.toFfi(),
            .radius = self.radius,
            .color_inner = self.color_inner.toU8(),
            .color_outer = self.color_outer.toU8(),
        };
    }
};

// Line

/// Line shape with start and end points, and color.
pub const Line = struct {
    start: Vector2,
    end: Vector2,
    color: Color,

    /// FFI-compatible layout matching Roc's Line.
    /// Field order (alphabetical): end, start, then color
    pub const FFI = extern struct {
        end: Vector2.FFI,
        start: Vector2.FFI,
        color: u8,

        pub fn toLine(self: FFI) Line {
            return .{
                .start = self.start.toVector2(),
                .end = self.end.toVector2(),
                .color = Color.fromU8(self.color),
            };
        }
    };

    pub fn toFfi(self: Line) FFI {
        return .{
            .end = self.end.toFfi(),
            .start = self.start.toFfi(),
            .color = self.color.toU8(),
        };
    }
};

// Text

/// Text to be rendered with position, content, size, and color.
pub const Text = struct {
    pos: Vector2,
    content: []const u8,
    size: i32,
    color: Color,

    /// FFI-compatible layout matching Roc's Text.
    /// On 64-bit: RocStr is 8-byte aligned -> text, pos, size, color
    /// On 32-bit: RocStr is 4-byte aligned -> pos, size, text, color
    pub const FFI = if (@sizeOf(*anyopaque) == 4)
        extern struct {
            pos: Vector2.FFI,
            size: i32,
            text: RocStr,
            color: u8,
        }
    else
        extern struct {
            text: RocStr,
            pos: Vector2.FFI,
            size: i32,
            color: u8,
        };

    /// Serialization-only layout for .rrsim format.
    /// Text content is stored separately in the string buffer.
    pub const Serialized = extern struct {
        pos_x: f32,
        pos_y: f32,
        size: i32,
        color: u8,
        text_offset: u32,
        text_len: u32,
    };
};

// InputState / Host state

/// Platform input state (safe version).
/// Represents the state of input devices at a given frame.
pub const InputState = struct {
    frame_count: u64,
    mouse_x: f32,
    mouse_y: f32,
    mouse_wheel: f32,
    mouse_left: bool,
    mouse_middle: bool,
    mouse_right: bool,

    pub fn init() InputState {
        return .{
            .frame_count = 0,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_wheel = 0,
            .mouse_left = false,
            .mouse_middle = false,
            .mouse_right = false,
        };
    }

    /// FFI-compatible layout matching Roc's HostStateFromHost.
    /// Field order: frame_count (align 8), mouse_wheel/x/y (align 4, alphabetical),
    /// then mouse_left/middle/right (align 1, alphabetical)
    pub const FFI = extern struct {
        frame_count: u64,
        mouse_wheel: f32,
        mouse_x: f32,
        mouse_y: f32,
        mouse_left: bool,
        mouse_middle: bool,
        mouse_right: bool,

        pub fn toInputState(self: FFI) InputState {
            return .{
                .frame_count = self.frame_count,
                .mouse_x = self.mouse_x,
                .mouse_y = self.mouse_y,
                .mouse_wheel = self.mouse_wheel,
                .mouse_left = self.mouse_left,
                .mouse_middle = self.mouse_middle,
                .mouse_right = self.mouse_right,
            };
        }
    };

    pub fn toFfi(self: InputState) FFI {
        return .{
            .frame_count = self.frame_count,
            .mouse_wheel = self.mouse_wheel,
            .mouse_x = self.mouse_x,
            .mouse_y = self.mouse_y,
            .mouse_left = self.mouse_left,
            .mouse_middle = self.mouse_middle,
            .mouse_right = self.mouse_right,
        };
    }

    /// Serialization layout for .rrsim format.
    /// Uses u8 for bools to ensure stable binary format.
    pub const Serialized = extern struct {
        frame_count: u64,
        mouse_wheel: f32,
        mouse_x: f32,
        mouse_y: f32,
        mouse_left: u8,
        mouse_middle: u8,
        mouse_right: u8,
        _padding: u8 = 0,

        pub fn toInputState(self: Serialized) InputState {
            return .{
                .frame_count = self.frame_count,
                .mouse_x = self.mouse_x,
                .mouse_y = self.mouse_y,
                .mouse_wheel = self.mouse_wheel,
                .mouse_left = self.mouse_left != 0,
                .mouse_middle = self.mouse_middle != 0,
                .mouse_right = self.mouse_right != 0,
            };
        }
    };

    pub fn toSerialized(self: InputState) Serialized {
        return .{
            .frame_count = self.frame_count,
            .mouse_wheel = self.mouse_wheel,
            .mouse_x = self.mouse_x,
            .mouse_y = self.mouse_y,
            .mouse_left = if (self.mouse_left) 1 else 0,
            .mouse_middle = if (self.mouse_middle) 1 else 0,
            .mouse_right = if (self.mouse_right) 1 else 0,
        };
    }
};

// Roc Result Types

/// Runtime layout for `Try(Str, [NotFound])`
/// Used as return type for Host.read_env!
pub const Try_Str_NotFound = extern struct {
    /// RocStr payload for Ok variant (24 bytes on 64-bit, 12 bytes on 32-bit)
    payload: RocStr,
    /// 0 = Err (NotFound), 1 = Ok
    discriminant: u8,
    // Padding to align struct properly
    _padding: if (@sizeOf(*anyopaque) == 4) [3]u8 else [7]u8,

    pub fn ok(str: RocStr) Try_Str_NotFound {
        return .{ .payload = str, .discriminant = 1, ._padding = undefined };
    }

    pub fn notFound() Try_Str_NotFound {
        return .{ .payload = RocStr.empty(), .discriminant = 0, ._padding = undefined };
    }
};

/// Runtime layout for the Roc type `Try(Box(Model), I64)`
/// Used as return type for init_for_host and render_for_host
pub const Try_BoxModel_I64 = extern struct {
    /// Box(Model) or I64 (8 bytes)
    payload: extern union { ok: RocBox, err: i64 },
    /// 0 = Err, 1 = Ok (1 byte)
    discriminant: u8,
    /// Padding to maintain 8-byte alignment
    _padding: [7]u8,

    pub fn isOk(self: Try_BoxModel_I64) bool {
        return self.discriminant == 1;
    }

    pub fn isErr(self: Try_BoxModel_I64) bool {
        return self.discriminant == 0;
    }

    pub fn getModel(self: Try_BoxModel_I64) RocBox {
        return self.payload.ok;
    }

    pub fn getErrCode(self: Try_BoxModel_I64) i64 {
        return self.payload.err;
    }
};

/// Args tuple for render_for_host!
/// Per RocCall ABI, all args are passed as a single pointer to a tuple struct.
/// Roc sorts tuple fields by alignment (descending), then alphabetically.
///
/// On 64-bit: pointer align == u64 align (8), so sorted alphabetically -> model, state
/// On 32-bit WASM: pointer align (4) < u64 align (8), so sorted by align -> state, model
pub const RenderArgs = if (@sizeOf(*anyopaque) == 4)
    extern struct {
        state: InputState.FFI,
        model: RocBox,
    }
else
    extern struct {
        model: RocBox,
        state: InputState.FFI,
    };

// External Roc Functions (provided at link time)

/// Initialize the Roc application, returning the initial model.
pub extern fn roc__init_for_host(ops: *RocOps, ret_ptr: *Try_BoxModel_I64, arg_ptr: ?*anyopaque) callconv(.c) void;

/// Render a frame, taking the current model and platform state, returning an updated model.
pub extern fn roc__render_for_host(ops: *RocOps, ret_ptr: *Try_BoxModel_I64, args_ptr: *RenderArgs) callconv(.c) void;

// Tests

test "Color.fromU8 valid values" {
    try std.testing.expectEqual(Color.black, Color.fromU8(0));
    try std.testing.expectEqual(Color.blue, Color.fromU8(1));
    try std.testing.expectEqual(Color.white, Color.fromU8(11));
    try std.testing.expectEqual(Color.yellow, Color.fromU8(12));
}

test "Color.fromU8 invalid value returns white" {
    try std.testing.expectEqual(Color.white, Color.fromU8(13));
    try std.testing.expectEqual(Color.white, Color.fromU8(255));
}

test "Color.fromU8Checked valid values" {
    try std.testing.expectEqual(Color.black, Color.fromU8Checked(0).?);
    try std.testing.expectEqual(Color.blue, Color.fromU8Checked(1).?);
    try std.testing.expectEqual(Color.white, Color.fromU8Checked(11).?);
    try std.testing.expectEqual(Color.yellow, Color.fromU8Checked(12).?);
}

test "Color.fromU8Checked invalid value returns null" {
    try std.testing.expect(Color.fromU8Checked(13) == null);
    try std.testing.expect(Color.fromU8Checked(255) == null);
}

test "Color.toU8 round trip" {
    inline for (std.meta.fields(Color)) |field| {
        const color: Color = @enumFromInt(field.value);
        try std.testing.expectEqual(color, Color.fromU8(color.toU8()));
    }
}

test "Vector2.init" {
    const v = Vector2.init(1.5, 2.5);
    try std.testing.expectEqual(@as(f32, 1.5), v.x);
    try std.testing.expectEqual(@as(f32, 2.5), v.y);
}

test "Vector2.zero" {
    const v = Vector2.zero();
    try std.testing.expectEqual(@as(f32, 0), v.x);
    try std.testing.expectEqual(@as(f32, 0), v.y);
}

test "Vector2 FFI round trip" {
    const v = Vector2.init(3.5, 4.5);
    const ffi = v.toFfi();
    const back = ffi.toVector2();
    try std.testing.expectEqual(v.x, back.x);
    try std.testing.expectEqual(v.y, back.y);
}

test "Circle FFI round trip" {
    const c = Circle{
        .center = Vector2.init(10, 20),
        .radius = 5.0,
        .color = .red,
    };
    const ffi = c.toFfi();
    const back = ffi.toCircle();
    try std.testing.expectEqual(c.center.x, back.center.x);
    try std.testing.expectEqual(c.center.y, back.center.y);
    try std.testing.expectEqual(c.radius, back.radius);
    try std.testing.expectEqual(c.color, back.color);
}

test "Rectangle FFI round trip" {
    const r = Rectangle{
        .x = 10,
        .y = 20,
        .width = 100,
        .height = 50,
        .color = .blue,
    };
    const ffi = r.toFfi();
    const back = ffi.toRectangle();
    try std.testing.expectEqual(r.x, back.x);
    try std.testing.expectEqual(r.y, back.y);
    try std.testing.expectEqual(r.width, back.width);
    try std.testing.expectEqual(r.height, back.height);
    try std.testing.expectEqual(r.color, back.color);
}

test "Line FFI round trip" {
    const l = Line{
        .start = Vector2.init(0, 0),
        .end = Vector2.init(100, 100),
        .color = .green,
    };
    const ffi = l.toFfi();
    const back = ffi.toLine();
    try std.testing.expectEqual(l.start.x, back.start.x);
    try std.testing.expectEqual(l.start.y, back.start.y);
    try std.testing.expectEqual(l.end.x, back.end.x);
    try std.testing.expectEqual(l.end.y, back.end.y);
    try std.testing.expectEqual(l.color, back.color);
}

test "InputState.init" {
    const state = InputState.init();
    try std.testing.expectEqual(@as(u64, 0), state.frame_count);
    try std.testing.expect(!state.mouse_left);
    try std.testing.expect(!state.mouse_middle);
    try std.testing.expect(!state.mouse_right);
}

test "InputState FFI round trip" {
    const state = InputState{
        .frame_count = 42,
        .mouse_x = 100.5,
        .mouse_y = 200.5,
        .mouse_wheel = 1.0,
        .mouse_left = true,
        .mouse_middle = false,
        .mouse_right = true,
    };
    const ffi = state.toFfi();
    const back = ffi.toInputState();
    try std.testing.expectEqual(state.frame_count, back.frame_count);
    try std.testing.expectEqual(state.mouse_x, back.mouse_x);
    try std.testing.expectEqual(state.mouse_y, back.mouse_y);
    try std.testing.expectEqual(state.mouse_wheel, back.mouse_wheel);
    try std.testing.expectEqual(state.mouse_left, back.mouse_left);
    try std.testing.expectEqual(state.mouse_middle, back.mouse_middle);
    try std.testing.expectEqual(state.mouse_right, back.mouse_right);
}

test "InputState Serialized round trip" {
    const state = InputState{
        .frame_count = 100,
        .mouse_x = 50.0,
        .mouse_y = 75.0,
        .mouse_wheel = -0.5,
        .mouse_left = true,
        .mouse_middle = false,
        .mouse_right = true,
    };
    const ser = state.toSerialized();
    const back = ser.toInputState();
    try std.testing.expectEqual(state.frame_count, back.frame_count);
    try std.testing.expectEqual(state.mouse_x, back.mouse_x);
    try std.testing.expectEqual(state.mouse_y, back.mouse_y);
    try std.testing.expectEqual(state.mouse_wheel, back.mouse_wheel);
    try std.testing.expectEqual(state.mouse_left, back.mouse_left);
    try std.testing.expectEqual(state.mouse_middle, back.mouse_middle);
    try std.testing.expectEqual(state.mouse_right, back.mouse_right);
}

test "RectangleGradientV FFI round trip" {
    const r = RectangleGradientV{
        .x = 10,
        .y = 20,
        .width = 100,
        .height = 50,
        .color_top = .blue,
        .color_bottom = .red,
    };
    const ffi = r.toFfi();
    const back = ffi.toRectangleGradientV();
    try std.testing.expectEqual(r.x, back.x);
    try std.testing.expectEqual(r.y, back.y);
    try std.testing.expectEqual(r.width, back.width);
    try std.testing.expectEqual(r.height, back.height);
    try std.testing.expectEqual(r.color_top, back.color_top);
    try std.testing.expectEqual(r.color_bottom, back.color_bottom);
}

test "RectangleGradientH FFI round trip" {
    const r = RectangleGradientH{
        .x = 15,
        .y = 25,
        .width = 200,
        .height = 75,
        .color_left = .green,
        .color_right = .yellow,
    };
    const ffi = r.toFfi();
    const back = ffi.toRectangleGradientH();
    try std.testing.expectEqual(r.x, back.x);
    try std.testing.expectEqual(r.y, back.y);
    try std.testing.expectEqual(r.width, back.width);
    try std.testing.expectEqual(r.height, back.height);
    try std.testing.expectEqual(r.color_left, back.color_left);
    try std.testing.expectEqual(r.color_right, back.color_right);
}

test "CircleGradient FFI round trip" {
    const c = CircleGradient{
        .center = Vector2.init(100, 150),
        .radius = 75.0,
        .color_inner = .white,
        .color_outer = .blue,
    };
    const ffi = c.toFfi();
    const back = ffi.toCircleGradient();
    try std.testing.expectEqual(c.center.x, back.center.x);
    try std.testing.expectEqual(c.center.y, back.center.y);
    try std.testing.expectEqual(c.radius, back.radius);
    try std.testing.expectEqual(c.color_inner, back.color_inner);
    try std.testing.expectEqual(c.color_outer, back.color_outer);
}
