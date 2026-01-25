///! Web platform host for roc-ray - command buffer based rendering for Canvas 2D/WebGL
///! This file is used for WASM builds. Native builds use host_native.zig with raylib.
///! Can also be compiled natively for unit testing.
const std = @import("std");
const builtin = @import("builtin");
const builtins = @import("builtins");

// Import shared Roc ABI types (same definitions as native host)
const roc_types = @import("roc_types.zig");
const RocStr = roc_types.RocStr;
const RocBox = roc_types.RocBox;
const RocVector2 = roc_types.RocVector2;
const RocPlatformState = roc_types.RocPlatformState;
const RocRectangle = roc_types.RocRectangle;
const RocCircle = roc_types.RocCircle;
const RocLine = roc_types.RocLine;
const RocText = roc_types.RocText;
const Try_BoxModel_I64 = roc_types.Try_BoxModel_I64;
const RenderArgs = roc_types.RenderArgs;
const RocOps = roc_types.RocOps;
const HostedFn = roc_types.HostedFn;
const RocAlloc = roc_types.RocAlloc;
const RocDealloc = roc_types.RocDealloc;
const RocRealloc = roc_types.RocRealloc;
const RocDbg = roc_types.RocDbg;
const RocExpectFailed = roc_types.RocExpectFailed;
const RocCrashed = roc_types.RocCrashed;
// Roc functions: extern on WASM (provided by Roc compiler), stubs on native (for testing)
const roc__init_for_host = if (builtin.cpu.arch == .wasm32)
    roc_types.roc__init_for_host
else
    stubRocInit;

const roc__render_for_host = if (builtin.cpu.arch == .wasm32)
    roc_types.roc__render_for_host
else
    stubRocRender;

// Native stubs (only used during unit testing, not in production)
fn stubRocInit(_: *RocOps, _: *Try_BoxModel_I64, _: ?*anyopaque) callconv(.c) void {}
fn stubRocRender(_: *RocOps, _: *Try_BoxModel_I64, _: *RenderArgs) callconv(.c) void {}

// ============================================================================
// Constants - Command buffer capacities (tune based on typical usage)
// ============================================================================

pub const MAX_COMMANDS = 2048; // Total commands per frame (all types combined)
pub const MAX_RECTS = 1024;
pub const MAX_CIRCLES = 512;
pub const MAX_LINES = 512;
pub const MAX_TEXTS = 256;
pub const MAX_STRING_BYTES = 8192;

// Command type codes (must match JS)
pub const CMD_RECT: u4 = 1;
pub const CMD_CIRCLE: u4 = 2;
pub const CMD_LINE: u4 = 3;
pub const CMD_TEXT: u4 = 4;

// ============================================================================
// Command Buffer - SoA layout for cache efficiency and zero allocations
// ============================================================================

pub const CommandBuffer = struct {
    // Frame state
    has_clear: bool = false,
    clear_color: u8 = 0,

    // Command stream - draw order as (type, index) pairs
    // High 4 bits = type, low 12 bits = index into type-specific arrays
    cmd_stream: [MAX_COMMANDS]u16 = undefined,
    cmd_count: u32 = 0,

    // Rectangles (SoA)
    rect_count: u32 = 0,
    rect_x: [MAX_RECTS]f32 = undefined,
    rect_y: [MAX_RECTS]f32 = undefined,
    rect_w: [MAX_RECTS]f32 = undefined,
    rect_h: [MAX_RECTS]f32 = undefined,
    rect_color: [MAX_RECTS]u8 = undefined,

    // Circles (SoA)
    circle_count: u32 = 0,
    circle_x: [MAX_CIRCLES]f32 = undefined,
    circle_y: [MAX_CIRCLES]f32 = undefined,
    circle_radius: [MAX_CIRCLES]f32 = undefined,
    circle_color: [MAX_CIRCLES]u8 = undefined,

    // Lines (SoA)
    line_count: u32 = 0,
    line_x1: [MAX_LINES]f32 = undefined,
    line_y1: [MAX_LINES]f32 = undefined,
    line_x2: [MAX_LINES]f32 = undefined,
    line_y2: [MAX_LINES]f32 = undefined,
    line_color: [MAX_LINES]u8 = undefined,

    // Text (SoA)
    text_count: u32 = 0,
    text_x: [MAX_TEXTS]f32 = undefined,
    text_y: [MAX_TEXTS]f32 = undefined,
    text_size: [MAX_TEXTS]i32 = undefined,
    text_color: [MAX_TEXTS]u8 = undefined,
    text_str_offset: [MAX_TEXTS]u16 = undefined,
    text_str_len: [MAX_TEXTS]u16 = undefined,

    // String buffer (append-only)
    string_buffer: [MAX_STRING_BYTES]u8 = undefined,
    string_buffer_len: u32 = 0,

    pub fn reset(self: *CommandBuffer) void {
        self.has_clear = false;
        self.cmd_count = 0;
        self.rect_count = 0;
        self.circle_count = 0;
        self.line_count = 0;
        self.text_count = 0;
        self.string_buffer_len = 0;
    }
};

