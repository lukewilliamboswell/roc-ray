//! Roc FFI utilities module.
//!
//! This module provides reusable components for Roc host implementations:
//! - wrapHostedFn: Type-safe wrapper for hosted function callbacks
//! - RocMemory: Memory management callbacks (alloc, dealloc, realloc)
//! - RocCallbacks: Debug/expect/crash callbacks with stderr output
//!
//! All are designed to reduce boilerplate and improve type safety in host code.

const std = @import("std");
const builtins = @import("builtins");

// Re-export host ABI types for convenience
pub const RocOps = builtins.host_abi.RocOps;
pub const HostedFn = builtins.host_abi.HostedFn;
pub const RocDbg = builtins.host_abi.RocDbg;
pub const RocExpectFailed = builtins.host_abi.RocExpectFailed;
pub const RocCrashed = builtins.host_abi.RocCrashed;

/// Unit type for hosted functions with no arguments.
pub const NoArgs = extern struct {};

/// Unit type for hosted functions with no return value.
pub const NoReturn = extern struct {};

/// Wraps a typed hosted function into the HostedFn signature (which uses *anyopaque).
/// This allows writing hosted functions with explicit typed parameters for clarity.
///
/// The function can receive either:
/// - `*RocOps` as first param: ops is passed directly (for functions needing allocation)
/// - Any other pointer type: ops.env is cast to that type (for functions needing host env)
///
/// Example with typed env:
/// ```
/// fn hostedDrawCircle(host: *HostEnv, _: *ffi.NoReturn, args: *const Circle.FFI) void { ... }
/// ```
///
/// Example with RocOps (for string allocation):
/// ```
/// fn hostedReadEnv(ops: *RocOps, result: *Try_Str_NotFound, args: *const ReadEnvArgs) void { ... }
/// ```
pub fn wrapHostedFn(comptime func: anytype) HostedFn {
    const FnInfo = @typeInfo(@TypeOf(func)).@"fn";
    const FirstParamType = FnInfo.params[0].type.?;
    const RetType = FnInfo.params[1].type.?;
    const ArgsType = FnInfo.params[2].type.?;

    // Check if first param is *RocOps (pass ops directly) or something else (cast ops.env)
    const pass_ops_directly = (FirstParamType == *RocOps);

    return struct {
        fn wrapper(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
            const first_arg = if (pass_ops_directly)
                ops
            else
                @as(FirstParamType, @ptrCast(@alignCast(ops.env)));
            const result: RetType = @ptrCast(@alignCast(ret_ptr));
            const args: ArgsType = @ptrCast(@alignCast(args_ptr));
            @call(.auto, func, .{ first_arg, result, args });
        }
    }.wrapper;
}

/// Create debug/expect/crash callbacks that write to stderr with ANSI colors.
/// Optionally tracks when dbg or expect_failed is called via a flag getter function.
///
/// Usage:
/// ```
/// var debug_flag: std.atomic.Value(bool) = .init(false);
/// fn getDebugFlag() *std.atomic.Value(bool) { return &debug_flag; }
/// const Callbacks = ffi.RocCallbacks(getDebugFlag);
/// // Use Callbacks.dbg, Callbacks.expectFailed, Callbacks.crashed
/// ```
///
/// Pass `null` for getDebugFlag if you don't need to track debug/expect calls.
pub fn RocCallbacks(comptime getDebugFlag: ?fn () *std.atomic.Value(bool)) type {
    return struct {
        /// Roc debug callback - prints message to stderr with yellow "dbg:" prefix.
        pub fn dbg(roc_dbg: *const RocDbg, env: *anyopaque) callconv(.c) void {
            _ = env;
            if (getDebugFlag) |getter| getter().store(true, .release);
            const message = roc_dbg.utf8_bytes[0..roc_dbg.len];
            const stderr: std.fs.File = .stderr();
            stderr.writeAll("\x1b[33mdbg:\x1b[0m ") catch {};
            stderr.writeAll(message) catch {};
            stderr.writeAll("\n") catch {};
        }

        /// Roc expect failed callback - prints message to stderr with yellow "expect failed:" prefix.
        pub fn expectFailed(roc_expect: *const RocExpectFailed, env: *anyopaque) callconv(.c) void {
            _ = env;
            if (getDebugFlag) |getter| getter().store(true, .release);
            const source_bytes = roc_expect.utf8_bytes[0..roc_expect.len];
            const trimmed = std.mem.trim(u8, source_bytes, " \t\n\r");
            const stderr: std.fs.File = .stderr();
            stderr.writeAll("\x1b[33mexpect failed:\x1b[0m ") catch {};
            stderr.writeAll(trimmed) catch {};
            stderr.writeAll("\n") catch {};
        }

        /// Roc crashed callback - prints message to stderr with red "Roc crashed:" prefix and exits.
        pub fn crashed(roc_crashed: *const RocCrashed, env: *anyopaque) callconv(.c) noreturn {
            _ = env;
            const message = roc_crashed.utf8_bytes[0..roc_crashed.len];
            const stderr: std.fs.File = .stderr();
            var buf: [256]u8 = undefined;
            var w = stderr.writer(&buf);
            w.interface.print("\n\x1b[31mRoc crashed:\x1b[0m {s}\n", .{message}) catch {};
            w.interface.flush() catch {};
            std.process.exit(1);
        }
    };
}

