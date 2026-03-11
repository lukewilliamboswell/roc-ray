//! WASM platform host for roc-ray uses a command buffer assumes rendering for a Canvas 2D context.
//!
//! This file is used for WASM builds, but also compiled natively for unit testing.
//!
//! Architecture:
//! - This host handles Roc FFI, memory callbacks, and WASM exports
//! - The command buffer backend (backend_wasm.zig) handles draw buffering
//! - JavaScript reads the command buffer after each frame

const std = @import("std");
const builtin = @import("builtin");
const wasm = @import("backend_wasm.zig");

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

const ffi = @import("roc_ffi.zig");
const abi = @import("roc_platform_abi.zig");

// Type aliases
const RocBox = ffi.RocBox;
const RocResult = ffi.Try(ffi.RocBox, i64);
const RenderArgs = ffi.RenderArgs;
const RocOps = ffi.RocOps;
const ReadEnvResult = abi.Try(abi.RocStr, *anyopaque);

// Roc functions: extern on WASM (provided by Roc compiler), stubs on native (for testing)
const roc__init_for_host = if (builtin.cpu.arch == .wasm32)
    abi.roc__init_for_host
else
    stubRocInit;

const roc__render_for_host = if (builtin.cpu.arch == .wasm32)
    abi.roc__render_for_host
else
    stubRocRender;

// Native stubs (only used during unit testing, not in production)
fn stubRocInit(_: *RocOps, _: *anyopaque, _: *anyopaque) callconv(.c) void {}
fn stubRocRender(_: *RocOps, _: *anyopaque, _: *anyopaque) callconv(.c) void {}

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

// Exit request state (set by Host.exit!, read by JS via _get_exit_requested)
var exit_requested: ?i64 = null;

// Screen size (set by JS via _set_screen_size, read by Host.get_screen_size!)
var screen_width: i32 = 800;
var screen_height: i32 = 600;

// Keyboard state (set by JS via _set_key_down/_set_key_up, passed to Roc each frame)
var key_state: [ffi.KEY_COUNT]u8 = [_]u8{0} ** ffi.KEY_COUNT;

// Keyboard state manager (initialized in _init)
var keys: ffi.Keys = undefined;
var keys_initialized: bool = false;

// Conditional allocator: WASM uses wasm_allocator, native uses page_allocator (for testing)
const wasm_allocator: std.mem.Allocator = if (builtin.cpu.arch == .wasm32)
    std.heap.wasm_allocator
else
    std.heap.page_allocator;

/// WASM environment type for DefaultAllocators.
const WasmEnv = struct {
    pub fn allocator(_: *@This()) std.mem.Allocator {
        return wasm_allocator;
    }
};

var wasm_env: WasmEnv = .{};

