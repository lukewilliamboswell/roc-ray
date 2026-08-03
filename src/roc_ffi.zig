//! Roc FFI utilities module.
//!
//! This module provides reusable components for Roc host implementations:
//! - Try: Generic result type matching Roc's Try layout (with helper methods)
//! - Keys/MouseButtons: input state managers for FFI with Roc
//!
//! All are designed to reduce boilerplate and improve type safety in host code.

const std = @import("std");
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

/// Number of gamepads sampled into each Host snapshot.
pub const GAMEPAD_COUNT: usize = 4;

/// Number of raylib gamepad button codes (0-17).
pub const GAMEPAD_BUTTON_COUNT: usize = 18;

/// Number of raylib gamepad axes (0-5).
pub const GAMEPAD_AXIS_COUNT: usize = 6;

/// Held bit used by packed keyboard and mouse button state bytes.
pub const INPUT_HELD: u8 = 1;
/// Pressed-this-frame bit used by packed input state bytes.
pub const INPUT_PRESSED: u8 = 2;
/// Released-this-frame bit used by packed input state bytes.
pub const INPUT_RELEASED: u8 = 4;

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
        ///
        /// The host normally owns the list's only reference between callbacks,
        /// so the common path updates its allocation in place. If Roc retained
        /// an earlier frame snapshot, first move the host to a fresh allocation
        /// so the retained list remains immutable.
        pub fn update(self: *Self, source: *const [COUNT]u8) void {
            if (!self.list.isUnique()) {
                const retained_snapshot = self.list;
                self.list = abi.RocListWith(u8, false).allocate(COUNT, self.roc_host);
                retained_snapshot.decref(self.roc_host);
            }
            if (self.list.elements_ptr) |elements| {
                @memcpy(elements[0..COUNT], source);
            }
        }

        /// Check a packed state flag without crossing the host boundary again.
        pub fn hasFlag(self: *const Self, index: usize, flag: u8) bool {
            if (index >= COUNT) return false;
            const elements = self.list.elements_ptr orelse return false;
            return elements[index] & flag != 0;
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

/// Gamepad availability and packed button state managers.
pub const GamepadAvailability = StateList(GAMEPAD_COUNT);
/// Packed gamepad button state manager.
pub const GamepadButtons = StateList(GAMEPAD_COUNT * GAMEPAD_BUTTON_COUNT);

/// Fixed-size value list manager for non-byte input state such as axes.
pub fn ValueList(comptime T: type, comptime COUNT: usize) type {
    return struct {
        list: abi.RocListWith(T, false),
        roc_host: *RocHost,

        const Self = @This();

        pub fn init(roc_host: *RocHost) Self {
            const list = abi.RocListWith(T, false).allocate(COUNT, roc_host);
            if (list.elements_ptr) |elements| {
                @memset(elements[0..COUNT], 0);
            }
            return .{ .list = list, .roc_host = roc_host };
        }

        pub fn update(self: *Self, source: *const [COUNT]T) void {
            if (!self.list.isUnique()) {
                const retained_snapshot = self.list;
                self.list = abi.RocListWith(T, false).allocate(COUNT, self.roc_host);
                retained_snapshot.decref(self.roc_host);
            }
            if (self.list.elements_ptr) |elements| {
                @memcpy(elements[0..COUNT], source);
            }
        }

        pub fn incref(self: *Self) void {
            self.list.incref(1);
        }

        pub fn decref(self: *Self) void {
            self.list.decref(self.roc_host);
        }
    };
}

/// Sampled gamepad axis state manager.
pub const GamepadAxes = ValueList(f32, GAMEPAD_COUNT * GAMEPAD_AXIS_COUNT);

test "fixed input lists reuse unique storage and copy retained snapshots" {
    var env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.default() };
    var host = RocHost{
        .env = &env,
        .roc_alloc = &abi.DefaultAllocators.rocAlloc,
        .roc_dealloc = &abi.DefaultAllocators.rocDealloc,
        .roc_realloc = &abi.DefaultAllocators.rocRealloc,
        .roc_dbg = &abi.DefaultHandlers.rocDbg,
        .roc_expect_failed = &abi.DefaultHandlers.rocExpectFailed,
        .roc_crashed = &abi.DefaultHandlers.rocCrashed,
    };

    var state = StateList(2).init(&host);
    defer state.decref();
    const original_ptr = state.list.elements_ptr;
    state.update(&.{ 1, 2 });
    try std.testing.expectEqual(original_ptr, state.list.elements_ptr);

    const retained = state.list;
    retained.incref(1);
    defer retained.decref(&host);
    state.update(&.{ 3, 4 });
    try std.testing.expect(original_ptr != state.list.elements_ptr);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, retained.items());
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, state.list.items());
}

/// Flat state for init_for_host!/render_for_host!.
/// This is not the public nested `Host` record exposed to Roc apps.
pub const HostState = abi.Init_for_hostArg0;