/// Configuration for RocMemory callbacks.
pub const RocMemoryConfig = struct {
    /// Function to get allocator from env pointer.
    getAllocator: *const fn (env: *anyopaque) std.mem.Allocator,

    /// OOM handler - called when allocation fails. Must not return.
    onOOM: *const fn () noreturn,

    /// Optional telemetry: called after successful allocation with user bytes.
    onAlloc: ?*const fn (bytes: usize) void = null,

    /// Optional telemetry: called after deallocation with user bytes freed.
    onDealloc: ?*const fn (bytes: usize) void = null,

    /// Optional telemetry: called after reallocation with old and new user bytes.
    onRealloc: ?*const fn (old_bytes: usize, new_bytes: usize) void = null,
};

/// Create memory management callbacks with configurable allocator, OOM handling, and telemetry.
pub fn RocMemory(comptime config: RocMemoryConfig) type {
    return struct {
        /// Roc allocation function with size-tracking metadata.
        pub fn alloc(roc_alloc: *builtins.host_abi.RocAlloc, env: *anyopaque) callconv(.c) void {
            const allocator = config.getAllocator(env);

            const min_alignment: usize = @max(roc_alloc.alignment, @alignOf(usize));
            const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);

            // Calculate additional bytes needed to store the size
            const size_storage_bytes = @max(roc_alloc.alignment, @alignOf(usize));
            const total_size = roc_alloc.length + size_storage_bytes;

            // Allocate memory including space for size metadata
            const base_ptr = allocator.rawAlloc(total_size, align_enum, @returnAddress()) orelse {
                config.onOOM();
            };

            // Store the total size (including metadata) right before the user data
            const size_ptr: *usize = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes - @sizeOf(usize));
            size_ptr.* = total_size;

            // Track telemetry if configured
            if (config.onAlloc) |onAlloc| onAlloc(roc_alloc.length);

            // Return pointer to the user data (after the size metadata)
            roc_alloc.answer = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes);
        }

        /// Roc deallocation function with size-tracking metadata.
        pub fn dealloc(roc_dealloc: *builtins.host_abi.RocDealloc, env: *anyopaque) callconv(.c) void {
            const allocator = config.getAllocator(env);

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

            // Track telemetry if configured (user bytes = total - metadata)
            if (config.onDealloc) |onDealloc| onDealloc(total_size - size_storage_bytes);

            // Free the memory (including the size metadata)
            const slice = @as([*]u8, @ptrCast(base_ptr))[0..total_size];
            allocator.rawFree(slice, align_enum, @returnAddress());
        }

        /// Roc reallocation function with size-tracking metadata.
        pub fn realloc(roc_realloc: *builtins.host_abi.RocRealloc, env: *anyopaque) callconv(.c) void {
            const allocator = config.getAllocator(env);

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
                config.onOOM();
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

            // Track telemetry if configured
            if (config.onRealloc) |onRealloc| onRealloc(old_user_data_size, roc_realloc.new_length);

            // Return pointer to the user data (after the size metadata)
            roc_realloc.answer = new_user_ptr;
        }
    };
}