/// WASM-compatible memory management callbacks for RocOps.
/// Cannot use abi.DefaultAllocators because its OOM handler calls
/// std.process.exit/stderr which are unavailable on wasm32-freestanding.
const WasmAllocs = struct {
    pub fn rocAlloc(alloc_args: *abi.RocAlloc, _: *anyopaque) callconv(.c) void {
        const min_alignment: usize = @max(alloc_args.alignment, @alignOf(usize));
        const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);
        const size_storage_bytes = min_alignment;
        const total_size = alloc_args.length + size_storage_bytes;

        const base_ptr = wasm_allocator.rawAlloc(total_size, align_enum, @returnAddress()) orelse {
            js_throw_error("roc_alloc: out of memory", 24);
        };

        const size_ptr: *usize = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes - @sizeOf(usize));
        size_ptr.* = total_size;
        alloc_args.answer = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes);
    }

    pub fn rocDealloc(dealloc_args: *abi.RocDealloc, _: *anyopaque) callconv(.c) void {
        const min_alignment: usize = @max(dealloc_args.alignment, @alignOf(usize));
        const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);
        const size_storage_bytes = min_alignment;

        const size_ptr: *const usize = @ptrFromInt(@intFromPtr(dealloc_args.ptr) - @sizeOf(usize));
        const total_size = size_ptr.*;

        const base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(dealloc_args.ptr) - size_storage_bytes);
        const slice = base_ptr[0..total_size];
        wasm_allocator.rawFree(slice, align_enum, @returnAddress());
    }

    pub fn rocRealloc(realloc_args: *abi.RocRealloc, _: *anyopaque) callconv(.c) void {
        const min_alignment: usize = @max(realloc_args.alignment, @alignOf(usize));
        const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);
        const size_storage_bytes = min_alignment;

        const old_size_ptr: *const usize = @ptrFromInt(@intFromPtr(realloc_args.answer) - @sizeOf(usize));
        const old_total_size = old_size_ptr.*;
        const old_base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(realloc_args.answer) - size_storage_bytes);

        const new_total_size = realloc_args.new_length + size_storage_bytes;
        const old_user_data_size = old_total_size - size_storage_bytes;
        const copy_size = @min(old_user_data_size, realloc_args.new_length);

        const new_base_ptr = wasm_allocator.rawAlloc(new_total_size, align_enum, @returnAddress()) orelse {
            js_throw_error("roc_realloc: out of memory", 26);
        };

        const new_user_ptr: [*]u8 = @ptrFromInt(@intFromPtr(new_base_ptr) + size_storage_bytes);
        const old_user_ptr: [*]const u8 = @ptrCast(realloc_args.answer);
        @memcpy(new_user_ptr[0..copy_size], old_user_ptr[0..copy_size]);

        wasm_allocator.rawFree(old_base_ptr[0..old_total_size], align_enum, @returnAddress());

        const new_size_ptr: *usize = @ptrFromInt(@intFromPtr(new_base_ptr) + size_storage_bytes - @sizeOf(usize));
        new_size_ptr.* = new_total_size;
        realloc_args.answer = new_user_ptr;
    }
};

// Exported allocation functions (Roc imports these at link time)

