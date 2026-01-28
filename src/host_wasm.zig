//! WASM platform host for roc-ray uses a command buffer assumes rendering for a Canvas 2D context.
//!
//! This file is used for WASM builds, but also compiled natively for unit testing.
//!
//! Architecture:
//! - This host handles Roc FFI, memory callbacks, and WASM exports
//! - The command buffer backend (backend/wasm.zig) handles draw buffering
//! - JavaScript reads the command buffer after each frame

const std = @import("std");
const builtin = @import("builtin");
const wasm = @import("backend/wasm.zig");
const ffi = @import("roc_ffi.zig");

pub const CommandBuffer = wasm.CommandBuffer;
pub const MAX_COMMANDS = wasm.MAX_COMMANDS;
pub const MAX_RECTS = wasm.MAX_RECTS;
pub const MAX_CIRCLES = wasm.MAX_CIRCLES;
pub const MAX_LINES = wasm.MAX_LINES;
pub const MAX_TEXTS = wasm.MAX_TEXTS;
pub const MAX_STRING_BYTES = wasm.MAX_STRING_BYTES;
pub const CMD_RECT = wasm.CMD_RECT;
pub const CMD_CIRCLE = wasm.CMD_CIRCLE;
pub const CMD_LINE = wasm.CMD_LINE;
pub const CMD_TEXT = wasm.CMD_TEXT;

const types = @import("types.zig");
const RocBox = types.RocBox;
const RocHostState = types.InputState.FFI;
const RocRectangle = types.Rectangle.FFI; // Used in tests
const Try_BoxModel_I64 = types.Try_BoxModel_I64;
const RenderArgs = types.RenderArgs;
const RocOps = types.RocOps;
const HostedFn = types.HostedFn;
const RocAlloc = types.RocAlloc;
const RocDealloc = types.RocDealloc;
const RocRealloc = types.RocRealloc;
const RocDbg = types.RocDbg;
const RocExpectFailed = types.RocExpectFailed;
const RocCrashed = types.RocCrashed;

// Roc functions: extern on WASM (provided by Roc compiler), stubs on native (for testing)
const roc__init_for_host = if (builtin.cpu.arch == .wasm32)
    types.roc__init_for_host
else
    stubRocInit;

const roc__render_for_host = if (builtin.cpu.arch == .wasm32)
    types.roc__render_for_host
else
    stubRocRender;

// Native stubs (only used during unit testing, not in production)
fn stubRocInit(_: *RocOps, _: *Try_BoxModel_I64, _: ?*anyopaque) callconv(.c) void {}
fn stubRocRender(_: *RocOps, _: *Try_BoxModel_I64, _: *RenderArgs) callconv(.c) void {}

// Allocation telemetry - track allocations for leak detection
// JS can read these via exported getters and log them to detect memory leaks over time
var alloc_count: u64 = 0;
var dealloc_count: u64 = 0;
var realloc_count: u64 = 0;
var bytes_allocated: u64 = 0;
var bytes_freed: u64 = 0;

// App State
var app_model: RocBox = undefined;
var app_initialized: bool = false; // Track if init has been called (model can be ptr 0 for empty records)
var frame_count: u64 = 0;

// Dummy env for RocOps (not used by web host, but must be valid pointer)
var dummy_env: u8 = 0;

// Conditional allocator: WASM uses wasm_allocator, native uses page_allocator (for testing)
const allocator_vtable = if (builtin.cpu.arch == .wasm32)
    std.heap.wasm_allocator.vtable
else
    std.heap.page_allocator.vtable;

// RocOps callback implementations
fn rocAllocFn(args: *RocAlloc, env: *anyopaque) callconv(.c) void {
    _ = env;

    const align_enum = std.mem.Alignment.fromByteUnits(args.alignment);

    // Calculate additional bytes needed to store the size
    const size_storage_bytes = @max(args.alignment, @alignOf(usize));
    const total_size = args.length + size_storage_bytes;

    // Allocate memory including space for size metadata
    const base_ptr = allocator_vtable.alloc(undefined, total_size, align_enum, @returnAddress()) orelse {
        js_throw_error("Out of memory during rocAlloc", 29);
    };

    // Store the total size (including metadata) right before the user data
    const size_ptr: *usize = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes - @sizeOf(usize));
    size_ptr.* = total_size;

    // Track allocation telemetry
    alloc_count += 1;
    bytes_allocated += args.length;

    // Return pointer to the user data (after the size metadata)
    args.answer = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes);
}

