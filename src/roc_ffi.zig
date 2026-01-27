//! Roc FFI boundary module.
//!
//! This module isolates all unsafe Roc interop code in one place. It handles:
//! - Converting Roc ABI types to safe Zig types
//! - Memory management callbacks for Roc runtime
//! - Reference counting utilities
//!
//! This module is verified once and rarely modified. All @ptrCast/@alignCast
//! operations happen here, keeping the rest of the codebase type-safe.

const std = @import("std");
const builtins = @import("builtins");
const types = @import("types.zig");

/// Convert RocCircle pointer to safe Circle type.
/// The Roc ABI layout matches types.Circle.FFI exactly.
pub fn circleFromRoc(ptr: *anyopaque) types.Circle {
    const ffi: *const types.Circle.FFI = @ptrCast(@alignCast(ptr));
    return ffi.toCircle();
}

/// Convert RocRectangle pointer to safe Rectangle type.
/// The Roc ABI layout matches types.Rectangle.FFI exactly.
pub fn rectangleFromRoc(ptr: *anyopaque) types.Rectangle {
    const ffi: *const types.Rectangle.FFI = @ptrCast(@alignCast(ptr));
    return ffi.toRectangle();
}

/// Convert RocLine pointer to safe Line type.
/// The Roc ABI layout matches types.Line.FFI exactly.
pub fn lineFromRoc(ptr: *anyopaque) types.Line {
    const ffi: *const types.Line.FFI = @ptrCast(@alignCast(ptr));
    return ffi.toLine();
}

/// Convert RocRectangleGradientV pointer to safe RectangleGradientV type.
/// The Roc ABI layout matches types.RectangleGradientV.FFI exactly.
pub fn rectangleGradientVFromRoc(ptr: *anyopaque) types.RectangleGradientV {
    const ffi: *const types.RectangleGradientV.FFI = @ptrCast(@alignCast(ptr));
    return ffi.toRectangleGradientV();
}

/// Convert RocRectangleGradientH pointer to safe RectangleGradientH type.
/// The Roc ABI layout matches types.RectangleGradientH.FFI exactly.
pub fn rectangleGradientHFromRoc(ptr: *anyopaque) types.RectangleGradientH {
    const ffi: *const types.RectangleGradientH.FFI = @ptrCast(@alignCast(ptr));
    return ffi.toRectangleGradientH();
}

/// Convert RocCircleGradient pointer to safe CircleGradient type.
/// The Roc ABI layout matches types.CircleGradient.FFI exactly.
pub fn circleGradientFromRoc(ptr: *anyopaque) types.CircleGradient {
    const ffi: *const types.CircleGradient.FFI = @ptrCast(@alignCast(ptr));
    return ffi.toCircleGradient();
}

/// Convert RocText pointer to safe Text type.
/// Note: The returned Text.content is a slice into the RocStr's data,
/// which is only valid while the RocStr is live.
/// Text FFI layout is platform-dependent.
pub fn textFromRoc(ptr: *anyopaque) types.Text {
    const ffi: *const types.Text.FFI = @ptrCast(@alignCast(ptr));
    return .{
        .pos = .{ .x = ffi.pos.x, .y = ffi.pos.y },
        .content = ffi.text.asSlice(),
        .size = ffi.size,
        .color = types.Color.fromU8(ffi.color) orelse .white,
    };
}

// Memory Management