export fn roc_alloc(size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const align_enum = std.mem.Alignment.fromByteUnits(alignment);
    const size_storage_bytes = @max(alignment, @alignOf(usize));
    const total_size = size + size_storage_bytes;

    const base_ptr = wasm_allocator.vtable.alloc(undefined, total_size, align_enum, @returnAddress()) orelse {
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
    wasm_allocator.vtable.free(undefined, slice, align_enum, @returnAddress());
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

    const new_base_ptr = wasm_allocator.vtable.remap(undefined, old_slice, align_enum, new_total_size, @returnAddress()) orelse {
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
fn rocDbgFn(dbg_info: *const abi.RocDbg, _: *anyopaque) callconv(.c) void {
    js_console_log(dbg_info.utf8_bytes, dbg_info.len);
}

fn rocExpectFailedFn(roc_expect: *const abi.RocExpectFailed, _: *anyopaque) callconv(.c) void {
    js_console_log(roc_expect.utf8_bytes, roc_expect.len);
}

fn rocCrashedFn(roc_crashed_args: *const abi.RocCrashed, _: *anyopaque) callconv(.c) void {
    js_throw_error(roc_crashed_args.utf8_bytes, roc_crashed_args.len);
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

fn hostedDrawClear(_: *RocOps, _: *anyopaque, args: *const abi.DrawClearArgs) callconv(.c) void {
    wasm.clearBackground(args.arg0);
}

fn hostedDrawCircle(_: *RocOps, _: *anyopaque, args: *const abi.DrawCircleArgs) callconv(.c) void {
    wasm.drawCircle(args.*);
}

fn hostedDrawCircleGradient(_: *RocOps, _: *anyopaque, args: *const abi.DrawCircle_gradientArgs) callconv(.c) void {
    wasm.drawCircleGradient(args.*);
}

fn hostedDrawEndFrame(_: *RocOps, _: *anyopaque, _: *anyopaque) callconv(.c) void {
    wasm.endDrawing();
}

fn hostedDrawLine(_: *RocOps, _: *anyopaque, args: *const abi.DrawLineArgs) callconv(.c) void {
    wasm.drawLine(args.*);
}

fn hostedDrawRectangle(_: *RocOps, _: *anyopaque, args: *const abi.DrawRectangleArgs) callconv(.c) void {
    wasm.drawRectangle(args.*);
}

fn hostedDrawRectangleGradientH(_: *RocOps, _: *anyopaque, args: *const abi.DrawRectangle_gradient_hArgs) callconv(.c) void {
    wasm.drawRectangleGradientH(args.*);
}

fn hostedDrawRectangleGradientV(_: *RocOps, _: *anyopaque, args: *const abi.DrawRectangle_gradient_vArgs) callconv(.c) void {
    wasm.drawRectangleGradientV(args.*);
}

fn hostedDrawText(_: *RocOps, _: *anyopaque, args: *const abi.DrawTextArgs) callconv(.c) void {
    const text_slice = args.text.asSlice();
    wasm.drawText(args.pos.x, args.pos.y, text_slice, args.size, args.color);
}

fn hostedExit(_: *RocOps, _: *anyopaque, args: *const abi.HostExitArgs) callconv(.c) void {
    exit_requested = @as(i64, args.arg0);
}

fn hostedGetScreenSize(_: *RocOps, result: *abi.HostGet_screen_sizeRetRecord, _: *anyopaque) callconv(.c) void {
    result.* = .{ .height = screen_height, .width = screen_width };
}

fn hostedReadEnv(_: *RocOps, result: *ReadEnvResult, _: *const abi.HostRead_envArgs) callconv(.c) void {
    // WASM doesn't have environment variables - always return NotFound
    result.tag = .Err;
}

fn hostedSetScreenSize(_: *RocOps, result: *abi.Try(void, *anyopaque), _: *const abi.HostSet_screen_sizeArgs) callconv(.c) void {
    // WASM can't resize the browser window - return NotSupported
    result.tag = .Err;
}

fn hostedSetTargetFps(_: *RocOps, _: *anyopaque, _: *const abi.HostSet_target_fpsArgs) callconv(.c) void {
    // No-op on WASM - browser controls frame timing via requestAnimationFrame
}

/// Hosted function dispatch table built from PlatformHostedFns.
const hosted_fns_table = abi.hostedFunctions(.{
    .draw_begin_frame = &hostedDrawBeginFrame,
    .draw_circle = &hostedDrawCircle,
    .draw_circle_gradient = &hostedDrawCircleGradient,
    .draw_clear = &hostedDrawClear,
    .draw_end_frame = &hostedDrawEndFrame,
    .draw_line = &hostedDrawLine,
    .draw_rectangle = &hostedDrawRectangle,
    .draw_rectangle_gradient_h = &hostedDrawRectangleGradientH,
    .draw_rectangle_gradient_v = &hostedDrawRectangleGradientV,
    .draw_text = &hostedDrawText,
    .host_exit = &hostedExit,
    .host_get_screen_size = &hostedGetScreenSize,
    .host_read_env = &hostedReadEnv,
    .host_set_screen_size = &hostedSetScreenSize,
    .host_set_target_fps = &hostedSetTargetFps,
});

fn makeRocOps() RocOps {
    return RocOps{
        .env = @ptrCast(&wasm_env),
        .roc_alloc = &WasmAllocs.rocAlloc,
        .roc_dealloc = &WasmAllocs.rocDealloc,
        .roc_realloc = &WasmAllocs.rocRealloc,
        .roc_dbg = &rocDbgFn,
        .roc_expect_failed = &rocExpectFailedFn,
        .roc_crashed = &rocCrashedFn,
        .hosted_fns = hosted_fns_table,
    };
}

/// Initialize the app - call once at startup
export fn _init() void {
    var roc_ops = makeRocOps();

    // Initialize keyboard state manager
    if (!keys_initialized) {
        keys = ffi.Keys.init(&roc_ops);
        keys_initialized = true;
    }

    var result: RocResult = undefined;
    // Create initial host state for init (frame 0, no input)
    keys.incref(); // Prevent Roc from freeing our list
    var init_state = abi.Host{
        .frame_count = 0,
        .keys = keys.list,
        .mouse = .{
            .wheel = 0,
            .x = 0,
            .y = 0,
            .left = false,
            .right = false,
            .middle = false,
        },
    };
    roc__init_for_host(&roc_ops, @ptrCast(&result), @ptrCast(&init_state));

    if (result.isOk()) {
        app_model = result.getOk();
        app_initialized = true;
    }
}

/// Run one frame - call each animation frame
export fn _frame(mouse_x: f32, mouse_y: f32, buttons: u32, wheel: f32) void {
    if (!app_initialized) return;

    // Update keyboard state from JS-provided key_state array
    keys.update(&key_state);
    keys.incref(); // Prevent Roc from freeing our list

    const platform_state = abi.Host{
        .frame_count = frame_count,
        .keys = keys.list,
        .mouse = .{
            .x = mouse_x,
            .y = mouse_y,
            .left = (buttons & 1) != 0,
            .middle = (buttons & 4) != 0,
            .right = (buttons & 2) != 0,
            .wheel = wheel,
        },
    };

    var roc_ops = makeRocOps();
    var result: RocResult = undefined;
    var args = RenderArgs{ .model = app_model, .state = platform_state };
    roc__render_for_host(&roc_ops, @ptrCast(&result), @ptrCast(&args));

    // Update model for next frame (same as native host - no decref between frames)
    if (result.isOk()) {
        app_model = result.getOk();
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
    wasm.drawCircle(.{ .center = .{ .x = 200, .y = 100 }, .radius = 30, .color = .green });

    // Line from (300, 10) to (400, 100), yellow
    wasm.drawLine(.{ .start = .{ .x = 300, .y = 10 }, .end = .{ .x = 400, .y = 100 }, .color = .yellow });

    // Text "Test" at (10, 200), size 32, white
    wasm.drawText(10, 200, "Test", 32, .white);

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

// Host Effect JS Interop Exports
// These functions allow JavaScript to interact with Host effects

/// Get the exit code requested by Host.exit!, or -1 if no exit was requested.
/// JS should check this after each _frame() call.
export fn _get_exit_requested() i64 {
    return exit_requested orelse -1;
}

/// Clear the exit request (useful if JS wants to ignore the exit)
export fn _clear_exit_requested() void {
    exit_requested = null;
}

/// Set the screen size (JS should call this before _frame() to update dimensions)
export fn _set_screen_size(w: i32, h: i32) void {
    screen_width = w;
    screen_height = h;
}

// Keyboard State Exports
// These functions allow JavaScript to update keyboard state from keydown/keyup events.
// JS should call _set_key_down/up on keyboard events, then the state is automatically
// passed to Roc each frame via the keys list.

/// Set a key to Down state (1). JS should call this on keydown events.
/// key_code should be the raylib key code (0-348).
export fn _set_key_down(key_code: u32) void {
    if (key_code < ffi.KEY_COUNT) {
        key_state[key_code] = 1;
    }
}

/// Set a key to Up state (0). JS should call this on keyup events.
/// key_code should be the raylib key code (0-348).
export fn _set_key_up(key_code: u32) void {
    if (key_code < ffi.KEY_COUNT) {
        key_state[key_code] = 0;
    }
}

/// Get the current state of a key (0=Up, 1=Down). Useful for debugging.
export fn _get_key_state(key_code: u32) u8 {
    if (key_code < ffi.KEY_COUNT) {
        return key_state[key_code];
    }
    return 0;
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
// Note: Core command buffer tests are in backend_wasm.zig
// These tests verify the hosted function bridge layer

const testing = std.testing;

test "hostedDrawRectangle stores data correctly via wasm backend" {
    const buf = wasm.getBuffer();
    buf.reset();

    const rect = abi.DrawRectangleArgs{
        .x = 10.0,
        .y = 20.0,
        .width = 100.0,
        .height = 50.0,
        .color = .red,
    };
    hostedDrawRectangle(undefined, undefined, &rect);

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