fn rocDeallocFn(args: *RocDealloc, env: *anyopaque) callconv(.c) void {
    _ = env;

    // Calculate where the size metadata is stored
    const size_storage_bytes = @max(args.alignment, @alignOf(usize));
    const size_ptr: *const usize = @ptrFromInt(@intFromPtr(args.ptr) - @sizeOf(usize));

    // Read the total size from metadata
    const total_size = size_ptr.*;

    // Calculate the base pointer (start of actual allocation)
    const base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(args.ptr) - size_storage_bytes);

    // Calculate alignment
    const log2_align = std.math.log2_int(u29, @intCast(args.alignment));
    const align_enum: std.mem.Alignment = @enumFromInt(log2_align);

    // Track deallocation telemetry (user bytes = total - metadata)
    const user_bytes = total_size - size_storage_bytes;
    dealloc_count += 1;
    bytes_freed += user_bytes;

    // Free the memory (including the size metadata)
    const slice = base_ptr[0..total_size];
    allocator_vtable.free(undefined, slice, align_enum, @returnAddress());
}

fn rocReallocFn(args: *RocRealloc, env: *anyopaque) callconv(.c) void {
    _ = env;

    // Calculate where the size metadata is stored for the old allocation
    const size_storage_bytes = @max(args.alignment, @alignOf(usize));
    const old_size_ptr: *const usize = @ptrFromInt(@intFromPtr(args.answer) - @sizeOf(usize));

    // Read the old total size from metadata
    const old_total_size = old_size_ptr.*;
    const old_user_bytes = old_total_size - size_storage_bytes;

    // Calculate the old base pointer (start of actual allocation)
    const old_base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(args.answer) - size_storage_bytes);

    // Calculate new total size needed
    const new_total_size = args.new_length + size_storage_bytes;

    // Perform reallocation
    const old_slice = old_base_ptr[0..old_total_size];
    const log2_align = std.math.log2_int(u29, @intCast(args.alignment));
    const align_enum: std.mem.Alignment = @enumFromInt(log2_align);

    const new_base_ptr = allocator_vtable.remap(undefined, old_slice, align_enum, new_total_size, @returnAddress()) orelse {
        // remap failed, keep old pointer
        return;
    };

    // Track reallocation telemetry
    realloc_count += 1;
    // Adjust bytes: freed old user bytes, allocated new user bytes
    bytes_freed += old_user_bytes;
    bytes_allocated += args.new_length;

    // Store the new total size in the metadata
    const new_size_ptr: *usize = @ptrFromInt(@intFromPtr(new_base_ptr) + size_storage_bytes - @sizeOf(usize));
    new_size_ptr.* = new_total_size;

    // Return pointer to the user data (after the size metadata)
    args.answer = @ptrFromInt(@intFromPtr(new_base_ptr) + size_storage_bytes);
}

// Exported allocation functions (Roc imports these at link time)

export fn roc_alloc(size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const align_enum = std.mem.Alignment.fromByteUnits(alignment);
    const size_storage_bytes = @max(alignment, @alignOf(usize));
    const total_size = size + size_storage_bytes;

    const base_ptr = allocator_vtable.alloc(undefined, total_size, align_enum, @returnAddress()) orelse {
        return null;
    };

    const size_ptr: *usize = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes - @sizeOf(usize));
    size_ptr.* = total_size;

    // Track allocation telemetry
    alloc_count += 1;
    bytes_allocated += size;

    return @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes);
}

export fn roc_dealloc(ptr: [*]u8, alignment: u32) callconv(.c) void {
    const size_storage_bytes = @max(alignment, @alignOf(usize));
    const size_ptr: *const usize = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize));
    const total_size = size_ptr.*;

    const base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - size_storage_bytes);

    const log2_align = std.math.log2_int(u29, @intCast(alignment));
    const align_enum: std.mem.Alignment = @enumFromInt(log2_align);

    // Track deallocation telemetry
    const user_bytes = total_size - size_storage_bytes;
    dealloc_count += 1;
    bytes_freed += user_bytes;

    const slice = base_ptr[0..total_size];
    allocator_vtable.free(undefined, slice, align_enum, @returnAddress());
}