// Global command buffer (static allocation - no runtime alloc)
var cmd_buffer: CommandBuffer = .{};

// ============================================================================
// Memory Management
// ============================================================================

// Allocation telemetry - track allocations for leak detection
// JS can read these via exported getters and log them to detect memory leaks over time
var alloc_count: u64 = 0;
var dealloc_count: u64 = 0;
var realloc_count: u64 = 0;
var bytes_allocated: u64 = 0;
var bytes_freed: u64 = 0;

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

// ============================================================================
// Exported allocation functions (Roc imports these at link time)
// ============================================================================

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

// ============================================================================
// Exported debug/panic functions (Roc imports these at link time)
// ============================================================================

export fn roc_dbg(loc_ptr: [*]const u8, loc_len: usize, msg_ptr: [*]const u8, msg_len: usize) callconv(.c) void {
    // Log location if provided
    if (loc_len > 0) {
        js_console_log(loc_ptr, loc_len);
    }
    // Log message
    js_console_log(msg_ptr, msg_len);
}

export fn roc_panic(msg_ptr: [*]const u8, msg_len: usize) callconv(.c) noreturn {
    js_throw_error(msg_ptr, msg_len);
}

// ============================================================================
// Command Buffer Helpers
// ============================================================================

fn pushCmd(cmd_type: u4, index: u12) void {
    if (cmd_buffer.cmd_count >= MAX_COMMANDS) return;
    cmd_buffer.cmd_stream[cmd_buffer.cmd_count] = (@as(u16, cmd_type) << 12) | index;
    cmd_buffer.cmd_count += 1;
}

// ============================================================================
// Hosted Drawing Functions
// ============================================================================

fn hostedDrawBeginFrame(_: *RocOps, _: *anyopaque, _: *anyopaque) callconv(.c) void {
    cmd_buffer.reset();
}

fn hostedDrawClear(_: *RocOps, _: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const color: *const u8 = @ptrCast(args_ptr);
    cmd_buffer.has_clear = true;
    cmd_buffer.clear_color = color.*;
}

fn hostedDrawCircle(_: *RocOps, _: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const circle: *const RocCircle = @ptrCast(@alignCast(args_ptr));
    const i = cmd_buffer.circle_count;
    if (i >= MAX_CIRCLES) return;

    cmd_buffer.circle_x[i] = circle.center.x;
    cmd_buffer.circle_y[i] = circle.center.y;
    cmd_buffer.circle_radius[i] = circle.radius;
    cmd_buffer.circle_color[i] = circle.color;
    cmd_buffer.circle_count += 1;

    pushCmd(CMD_CIRCLE, @intCast(i));
}

fn hostedDrawEndFrame(_: *RocOps, _: *anyopaque, _: *anyopaque) callconv(.c) void {
    // No-op for WASM - JS reads buffer after _frame() returns
}

fn hostedDrawLine(_: *RocOps, _: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const line: *const RocLine = @ptrCast(@alignCast(args_ptr));
    const i = cmd_buffer.line_count;
    if (i >= MAX_LINES) return;

    cmd_buffer.line_x1[i] = line.start.x;
    cmd_buffer.line_y1[i] = line.start.y;
    cmd_buffer.line_x2[i] = line.end.x;
    cmd_buffer.line_y2[i] = line.end.y;
    cmd_buffer.line_color[i] = line.color;
    cmd_buffer.line_count += 1;

    pushCmd(CMD_LINE, @intCast(i));
}

