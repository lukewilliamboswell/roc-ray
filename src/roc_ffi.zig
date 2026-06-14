//! Roc FFI utilities module.
//!
//! This module provides reusable components for Roc host implementations:
//! - Try: Generic result type matching Roc's Try layout (with helper methods)
//! - Keys/MouseButtons: input state managers for FFI with Roc
//!
//! All are designed to reduce boilerplate and improve type safety in host code.

const abi = @import("roc_platform_abi.zig");

// Re-export host helper context for convenience.
pub const RocHost = abi.RocHost;

/// Boxed value - opaque pointer to heap-allocated Roc data.
/// Nullable because ZST models (e.g. `Model : {}`) use null (box_of_zst).
///
/// The host never frees a box itself: box allocation headers depend on the
/// `Model` layout (a payload with refcounted fields uses a wider header), which
/// only the compiler knows. Hand the box back to Roc via `drop_model_for_host`.
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

/// Number of mouse buttons to track (raylib mouse button codes 0-6)
pub const MOUSE_BUTTON_COUNT: usize = 7;

/// Fixed-size byte state list manager for FFI with Roc.
/// Handles RocList allocation, refcounting, and data copying internally.
pub fn StateList(comptime COUNT: usize) type {
    return struct {
        list: abi.RocListWith(u8, false),
        roc_host: *RocHost,

        const Self = @This();

        /// Initialize state with a heap-allocated RocList.
        pub fn init(roc_host: *RocHost) Self {
            const list = abi.RocListWith(u8, false).allocate(COUNT, roc_host);
            if (list.elements_ptr) |elements| {
                @memset(elements[0..COUNT], 0);
            }
            return .{ .list = list, .roc_host = roc_host };
        }

        /// Update state from a fixed-size source array.
        pub fn update(self: *Self, source: *const [COUNT]u8) void {
            if (self.list.elements_ptr) |elements| {
                @memcpy(elements[0..COUNT], source);
            }
        }

        /// Increment refcount before passing to Roc (prevents Roc from freeing our list).
        pub fn incref(self: *Self) void {
            self.list.incref(1);
        }

        /// Decrement refcount / free the list (call on cleanup).
        pub fn decref(self: *Self) void {
            self.list.decref(self.roc_host);
        }
    };
}

/// Keyboard state manager.
pub const Keys = StateList(KEY_COUNT);

/// Mouse button state manager.
pub const MouseButtons = StateList(MOUSE_BUTTON_COUNT);

/// Flat state for init_for_host!/render_for_host!.
/// This is not the public nested `Host` record exposed to Roc apps.
pub const HostState = abi.__AnonStruct80;