export fn roc_realloc(ptr: [*]u8, new_size: usize, _: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const size_storage_bytes = @max(alignment, @alignOf(usize));
    const old_size_ptr: *const usize = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize));
    const old_total_size = old_size_ptr.*;
    const old_user_bytes = old_total_size - size_storage_bytes;
    const old_base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - size_storage_bytes);

    const new_total_size = new_size + size_storage_bytes;
    const old_slice = old_base_ptr[0..old_total_size];
    const log2_align = std.math.log2_int(u29, @intCast(alignment));
    const align_enum: std.mem.Alignment = @enumFromInt(log2_align);

    const new_base_ptr = allocator_vtable.remap(undefined, old_slice, align_enum, new_total_size, @returnAddress()) orelse {
        return null;
    };

    // Track reallocation telemetry
    realloc_count += 1;
    bytes_freed += old_user_bytes;
    bytes_allocated += new_size;

    const new_size_ptr: *usize = @ptrFromInt(@intFromPtr(new_base_ptr) + size_storage_bytes - @sizeOf(usize));
    new_size_ptr.* = new_total_size;

    return @ptrFromInt(@intFromPtr(new_base_ptr) + size_storage_bytes);
}

// JavaScript imports (extern on WASM, stubs on native for testing)
fn js_console_log(ptr: [*]const u8, len: usize) void {
    if (builtin.cpu.arch == .wasm32) {
        const extern_log = @extern(*const fn ([*]const u8, usize) callconv(.c) void, .{ .name = "js_console_log" });
        extern_log(ptr, len);
    } else {
        std.debug.print("{s}\n", .{ptr[0..len]});
    }
}

fn js_throw_error(ptr: [*]const u8, len: usize) noreturn {
    if (builtin.cpu.arch == .wasm32) {
        const extern_throw = @extern(*const fn ([*]const u8, usize) callconv(.c) noreturn, .{ .name = "js_throw_error" });
        extern_throw(ptr, len);
    } else {
        std.debug.panic("Error: {s}", .{ptr[0..len]});
    }
}

// RocOps callback implementations
fn rocDbgFn(dbg_info: *const RocDbg, env: *anyopaque) callconv(.c) void {
    _ = env;
    js_console_log(dbg_info.utf8_bytes, dbg_info.len);
}

fn rocExpectFailedFn(roc_expect: *const RocExpectFailed, env: *anyopaque) callconv(.c) void {
    _ = env;
    js_console_log(roc_expect.utf8_bytes, roc_expect.len);
}

fn rocCrashedFn(roc_crashed: *const RocCrashed, env: *anyopaque) callconv(.c) noreturn {
    _ = env;
    js_throw_error(roc_crashed.utf8_bytes, roc_crashed.len);
}

// Exported debug for roc to link
export fn roc_dbg(loc_ptr: [*]const u8, loc_len: usize, msg_ptr: [*]const u8, msg_len: usize) callconv(.c) void {
    // Log location if provided
    if (loc_len > 0) {
        js_console_log(loc_ptr, loc_len);
    }
    // Log message
    js_console_log(msg_ptr, msg_len);
}

// Exported panic for roc to link
export fn roc_panic(msg_ptr: [*]const u8, msg_len: usize) callconv(.c) noreturn {
    js_throw_error(msg_ptr, msg_len);
}

fn hostedDrawBeginFrame(_: *RocOps, _: *anyopaque, _: *anyopaque) callconv(.c) void {
    wasm.beginDrawing();
}

fn hostedDrawClear(_: *RocOps, _: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const color_discriminant: *const u8 = @ptrCast(args_ptr);
    const color = types.Color.fromU8Safe(color_discriminant.*);
    wasm.clearBackground(color);
}

fn hostedDrawCircle(_: *RocOps, _: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const circle = ffi.circleFromRoc(args_ptr);
    wasm.drawCircle(circle);
}

fn hostedDrawCircleGradient(_: *RocOps, _: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const cg = ffi.circleGradientFromRoc(args_ptr);
    wasm.drawCircleGradient(cg);
}

fn hostedDrawEndFrame(_: *RocOps, _: *anyopaque, _: *anyopaque) callconv(.c) void {
    wasm.endDrawing();
}

fn hostedDrawLine(_: *RocOps, _: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const line = ffi.lineFromRoc(args_ptr);
    wasm.drawLine(line);
}

fn hostedDrawRectangle(_: *RocOps, _: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const rect = ffi.rectangleFromRoc(args_ptr);
    wasm.drawRectangle(rect);
}

fn hostedDrawRectangleGradientH(_: *RocOps, _: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const rg = ffi.rectangleGradientHFromRoc(args_ptr);
    wasm.drawRectangleGradientH(rg);
}