fn hostedDrawRectangle(_: *RocOps, _: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const rect: *const RocRectangle = @ptrCast(@alignCast(args_ptr));
    const i = cmd_buffer.rect_count;
    if (i >= MAX_RECTS) return;

    cmd_buffer.rect_x[i] = rect.x;
    cmd_buffer.rect_y[i] = rect.y;
    cmd_buffer.rect_w[i] = rect.width;
    cmd_buffer.rect_h[i] = rect.height;
    cmd_buffer.rect_color[i] = rect.color;
    cmd_buffer.rect_count += 1;

    pushCmd(CMD_RECT, @intCast(i));
}

fn hostedDrawText(_: *RocOps, _: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const txt: *const RocText = @ptrCast(@alignCast(args_ptr));
    const i = cmd_buffer.text_count;
    if (i >= MAX_TEXTS) return;

    const str_slice = txt.text.asSlice();
    const available = MAX_STRING_BYTES - cmd_buffer.string_buffer_len;
    const str_len: u32 = @intCast(@min(str_slice.len, available));
    if (str_len == 0) return;

    const offset = cmd_buffer.string_buffer_len;
    @memcpy(cmd_buffer.string_buffer[offset..][0..str_len], str_slice[0..str_len]);
    cmd_buffer.string_buffer_len += str_len;

    cmd_buffer.text_x[i] = txt.pos.x;
    cmd_buffer.text_y[i] = txt.pos.y;
    cmd_buffer.text_size[i] = txt.size;
    cmd_buffer.text_color[i] = txt.color;
    cmd_buffer.text_str_offset[i] = @intCast(offset);
    cmd_buffer.text_str_len[i] = @intCast(str_len);
    cmd_buffer.text_count += 1;

    pushCmd(CMD_TEXT, @intCast(i));
}

/// Hosted function pointers (alphabetical order by fully-qualified name)
const hosted_function_ptrs = [_]HostedFn{
    hostedDrawBeginFrame, // Draw.begin_frame! (0)
    hostedDrawCircle, // Draw.circle! (1)
    hostedDrawClear, // Draw.clear! (2)
    hostedDrawEndFrame, // Draw.end_frame! (3)
    hostedDrawLine, // Draw.line! (4)
    hostedDrawRectangle, // Draw.rectangle! (5)
    hostedDrawText, // Draw.text! (6)
};

// ============================================================================
// App State
// ============================================================================

var app_model: RocBox = undefined;
var app_initialized: bool = false; // Track if init has been called (model can be ptr 0 for empty records)
var frame_count: u64 = 0;

/// Decrement the reference count of a RocBox
/// If the refcount reaches zero, the memory is freed
fn decrefRocBox(box: RocBox, roc_ops: *RocOps) void {
    const ptr: ?[*]u8 = @ptrCast(box);
    // Box alignment is pointer-width, elements are not refcounted at this level
    builtins.utils.decrefDataPtrC(ptr, @alignOf(usize), false, roc_ops);
}

// Dummy env for RocOps (not used by web host, but must be valid pointer)
var dummy_env: u8 = 0;

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

// ============================================================================
// Exported WASM Functions
// ============================================================================

/// Initialize the app - call once at startup
export fn _init() void {
    var roc_ops = makeRocOps();
    var result: Try_BoxModel_I64 = undefined;
    var unit: struct {} = .{};
    roc__init_for_host(&roc_ops, &result, @ptrCast(&unit));

    if (result.isOk()) {
        app_model = result.getModel();
        app_initialized = true;
    }
}

