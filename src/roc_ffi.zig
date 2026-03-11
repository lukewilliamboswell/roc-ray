//! Roc FFI utilities module.
//!
//! This module provides reusable components for Roc host implementations:
//! - Try: Generic result type matching Roc's Try layout (with helper methods)
//! - Keys: Keyboard state manager for FFI with Roc
//! - Color helpers: Safe conversion between u8 discriminants and abi.Color
//!
//! All are designed to reduce boilerplate and improve type safety in host code.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");

// Re-export host ABI types for convenience
pub const RocOps = abi.RocOps;

/// Boxed value - opaque pointer to heap-allocated Roc data.
/// Nullable because ZST models (e.g. `Model : {}`) use null (box_of_zst).
pub const RocBox = ?*anyopaque;

/// Generic result type matching Roc's `Try` layout with helper methods.
/// Ok/Err variants share a union payload, followed by a 1-byte tag.
pub fn Try(comptime Ok: type, comptime Err: type) type {
    const OkField = if (@sizeOf(Ok) == 0) [0]u8 else Ok;
    const ErrField = if (@sizeOf(Err) == 0) [0]u8 else Err;
    return extern struct {
        payload: extern union { ok: OkField, err: ErrField },
        tag: Tag,

        pub const Tag = enum(u8) { Err = 0, Ok = 1 };
        const Self = @This();

        pub fn ok(value: OkField) Self {
            return .{ .payload = .{ .ok = value }, .tag = .Ok };
        }

        pub fn err(value: ErrField) Self {
            return .{ .payload = .{ .err = value }, .tag = .Err };
        }

        pub fn isOk(self: Self) bool {
            return self.tag == .Ok;
        }

        pub fn isErr(self: Self) bool {
            return self.tag == .Err;
        }

        pub fn getOk(self: Self) OkField {
            return self.payload.ok;
        }

        pub fn getErr(self: Self) ErrField {
            return self.payload.err;
        }
    };
}

/// Number of keyboard keys to track (raylib key codes 0-348)
pub const KEY_COUNT: usize = 349;

/// Keyboard state manager for FFI with Roc.
/// Handles RocList allocation, refcounting, and data copying internally.
pub const Keys = struct {
    list: abi.RocListWith(u8, false),
    roc_ops: *RocOps,

    /// Initialize keyboard state with heap-allocated RocList.
    pub fn init(roc_ops: *RocOps) Keys {
        const list = abi.RocListWith(u8, false).allocate(KEY_COUNT, roc_ops);
        // Initialize to zeros (all keys up)
        if (list.elements_ptr) |elements| {
            @memset(elements[0..KEY_COUNT], 0);
        }
        return .{ .list = list, .roc_ops = roc_ops };
    }

    /// Update keyboard state from a source array (e.g., from raylib).
    pub fn update(self: *Keys, source: *const [KEY_COUNT]u8) void {
        if (self.list.elements_ptr) |elements| {
            @memcpy(elements[0..KEY_COUNT], source);
        }
    }

    /// Increment refcount before passing to Roc (prevents Roc from freeing our list).
    pub fn incref(self: *Keys) void {
        self.list.incref(1);
    }

    /// Decrement refcount / free the list (call on cleanup).
    pub fn decref(self: *Keys) void {
        self.list.decref(self.roc_ops);
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
        state: abi.Host,
        model: RocBox,
    }
else
    extern struct {
        model: RocBox,
        state: abi.Host,
    };

/// Convert from raw u8 discriminant to abi.Color, returning white for invalid values.
pub fn colorFromU8(value: u8) abi.Color {
    return std.meta.intToEnum(abi.Color, value) catch .white;
}

/// Convert abi.Color to raw u8 discriminant.
pub fn colorToU8(color: abi.Color) u8 {
    return @intFromEnum(color);
}