fn hostedDrawRectangleGradientV(_: *RocOps, _: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const rg = ffi.rectangleGradientVFromRoc(args_ptr);
    wasm.drawRectangleGradientV(rg);
}

fn hostedDrawText(_: *RocOps, _: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const text = ffi.textFromRoc(args_ptr);
    var buf: [256:0]u8 = undefined;
    wasm.drawText(text, &buf);
}

fn hostedReadEnv(_: *RocOps, ret_ptr: *anyopaque, _: *anyopaque) callconv(.c) void {
    // WASM doesn't have environment variables - always return NotFound
    const result: *types.Try_Str_NotFound = @ptrCast(@alignCast(ret_ptr));
    result.* = types.Try_Str_NotFound.notFound();
}

/// Hosted function pointers (alphabetical order by fully-qualified name)
const hosted_function_ptrs = [_]HostedFn{
    hostedDrawBeginFrame, // Draw.begin_frame! (0)
    hostedDrawCircle, // Draw.circle! (1)
    hostedDrawCircleGradient, // Draw.circle_gradient! (2)
    hostedDrawClear, // Draw.clear! (3)
    hostedDrawEndFrame, // Draw.end_frame! (4)
    hostedDrawLine, // Draw.line! (5)
    hostedDrawRectangle, // Draw.rectangle! (6)
    hostedDrawRectangleGradientH, // Draw.rectangle_gradient_h! (7)
    hostedDrawRectangleGradientV, // Draw.rectangle_gradient_v! (8)
    hostedDrawText, // Draw.text! (9)
    hostedReadEnv, // Host.read_env! (10)
};

fn makeRocOps() RocOps {
    return RocOps{
        .env = @ptrCast(&dummy_env),
        .roc_alloc = rocAllocFn,
        .roc_dealloc = rocDeallocFn,
        .roc_realloc = rocReallocFn,
        .roc_dbg = rocDbgFn,
        .roc_expect_failed = rocExpectFailedFn,
        .roc_crashed = rocCrashedFn,
        .hosted_fns = .{
            .count = hosted_function_ptrs.len,
            .fns = @constCast(&hosted_function_ptrs),
        },
    };
}

/// Initialize the app - call once at startup
export fn _init() void {
    var roc_ops = makeRocOps();
    var result: Try_BoxModel_I64 = undefined;
    // Create initial host state for init (frame 0, no input)
    var init_state = types.InputState.FFI{
        .frame_count = 0,
        .mouse_wheel = 0,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_left = false,
        .mouse_right = false,
        .mouse_middle = false,
    };
    roc__init_for_host(&roc_ops, &result, @ptrCast(&init_state));

    if (result.isOk()) {
        app_model = result.getModel();
        app_initialized = true;
    }
}

/// Run one frame - call each animation frame
export fn _frame(mouse_x: f32, mouse_y: f32, buttons: u32, wheel: f32) void {
    if (!app_initialized) return;

    var roc_ops = makeRocOps();
    const platform_state = RocHostState{
        .frame_count = frame_count,
        .mouse_x = mouse_x,
        .mouse_y = mouse_y,
        .mouse_left = (buttons & 1) != 0,
        .mouse_middle = (buttons & 4) != 0,
        .mouse_right = (buttons & 2) != 0,
        .mouse_wheel = wheel,
    };

    var result: Try_BoxModel_I64 = undefined;
    var args = RenderArgs{ .model = app_model, .state = platform_state };
    roc__render_for_host(&roc_ops, &result, &args);

    // Update model for next frame (same as native host - no decref between frames)
    if (result.isOk()) {
        app_model = result.getModel();
    }
    frame_count += 1;
}

/// Get pointer to command buffer for JS to read
export fn _get_cmd_buffer_ptr() *CommandBuffer {
    return wasm.getBuffer();
}

/// Test function callable from JS - exercises draw commands without Roc
export fn _test_draw_commands() u32 {
    const buf = wasm.getBuffer();
    buf.reset();

    // Clear with blue
    wasm.clearBackground(.blue);

    // Rectangle at (10, 10), size 100x50, red
    wasm.drawRectangle(.{ .x = 10, .y = 10, .width = 100, .height = 50, .color = .red });

    // Circle at (200, 100), radius 30, green
    wasm.drawCircle(.{ .center = types.Vector2.init(200, 100), .radius = 30, .color = .green });

    // Line from (300, 10) to (400, 100), yellow
    wasm.drawLine(.{ .start = types.Vector2.init(300, 10), .end = types.Vector2.init(400, 100), .color = .yellow });

    // Text "Test" at (10, 200), size 32, white
    var text_buf: [256:0]u8 = undefined;
    wasm.drawText(.{ .pos = types.Vector2.init(10, 200), .content = "Test", .size = 32, .color = .white }, &text_buf);

    return buf.cmd_count;
}