/// Run one frame - call each animation frame
export fn _frame(mouse_x: f32, mouse_y: f32, buttons: u32, wheel: f32) void {
    if (!app_initialized) return;

    var roc_ops = makeRocOps();
    const platform_state = RocPlatformState{
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
    return &cmd_buffer;
}

// ============================================================================
// Test Exports - for JS round-trip testing without Roc
// ============================================================================

/// Test function callable from JS - exercises draw commands without Roc
export fn _test_draw_commands() u32 {
    cmd_buffer.reset();

    // Clear with blue (color index 1)
    cmd_buffer.has_clear = true;
    cmd_buffer.clear_color = 1;

    // Rectangle at (10, 10), size 100x50, red (color index 10)
    const rect = RocRectangle{ .x = 10, .y = 10, .width = 100, .height = 50, .color = 10 };
    hostedDrawRectangle(undefined, undefined, @constCast(@ptrCast(&rect)));

    // Circle at (200, 100), radius 30, green (color index 4)
    const circle = RocCircle{ .center = .{ .x = 200, .y = 100 }, .radius = 30, .color = 4 };
    hostedDrawCircle(undefined, undefined, @constCast(@ptrCast(&circle)));

    // Line from (300, 10) to (400, 100), yellow (color index 12)
    const line = RocLine{ .start = .{ .x = 300, .y = 10 }, .end = .{ .x = 400, .y = 100 }, .color = 12 };
    hostedDrawLine(undefined, undefined, @constCast(@ptrCast(&line)));

    // Text "Test" at (10, 200), size 32, white (color index 11)
    // For testing without RocStr, manually add to string buffer
    const test_str = "Test";
    @memcpy(cmd_buffer.string_buffer[0..test_str.len], test_str);
    cmd_buffer.string_buffer_len = test_str.len;

    const i = cmd_buffer.text_count;
    cmd_buffer.text_x[i] = 10;
    cmd_buffer.text_y[i] = 200;
    cmd_buffer.text_size[i] = 32;
    cmd_buffer.text_color[i] = 11;
    cmd_buffer.text_str_offset[i] = 0;
    cmd_buffer.text_str_len[i] = test_str.len;
    cmd_buffer.text_count += 1;
    pushCmd(CMD_TEXT, @intCast(i));

    return cmd_buffer.cmd_count;
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

// ============================================================================
// Memory Telemetry Exports
// ============================================================================
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

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "CommandBuffer.reset clears all counts" {
    var buf = CommandBuffer{};
    buf.rect_count = 5;
    buf.circle_count = 3;
    buf.cmd_count = 8;
    buf.string_buffer_len = 100;
    buf.has_clear = true;

    buf.reset();

    try testing.expectEqual(@as(u32, 0), buf.rect_count);
    try testing.expectEqual(@as(u32, 0), buf.circle_count);
    try testing.expectEqual(@as(u32, 0), buf.cmd_count);
    try testing.expectEqual(@as(u32, 0), buf.string_buffer_len);
    try testing.expect(!buf.has_clear);
}

test "pushCmd encodes type and index correctly" {
    cmd_buffer.reset();

    pushCmd(CMD_RECT, 0);
    try testing.expectEqual(@as(u16, 0x1000), cmd_buffer.cmd_stream[0]);

    pushCmd(CMD_CIRCLE, 5);
    try testing.expectEqual(@as(u16, 0x2005), cmd_buffer.cmd_stream[1]);

    pushCmd(CMD_LINE, 100);
    try testing.expectEqual(@as(u16, 0x3064), cmd_buffer.cmd_stream[2]);

    pushCmd(CMD_TEXT, 255);
    try testing.expectEqual(@as(u16, 0x40FF), cmd_buffer.cmd_stream[3]);

    try testing.expectEqual(@as(u32, 4), cmd_buffer.cmd_count);
}

test "hostedDrawRectangle stores data correctly" {
    cmd_buffer.reset();

    const rect = RocRectangle{
        .x = 10.0,
        .y = 20.0,
        .width = 100.0,
        .height = 50.0,
        .color = 10,
    };
    hostedDrawRectangle(undefined, undefined, @constCast(@ptrCast(&rect)));

    try testing.expectEqual(@as(u32, 1), cmd_buffer.rect_count);
    try testing.expectEqual(@as(u32, 1), cmd_buffer.cmd_count);
    try testing.expectEqual(@as(f32, 10.0), cmd_buffer.rect_x[0]);
    try testing.expectEqual(@as(f32, 20.0), cmd_buffer.rect_y[0]);
    try testing.expectEqual(@as(f32, 100.0), cmd_buffer.rect_w[0]);
    try testing.expectEqual(@as(f32, 50.0), cmd_buffer.rect_h[0]);
    try testing.expectEqual(@as(u8, 10), cmd_buffer.rect_color[0]);

    // Check command stream
    const cmd = cmd_buffer.cmd_stream[0];
    try testing.expectEqual(CMD_RECT, @as(u4, @truncate(cmd >> 12)));
    try testing.expectEqual(@as(u12, 0), @as(u12, @truncate(cmd)));
}

test "command stream preserves order" {
    cmd_buffer.reset();

    // Push: rect, circle, rect, line
    const rect1 = RocRectangle{ .x = 0, .y = 0, .width = 10, .height = 10, .color = 0 };
    hostedDrawRectangle(undefined, undefined, @constCast(@ptrCast(&rect1)));

    const circle = RocCircle{ .center = .{ .x = 50, .y = 50 }, .radius = 25, .color = 1 };
    hostedDrawCircle(undefined, undefined, @constCast(@ptrCast(&circle)));

    const rect2 = RocRectangle{ .x = 100, .y = 0, .width = 10, .height = 10, .color = 2 };
    hostedDrawRectangle(undefined, undefined, @constCast(@ptrCast(&rect2)));

    const line = RocLine{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 100, .y = 100 }, .color = 3 };
    hostedDrawLine(undefined, undefined, @constCast(@ptrCast(&line)));

    try testing.expectEqual(@as(u32, 4), cmd_buffer.cmd_count);
    try testing.expectEqual(@as(u32, 2), cmd_buffer.rect_count);
    try testing.expectEqual(@as(u32, 1), cmd_buffer.circle_count);
    try testing.expectEqual(@as(u32, 1), cmd_buffer.line_count);

    // Verify order: rect[0], circle[0], rect[1], line[0]
    try testing.expectEqual(CMD_RECT, @as(u4, @truncate(cmd_buffer.cmd_stream[0] >> 12)));
    try testing.expectEqual(@as(u12, 0), @as(u12, @truncate(cmd_buffer.cmd_stream[0])));

    try testing.expectEqual(CMD_CIRCLE, @as(u4, @truncate(cmd_buffer.cmd_stream[1] >> 12)));
    try testing.expectEqual(@as(u12, 0), @as(u12, @truncate(cmd_buffer.cmd_stream[1])));

    try testing.expectEqual(CMD_RECT, @as(u4, @truncate(cmd_buffer.cmd_stream[2] >> 12)));
    try testing.expectEqual(@as(u12, 1), @as(u12, @truncate(cmd_buffer.cmd_stream[2])));

    try testing.expectEqual(CMD_LINE, @as(u4, @truncate(cmd_buffer.cmd_stream[3] >> 12)));
    try testing.expectEqual(@as(u12, 0), @as(u12, @truncate(cmd_buffer.cmd_stream[3])));
}

test "capacity limits are respected" {
    cmd_buffer.reset();

    // Fill rectangles to capacity
    var i: u32 = 0;
    while (i < MAX_RECTS) : (i += 1) {
        const rect = RocRectangle{ .x = 0, .y = 0, .width = 1, .height = 1, .color = 0 };
        hostedDrawRectangle(undefined, undefined, @constCast(@ptrCast(&rect)));
    }

    try testing.expectEqual(@as(u32, MAX_RECTS), cmd_buffer.rect_count);

    // One more should be ignored
    const extra = RocRectangle{ .x = 999, .y = 999, .width = 1, .height = 1, .color = 0 };
    hostedDrawRectangle(undefined, undefined, @constCast(@ptrCast(&extra)));
    try testing.expectEqual(@as(u32, MAX_RECTS), cmd_buffer.rect_count);
}

test "_test_draw_commands returns correct count" {
    const count = _test_draw_commands();
    try testing.expectEqual(@as(u32, 4), count);

    try testing.expect(cmd_buffer.has_clear);
    try testing.expectEqual(@as(u8, 1), cmd_buffer.clear_color);
    try testing.expectEqual(@as(u32, 1), cmd_buffer.rect_count);
    try testing.expectEqual(@as(u32, 1), cmd_buffer.circle_count);
    try testing.expectEqual(@as(u32, 1), cmd_buffer.line_count);
    try testing.expectEqual(@as(u32, 1), cmd_buffer.text_count);
}
