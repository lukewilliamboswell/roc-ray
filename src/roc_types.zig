//! Shared Roc ABI types for platform host implementations.
//!
//! This module contains the exact type definitions that match Roc's memory layout
//! for the platform's exposed types. Both native (raylib) and web (canvas) hosts
//! import these types to ensure ABI compatibility.
//!
//! IMPORTANT: Field ordering in extern structs must match Roc's layout rules:
//! 1. Fields sorted by alignment (descending)
//! 2. Within same alignment, sorted alphabetically by field name

const builtins = @import("builtins");

// Re-export commonly used builtins types
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

// ============================================================================
// Core Types
// ============================================================================

/// Boxed value - opaque pointer to heap-allocated Roc data
pub const RocBox = *anyopaque;

/// Roc Vector2 type layout: { x: F32, y: F32 }
pub const RocVector2 = extern struct {
    x: f32,
    y: f32,
};

// ============================================================================
// Platform State Types
// ============================================================================

/// Roc PlatformStateFromHost type layout
/// Fields ordered by alignment (descending), then alphabetically within each alignment group
pub const RocPlatformState = extern struct {
    frame_count: u64, // @0 (align 8)
    mouse_wheel: f32, // @8 (align 4, "wheel" < "x" < "y")
    mouse_x: f32, // @12
    mouse_y: f32, // @16
    mouse_left: bool, // @20 (align 1, "left" < "middle" < "right")
    mouse_middle: bool, // @21
    mouse_right: bool, // @22
};

// ============================================================================
// Result Types
// ============================================================================

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
/// On 64-bit: pointer align == u64 align (8), so sorted alphabetically → model, state
/// On 32-bit WASM: pointer align (4) < u64 align (8), so sorted by align → state, model
pub const RenderArgs = if (@sizeOf(*anyopaque) == 4)
    extern struct {
        state: RocPlatformState, // 8-byte aligned (u64) comes first on 32-bit
        model: RocBox, // 4-byte aligned pointer comes second
    }
else
    extern struct {
        model: RocBox, // 8-byte aligned pointer
        state: RocPlatformState, // 8-byte aligned, "model" < "state" alphabetically
    };

// ============================================================================
// Drawing Types
// ============================================================================

/// Roc Rectangle type layout: { x, y, width, height: F32, color: Color }
/// Fields ordered by alignment (4 bytes for F32) then alphabetically, then 1-byte fields
pub const RocRectangle = extern struct {
    height: f32,
    width: f32,
    x: f32,
    y: f32,
    color: u8,
};

/// Roc Circle type layout: { center: Vector2, radius: F32, color: Color }
/// Fields ordered by alignment then alphabetically: center, radius, color
pub const RocCircle = extern struct {
    center: RocVector2,
    radius: f32,
    color: u8,
};

/// Roc Line type layout: { start: Vector2, end: Vector2, color: Color }
/// Fields ordered by alignment then alphabetically: end, start, color
pub const RocLine = extern struct {
    end: RocVector2,
    start: RocVector2,
    color: u8,
};

/// Roc Text type layout: { pos: Vector2, text: Str, size: I32, color: Color }
/// Fields ordered by alignment then alphabetically.
///
/// On 64-bit: RocStr is 8-byte aligned → text, pos, size, color
/// On 32-bit: RocStr is 4-byte aligned (same as pos, size) → pos, size, text, color
pub const RocText = if (@sizeOf(*anyopaque) == 4)
    extern struct {
        pos: RocVector2, // 4-byte align, "pos" < "size" < "text"
        size: i32,
        text: RocStr,
        color: u8,
    }
else
    extern struct {
        text: RocStr, // 8-byte align on 64-bit
        pos: RocVector2,
        size: i32,
        color: u8,
    };

// ============================================================================
// External Roc Functions (provided at link time)
// ============================================================================

pub extern fn roc__init_for_host(ops: *RocOps, ret_ptr: *Try_BoxModel_I64, arg_ptr: ?*anyopaque) callconv(.c) void;
pub extern fn roc__render_for_host(ops: *RocOps, ret_ptr: *Try_BoxModel_I64, args_ptr: *RenderArgs) callconv(.c) void;

// ============================================================================
// Color Mapping
// ============================================================================

/// Color tag union discriminant values (alphabetically sorted)
pub const Color = enum(u8) {
    Black = 0,
    Blue = 1,
    DarkGray = 2,
    Gray = 3,
    Green = 4,
    LightGray = 5,
    Orange = 6,
    Pink = 7,
    Purple = 8,
    RayWhite = 9,
    Red = 10,
    White = 11,
    Yellow = 12,
};