/// Export struct offsets for JS to calculate buffer layout
export fn _get_offset_has_clear() usize {
    return @offsetOf(CommandBuffer, "has_clear");
}
export fn _get_offset_clear_color() usize {
    return @offsetOf(CommandBuffer, "clear_color");
}
export fn _get_offset_cmd_stream() usize {
    return @offsetOf(CommandBuffer, "cmd_stream");
}
export fn _get_offset_cmd_count() usize {
    return @offsetOf(CommandBuffer, "cmd_count");
}
export fn _get_offset_rect_count() usize {
    return @offsetOf(CommandBuffer, "rect_count");
}
export fn _get_offset_rect_x() usize {
    return @offsetOf(CommandBuffer, "rect_x");
}
export fn _get_offset_rect_y() usize {
    return @offsetOf(CommandBuffer, "rect_y");
}
export fn _get_offset_rect_w() usize {
    return @offsetOf(CommandBuffer, "rect_w");
}
export fn _get_offset_rect_h() usize {
    return @offsetOf(CommandBuffer, "rect_h");
}
export fn _get_offset_rect_color() usize {
    return @offsetOf(CommandBuffer, "rect_color");
}
export fn _get_offset_circle_count() usize {
    return @offsetOf(CommandBuffer, "circle_count");
}
export fn _get_offset_circle_x() usize {
    return @offsetOf(CommandBuffer, "circle_x");
}
export fn _get_offset_circle_y() usize {
    return @offsetOf(CommandBuffer, "circle_y");
}
export fn _get_offset_circle_radius() usize {
    return @offsetOf(CommandBuffer, "circle_radius");
}
export fn _get_offset_circle_color() usize {
    return @offsetOf(CommandBuffer, "circle_color");
}
export fn _get_offset_line_count() usize {
    return @offsetOf(CommandBuffer, "line_count");
}
export fn _get_offset_line_x1() usize {
    return @offsetOf(CommandBuffer, "line_x1");
}
export fn _get_offset_line_y1() usize {
    return @offsetOf(CommandBuffer, "line_y1");
}
export fn _get_offset_line_x2() usize {
    return @offsetOf(CommandBuffer, "line_x2");
}
export fn _get_offset_line_y2() usize {
    return @offsetOf(CommandBuffer, "line_y2");
}
export fn _get_offset_line_color() usize {
    return @offsetOf(CommandBuffer, "line_color");
}
export fn _get_offset_text_count() usize {
    return @offsetOf(CommandBuffer, "text_count");
}
export fn _get_offset_text_x() usize {
    return @offsetOf(CommandBuffer, "text_x");
}
export fn _get_offset_text_y() usize {
    return @offsetOf(CommandBuffer, "text_y");
}
export fn _get_offset_text_size() usize {
    return @offsetOf(CommandBuffer, "text_size");
}
export fn _get_offset_text_color() usize {
    return @offsetOf(CommandBuffer, "text_color");
}
export fn _get_offset_text_str_offset() usize {
    return @offsetOf(CommandBuffer, "text_str_offset");
}
export fn _get_offset_text_str_len() usize {
    return @offsetOf(CommandBuffer, "text_str_len");
}
export fn _get_offset_string_buffer() usize {
    return @offsetOf(CommandBuffer, "string_buffer");
}
export fn _get_offset_string_buffer_len() usize {
    return @offsetOf(CommandBuffer, "string_buffer_len");
}

// Circle gradient offsets
export fn _get_offset_circle_gradient_count() usize {
    return @offsetOf(CommandBuffer, "circle_gradient_count");
}
export fn _get_offset_circle_gradient_x() usize {
    return @offsetOf(CommandBuffer, "circle_gradient_x");
}
export fn _get_offset_circle_gradient_y() usize {
    return @offsetOf(CommandBuffer, "circle_gradient_y");
}
export fn _get_offset_circle_gradient_radius() usize {
    return @offsetOf(CommandBuffer, "circle_gradient_radius");
}
export fn _get_offset_circle_gradient_inner() usize {
    return @offsetOf(CommandBuffer, "circle_gradient_inner");
}
export fn _get_offset_circle_gradient_outer() usize {
    return @offsetOf(CommandBuffer, "circle_gradient_outer");
}