/// Create memory management callbacks parameterized by an allocator getter.
/// The getAllocator function is called to get the allocator for each operation,
/// allowing different hosts to provide different allocator sources.
pub fn RocMemory(comptime getAllocator: fn (env: *anyopaque) std.mem.Allocator) type {
    return struct {
        /// Roc allocation function with size-tracking metadata.
        pub fn alloc(roc_alloc: *builtins.host_abi.RocAlloc, env: *anyopaque) callconv(.c) void {
            const allocator = getAllocator(env);

            const min_alignment: usize = @max(roc_alloc.alignment, @alignOf(usize));
            const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);

            // Calculate additional bytes needed to store the size
            const size_storage_bytes = @max(roc_alloc.alignment, @alignOf(usize));
            const total_size = roc_alloc.length + size_storage_bytes;

            // Allocate memory including space for size metadata
            const result = allocator.rawAlloc(total_size, align_enum, @returnAddress());

            const base_ptr = result orelse {
                const stderr: std.fs.File = .stderr();
                stderr.writeAll("\x1b[31mHost error:\x1b[0m allocation failed, out of memory\n") catch {};
                std.process.exit(1);
            };

            // Store the total size (including metadata) right before the user data
            const size_ptr: *usize = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes - @sizeOf(usize));
            size_ptr.* = total_size;

            // Return pointer to the user data (after the size metadata)
            roc_alloc.answer = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes);
        }

        /// Roc deallocation function with size-tracking metadata.
        pub fn dealloc(roc_dealloc: *builtins.host_abi.RocDealloc, env: *anyopaque) callconv(.c) void {
            const allocator = getAllocator(env);

            // Calculate where the size metadata is stored
            const size_storage_bytes = @max(roc_dealloc.alignment, @alignOf(usize));
            const size_ptr: *const usize = @ptrFromInt(@intFromPtr(roc_dealloc.ptr) - @sizeOf(usize));

            // Read the total size from metadata
            const total_size = size_ptr.*;

            // Calculate the base pointer (start of actual allocation)
            const base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(roc_dealloc.ptr) - size_storage_bytes);

            // Calculate alignment
            const min_alignment: usize = @max(roc_dealloc.alignment, @alignOf(usize));
            const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);

            // Free the memory (including the size metadata)
            const slice = @as([*]u8, @ptrCast(base_ptr))[0..total_size];
            allocator.rawFree(slice, align_enum, @returnAddress());
        }

        /// Roc reallocation function with size-tracking metadata.
        pub fn realloc(roc_realloc: *builtins.host_abi.RocRealloc, env: *anyopaque) callconv(.c) void {
            const allocator = getAllocator(env);

            // Calculate alignment
            const min_alignment: usize = @max(roc_realloc.alignment, @alignOf(usize));
            const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);

            // Calculate where the size metadata is stored for the old allocation
            const size_storage_bytes = min_alignment;
            const old_size_ptr: *const usize = @ptrFromInt(@intFromPtr(roc_realloc.answer) - @sizeOf(usize));

            // Read the old total size from metadata
            const old_total_size = old_size_ptr.*;

            // Calculate the old base pointer (start of actual allocation)
            const old_base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(roc_realloc.answer) - size_storage_bytes);

            // Calculate new total size needed
            const new_total_size = roc_realloc.new_length + size_storage_bytes;

            // Allocate new memory with proper alignment
            const new_base_ptr = allocator.rawAlloc(new_total_size, align_enum, @returnAddress()) orelse {
                const stderr: std.fs.File = .stderr();
                stderr.writeAll("\x1b[31mHost error:\x1b[0m reallocation failed, out of memory\n") catch {};
                std.process.exit(1);
            };

            // Copy old data to new allocation (excluding metadata, just user data)
            const old_user_data_size = old_total_size - size_storage_bytes;
            const copy_size = @min(old_user_data_size, roc_realloc.new_length);
            const new_user_ptr: [*]u8 = @ptrFromInt(@intFromPtr(new_base_ptr) + size_storage_bytes);
            const old_user_ptr: [*]const u8 = @ptrCast(roc_realloc.answer);
            @memcpy(new_user_ptr, old_user_ptr[0..copy_size]);

            // Free old allocation
            const old_slice = old_base_ptr[0..old_total_size];
            allocator.rawFree(old_slice, align_enum, @returnAddress());

            // Store the new total size in the metadata
            const new_size_ptr: *usize = @ptrFromInt(@intFromPtr(new_base_ptr) + size_storage_bytes - @sizeOf(usize));
            new_size_ptr.* = new_total_size;

            // Return pointer to the user data (after the size metadata)
            roc_realloc.answer = new_user_ptr;
        }
    };
}

/// Decrement the reference count of a RocBox.
/// If the refcount reaches zero, the memory is freed.
pub fn decrefRocBox(box: types.RocBox, roc_ops: *types.RocOps) void {
    const ptr: ?[*]u8 = @ptrCast(box);
    // Box alignment is pointer-width, elements are not refcounted at this level
    builtins.utils.decrefDataPtrC(ptr, @alignOf(usize), false, roc_ops);
}

// Tests for FFI conversion functions are in types.zig
// This module's tests focus on the pointer conversion functions