// Rectangle gradient V offsets
export fn _get_offset_rect_gradient_v_count() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_v_count");
}
export fn _get_offset_rect_gradient_v_x() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_v_x");
}
export fn _get_offset_rect_gradient_v_y() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_v_y");
}
export fn _get_offset_rect_gradient_v_w() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_v_w");
}
export fn _get_offset_rect_gradient_v_h() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_v_h");
}
export fn _get_offset_rect_gradient_v_top() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_v_top");
}
export fn _get_offset_rect_gradient_v_bottom() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_v_bottom");
}

// Rectangle gradient H offsets
export fn _get_offset_rect_gradient_h_count() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_h_count");
}
export fn _get_offset_rect_gradient_h_x() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_h_x");
}
export fn _get_offset_rect_gradient_h_y() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_h_y");
}
export fn _get_offset_rect_gradient_h_w() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_h_w");
}
export fn _get_offset_rect_gradient_h_h() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_h_h");
}
export fn _get_offset_rect_gradient_h_left() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_h_left");
}
export fn _get_offset_rect_gradient_h_right() usize {
    return @offsetOf(CommandBuffer, "rect_gradient_h_right");
}

// Memory Telemetry Exports
// These functions allow JavaScript to monitor memory allocation patterns.
// Call after _frame() to get current statistics. If (alloc_count - dealloc_count)
// grows over time, there may be a memory leak.
//
// Usage from JS:
//   const stats = {
//       allocCount: wasm._get_alloc_count(),
//       deallocCount: wasm._get_dealloc_count(),
//       reallocCount: wasm._get_realloc_count(),
//       bytesAllocated: wasm._get_bytes_allocated(),
//       bytesFreed: wasm._get_bytes_freed(),
//   };
//   const liveAllocations = stats.allocCount - stats.deallocCount;
//   const liveBytes = stats.bytesAllocated - stats.bytesFreed;
//   console.log(`Live: ${liveAllocations} allocations, ${liveBytes} bytes`);

export fn _get_alloc_count() u64 {
    return alloc_count;
}

export fn _get_dealloc_count() u64 {
    return dealloc_count;
}

export fn _get_realloc_count() u64 {
    return realloc_count;
}

export fn _get_bytes_allocated() u64 {
    return bytes_allocated;
}

export fn _get_bytes_freed() u64 {
    return bytes_freed;
}

/// Reset all telemetry counters to zero (useful for per-session tracking)
export fn _reset_memory_telemetry() void {
    alloc_count = 0;
    dealloc_count = 0;
    realloc_count = 0;
    bytes_allocated = 0;
    bytes_freed = 0;
}

// Unit Tests
// Note: Core command buffer tests are in backend/wasm.zig
// These tests verify the hosted function bridge layer

const testing = std.testing;

test "hostedDrawRectangle stores data correctly via wasm backend" {
    const buf = wasm.getBuffer();
    buf.reset();

    const rect = RocRectangle{
        .x = 10.0,
        .y = 20.0,
        .width = 100.0,
        .height = 50.0,
        .color = 10,
    };
    hostedDrawRectangle(undefined, undefined, @ptrCast(@constCast(&rect)));

    try testing.expectEqual(@as(u32, 1), buf.rect_count);
    try testing.expectEqual(@as(u32, 1), buf.cmd_count);
    try testing.expectEqual(@as(f32, 10.0), buf.rect_x[0]);
    try testing.expectEqual(@as(f32, 20.0), buf.rect_y[0]);
    try testing.expectEqual(@as(f32, 100.0), buf.rect_w[0]);
    try testing.expectEqual(@as(f32, 50.0), buf.rect_h[0]);
    try testing.expectEqual(@as(u8, 10), buf.rect_color[0]);
}

test "_test_draw_commands returns correct count" {
    const count = _test_draw_commands();
    const buf = wasm.getBuffer();

    try testing.expectEqual(@as(u32, 4), count);
    try testing.expect(buf.has_clear);
    try testing.expectEqual(@as(u8, 1), buf.clear_color);
    try testing.expectEqual(@as(u32, 1), buf.rect_count);
    try testing.expectEqual(@as(u32, 1), buf.circle_count);
    try testing.expectEqual(@as(u32, 1), buf.line_count);
    try testing.expectEqual(@as(u32, 1), buf.text_count);
}
