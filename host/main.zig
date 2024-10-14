const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const str = @import("roc/str.zig");
const RocStr = str.RocStr;

const list = @import("roc/list.zig");
const RocList = list.RocList;

const result = @import("result.zig");
const RocResult = result.RocResult;
const RocResultPayload = result.RocResultPayload;

const utils = @import("roc/utils.zig");

const rl = @import("raylib");
const rg = @import("raygui");

const DEBUG: bool = false;

const Align = 2 * @alignOf(usize);

extern fn malloc(size: usize) callconv(.C) ?*align(Align) anyopaque;
extern fn realloc(c_ptr: [*]align(Align) u8, size: usize) callconv(.C) ?*anyopaque;
extern fn free(c_ptr: [*]align(Align) u8) callconv(.C) void;
extern fn memcpy(dst: [*]u8, src: [*]u8, size: usize) callconv(.C) void;
extern fn memset(dst: [*]u8, value: i32, size: usize) callconv(.C) void;

export fn roc_alloc(size: usize, alignment: u32) callconv(.C) *anyopaque {
    if (DEBUG) {
        const ptr = malloc(size);
        const stdout = std.io.getStdOut().writer();
        stdout.print("alloc:   {d} (alignment {d}, size {d})\n", .{ ptr, alignment, size }) catch unreachable;
        return ptr;
    } else {
        return malloc(size).?;
    }
}

export fn roc_realloc(old_ptr: *anyopaque, new_size: usize, old_size: usize, alignment: u32) callconv(.C) *anyopaque {
    if (DEBUG) {
        const stdout = std.io.getStdOut().writer();
        stdout.print("realloc: {d} (alignment {d}, old_size {d})\n", .{ old_ptr, alignment, old_size }) catch unreachable;
    }

    return realloc(@as([*]align(Align) u8, @alignCast(@ptrCast(old_ptr))), new_size).?;
}

export fn roc_dealloc(c_ptr: *anyopaque, alignment: u32) callconv(.C) void {
    if (DEBUG) {
        const stdout = std.io.getStdOut().writer();
        stdout.print("dealloc: {d} (alignment {d})\n", .{ c_ptr, alignment }) catch unreachable;
    }

    free(@as([*]align(Align) u8, @alignCast(@ptrCast(c_ptr))));
}

export fn roc_panic(msg: *RocStr, tag_id: u32) callconv(.C) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print("\n\nRoc crashed with the following error;\nMSG:{s}\nTAG:{d}\n\nShutting down\n", .{ msg.asSlice(), tag_id }) catch unreachable;
    std.process.exit(0);
}

export fn roc_dbg(loc: *RocStr, msg: *RocStr, src: *RocStr) callconv(.C) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print("[{s}] {s} = {s}\n", .{ loc.asSlice(), src.asSlice(), msg.asSlice() }) catch unreachable;
}

export fn roc_memset(dst: [*]u8, value: i32, size: usize) callconv(.C) void {
    return memset(dst, value, size);
}

extern fn kill(pid: c_int, sig: c_int) c_int;
extern fn shm_open(name: *const i8, oflag: c_int, mode: c_uint) c_int;
extern fn mmap(addr: ?*anyopaque, length: c_uint, prot: c_int, flags: c_int, fd: c_int, offset: c_uint) *anyopaque;
extern fn getppid() c_int;

fn roc_getppid() callconv(.C) c_int {
    return getppid();
}

fn roc_getppid_windows_stub() callconv(.C) c_int {
    return 0;
}

fn roc_shm_open(name: *const i8, oflag: c_int, mode: c_uint) callconv(.C) c_int {
    return shm_open(name, oflag, mode);
}
fn roc_mmap(addr: ?*anyopaque, length: c_uint, prot: c_int, flags: c_int, fd: c_int, offset: c_uint) callconv(.C) *anyopaque {
    return mmap(addr, length, prot, flags, fd, offset);
}

comptime {
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        @export(roc_getppid, .{ .name = "roc_getppid", .linkage = .strong });
        @export(roc_mmap, .{ .name = "roc_mmap", .linkage = .strong });
        @export(roc_shm_open, .{ .name = "roc_shm_open", .linkage = .strong });
    }

    if (builtin.os.tag == .windows) {
        @export(roc_getppid_windows_stub, .{ .name = "roc_getppid", .linkage = .strong });
    }
}

var model: *anyopaque = undefined;

extern fn roc__mainForHost_1_exposed_generic(*anyopaque) callconv(.C) void;
extern fn roc__mainForHost_1_exposed_size() callconv(.C) i64;

// Init Task
extern fn roc__mainForHost_0_caller(*anyopaque, *anyopaque, **anyopaque) callconv(.C) void;
extern fn roc__mainForHost_0_size() callconv(.C) i64;

// Update Fn
extern fn roc__mainForHost_1_caller(**anyopaque, PlatformState, *anyopaque, *anyopaque) callconv(.C) void;
extern fn roc__mainForHost_1_size() callconv(.C) i64;

// Update Task
extern fn roc__mainForHost_2_caller(*anyopaque, *anyopaque, **anyopaque) callconv(.C) void;
extern fn roc__mainForHost_2_size() callconv(.C) i64;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// GLOBAL VARIABLES THAT ROC CHANGES
var window_size_width: c_int = 800;
var window_size_height: c_int = 600;
var show_fps: bool = false;
var show_fps_pos_x: i32 = 10;
var show_fps_pos_y: i32 = 10;
var should_exit: bool = false;
var background_clear_color: rl.Color = rl.Color.black;

// store all the keys in a map so we can track those that are currently pressed down
// when a key is pressed it is inserted into the map, and then checked on each frame
// until it is released
var keys_down = std.AutoHashMap(rl.KeyboardKey, bool).init(allocator);

// store the cameras in a map so we pass an u64 id to roc as an opaque handle
var camera_list = std.AutoHashMap(u64, rl.Camera2D).init(allocator);
var camera_list_next_free_id: u64 = 0;

pub fn main() !void {
    var frame_count: u64 = 0;

    // SETUP WINDOW
    rl.initWindow(window_size_width, window_size_height, "hello world!");
    defer rl.closeWindow(); // Close window and OpenGL context

    rl.setTargetFPS(60); // Set our game to run at 60 frames-per-second
    rl.setConfigFlags(rl.ConfigFlags{ .window_resizable = true });

    // INIT ROC
    const size = @as(usize, @intCast(roc__mainForHost_1_exposed_size()));
    const captures = roc_alloc(size, @alignOf(u128));
    defer roc_dealloc(captures, @alignOf(u128));

    roc__mainForHost_1_exposed_generic(captures);
    roc__mainForHost_0_caller(undefined, captures, &model);

    const update_task_size = @as(usize, @intCast(roc__mainForHost_2_size()));
    const update_captures = roc_alloc(update_task_size, @alignOf(u128));

    // RUN WINDOW FRAME LOOP
    while (!rl.windowShouldClose() and !should_exit) {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(background_clear_color);

        try update_keys_down();

        const mouse_pos = rl.getMousePosition();

        const platform_state = PlatformState{
            .nanosTimestampUtc = std.time.nanoTimestamp(),
            .frameCount = frame_count,
            .keysDown = get_keys_down(),
            .mouseDown = get_mouse_down(),
            .mousePosX = mouse_pos.x,
            .mousePosY = mouse_pos.y,
        };

        // UPDATE ROC
        roc__mainForHost_1_caller(&model, platform_state, undefined, update_captures);
        roc__mainForHost_2_caller(undefined, update_captures, &model);

        if (show_fps) {
            rl.drawFPS(show_fps_pos_x, show_fps_pos_y);
        }

        frame_count += 1;
    }
}

export fn roc_fx_exit() callconv(.C) void {
    should_exit = true;
}

const ok_void = .{ .payload = .{ .ok = void{} }, .tag = .RocOk };

export fn roc_fx_setWindowSize(width: i32, height: i32) callconv(.C) RocResult(void, void) {
    rl.setWindowSize(width, height);
    return ok_void;
}

// z : I64 isn't used here it's a workaround for https://github.com/roc-lang/roc/issues/7142
const MousePos = extern struct {
    z: i64,
    x: f32,
    y: f32,
};

export fn roc_fx_getMousePosition() callconv(.C) RocResult(MousePos, void) {
    const pos = rl.getMousePosition();
    return .{ .payload = .{ .ok = MousePos{
        .x = pos.x,
        .y = pos.y,
        .z = 0,
    } }, .tag = .RocOk };
}

const ScreenSize = extern struct {
    z: i64,
    height: i32,
    width: i32,
};

export fn roc_fx_getScreenSize() callconv(.C) RocResult(ScreenSize, void) {
    const height: i32 = rl.getScreenHeight();
    const width: i32 = rl.getScreenWidth();
    return .{ .payload = .{ .ok = ScreenSize{ .height = height, .width = width, .z = 0 } }, .tag = .RocOk };
}

export fn roc_fx_drawGuiButton(x: f32, y: f32, width: f32, height: f32, text: *RocStr) callconv(.C) RocResult(i64, void) {
    const id = rg.guiButton(rl.Rectangle{ .x = x, .y = y, .width = width, .height = height }, str_to_c(text));
    return .{ .payload = .{ .ok = id }, .tag = .RocOk };
}

export fn roc_fx_guiWindowBox(x: f32, y: f32, width: f32, height: f32, text: *RocStr) callconv(.C) RocResult(i64, void) {
    const id = rg.guiWindowBox(rl.Rectangle{ .x = x, .y = y, .width = width, .height = height }, str_to_c(text));
    return .{ .payload = .{ .ok = id }, .tag = .RocOk };
}

const MouseButtons = extern struct {
    unused: i64,
    back: bool,
    extra: bool,
    forward: bool,
    left: bool,
    middle: bool,
    right: bool,
    side: bool,
};

export fn roc_fx_mouseButtons() callconv(.C) RocResult(MouseButtons, void) {
    const buttons = MouseButtons{
        .unused = 0,
        .back = rl.isMouseButtonPressed(.mouse_button_back),
        .extra = rl.isMouseButtonPressed(.mouse_button_extra),
        .forward = rl.isMouseButtonPressed(.mouse_button_forward),
        .left = rl.isMouseButtonPressed(.mouse_button_left),
        .middle = rl.isMouseButtonPressed(.mouse_button_middle),
        .right = rl.isMouseButtonPressed(.mouse_button_right),
        .side = rl.isMouseButtonPressed(.mouse_button_side),
    };
    return .{ .payload = .{ .ok = buttons }, .tag = .RocOk };
}

// TODO this is terrible, but works for now
var memory: [1000]u8 = undefined;

fn str_to_c(roc_str: *RocStr) [*:0]const u8 {
    const slice = roc_str.asSlice();

    var buffer: []u8 = &memory;

    if (slice.len > 1000) {
        @panic("unsupported, the platform only handles RocStr that are less than 1000 bytes for now");
    }

    @memcpy(buffer[0..slice.len], slice);

    buffer[slice.len] = 0;

    return @ptrCast(&memory);
}

export fn roc_fx_drawText(x: f32, y: f32, size: i32, text: *RocStr, r: u8, g: u8, b: u8, a: u8) callconv(.C) RocResult(void, void) {
    rl.drawText(str_to_c(text), @intFromFloat(x), @intFromFloat(y), size, rl.Color{ .r = r, .g = g, .b = b, .a = a });
    return ok_void;
}

export fn roc_fx_measureText(text: *RocStr, size: i32) callconv(.C) RocResult(i64, void) {
    return .{ .payload = .{ .ok = rl.measureText(str_to_c(text), size) }, .tag = .RocOk };
}

export fn roc_fx_drawRectangle(x: f32, y: f32, width: f32, height: f32, r: u8, g: u8, b: u8, a: u8) callconv(.C) RocResult(void, void) {
    rl.drawRectangle(
        @intFromFloat(x),
        @intFromFloat(y),
        @intFromFloat(width),
        @intFromFloat(height),
        rl.Color{ .r = r, .g = g, .b = b, .a = a },
    );

    return ok_void;
}

export fn roc_fx_drawCircle(centerX: f32, centerY: f32, radius: f32, r: u8, g: u8, b: u8, a: u8) callconv(.C) RocResult(void, void) {
    rl.drawCircle(
        @intFromFloat(centerX),
        @intFromFloat(centerY),
        radius,
        rl.Color{ .r = r, .g = g, .b = b, .a = a },
    );

    return ok_void;
}

export fn roc_fx_drawCircleGradient(centerX: f32, centerY: f32, radius: f32, r1: u8, g1: u8, b1: u8, a1: u8, r2: u8, g2: u8, b2: u8, a2: u8) callconv(.C) RocResult(void, void) {
    rl.drawCircleGradient(
        @intFromFloat(centerX),
        @intFromFloat(centerY),
        radius,
        rl.Color{ .r = r1, .g = g1, .b = b1, .a = a1 },
        rl.Color{ .r = r2, .g = g2, .b = b2, .a = a2 },
    );

    return ok_void;
}

export fn roc_fx_drawRectangleGradient(x: f32, y: f32, width: f32, height: f32, r1: u8, g1: u8, b1: u8, a1: u8, r2: u8, g2: u8, b2: u8, a2: u8) callconv(.C) RocResult(void, void) {
    rl.drawRectangleGradientV(
        @intFromFloat(x),
        @intFromFloat(y),
        @intFromFloat(width),
        @intFromFloat(height),
        rl.Color{ .r = r1, .g = g1, .b = b1, .a = a1 },
        rl.Color{ .r = r2, .g = g2, .b = b2, .a = a2 },
    );

    return ok_void;
}

export fn roc_fx_drawLine(startX: f32, startY: f32, endX: f32, endY: f32, r: u8, g: u8, b: u8, a: u8) callconv(.C) RocResult(void, void) {
    const start = rl.Vector2{ .x = startX, .y = startY };
    const end = rl.Vector2{ .x = endX, .y = endY };
    rl.drawLineV(start, end, rl.Color{ .r = r, .g = g, .b = b, .a = a });
    return ok_void;
}

export fn roc_fx_setWindowTitle(text: *RocStr) callconv(.C) RocResult(void, void) {
    rl.setWindowTitle(str_to_c(text));
    return ok_void;
}

export fn roc_fx_setTargetFPS(rate: i32) callconv(.C) RocResult(void, void) {
    rl.setTargetFPS(rate);
    return ok_void;
}

export fn roc_fx_setBackgroundColor(r: u8, g: u8, b: u8, a: u8) callconv(.C) RocResult(void, void) {
    background_clear_color = rl.Color{ .r = r, .g = g, .b = b, .a = a };
    return ok_void;
}

export fn roc_fx_takeScreenshot(path: *RocStr) callconv(.C) RocResult(void, void) {
    rl.takeScreenshot(str_to_c(path));
    return ok_void;
}

export fn roc_fx_setDrawFPS(show: bool, posX: f32, posY: f32) callconv(.C) RocResult(void, void) {
    show_fps = show;
    show_fps_pos_x = @intFromFloat(posX);
    show_fps_pos_y = @intFromFloat(posY);
    return ok_void;
}

export fn roc_fx_createCamera(targetX: f32, targetY: f32, offsetX: f32, offsetY: f32, rotation: f32, zoom: f32) callconv(.C) RocResult(u64, void) {
    const camera = rl.Camera2D{
        .target = rl.Vector2{
            .x = targetX,
            .y = targetY,
        },
        .offset = rl.Vector2{
            .x = offsetX,
            .y = offsetY,
        },
        .rotation = rotation,
        .zoom = zoom,
    };

    const camera_id = camera_list_next_free_id;

    camera_list.put(camera_id, camera) catch |err| switch (err) {
        error.OutOfMemory => @panic("Failed to create camera, out of memory."),
    };

    camera_list_next_free_id += 1;

    return .{ .payload = .{ .ok = camera_id }, .tag = .RocOk };
}

export fn roc_fx_updateCamera(camera_id: u64, targetX: f32, targetY: f32, offsetX: f32, offsetY: f32, rotation: f32, zoom: f32) callconv(.C) RocResult(void, void) {
    const camera_ptr = camera_list.getPtr(camera_id) orelse {
        @panic("Failed to update camera, camera not found.");
    };

    camera_ptr.target = rl.Vector2{
        .x = targetX,
        .y = targetY,
    };

    camera_ptr.offset = rl.Vector2{
        .x = offsetX,
        .y = offsetY,
    };

    camera_ptr.rotation = rotation;
    camera_ptr.zoom = zoom;

    return ok_void;
}

export fn roc_fx_beginMode2D(camera_id: u64) callconv(.C) RocResult(void, void) {
    const camera = camera_list.get(camera_id) orelse {
        @panic("Failed to begin 2D mode, camera not found.");
    };

    camera.begin();

    return ok_void;
}

export fn roc_fx_endMode2D(camera_id: u64) callconv(.C) RocResult(void, void) {
    const camera = camera_list.get(camera_id) orelse {
        @panic("Failed to end 2D mode, camera not found.");
    };

    camera.end();

    return ok_void;
}

export fn roc_fx_log(msg: *RocStr, level: u8) callconv(.C) RocResult(void, void) {
    switch (level) {
        0 => rl.traceLog(rl.TraceLogLevel.log_all, str_to_c(msg)),
        1 => rl.traceLog(rl.TraceLogLevel.log_trace, str_to_c(msg)),
        2 => rl.traceLog(rl.TraceLogLevel.log_debug, str_to_c(msg)),
        3 => rl.traceLog(rl.TraceLogLevel.log_info, str_to_c(msg)),
        4 => rl.traceLog(rl.TraceLogLevel.log_warning, str_to_c(msg)),
        5 => rl.traceLog(rl.TraceLogLevel.log_error, str_to_c(msg)),
        6 => rl.traceLog(rl.TraceLogLevel.log_fatal, str_to_c(msg)),
        7 => rl.traceLog(rl.TraceLogLevel.log_none, str_to_c(msg)),
        else => @panic("Invalid log level from roc"),
    }

    return ok_void;
}

fn update_keys_down() !void {
    var key = rl.getKeyPressed();

    // insert newly pressed keys
    while (key != rl.KeyboardKey.key_null) {
        try keys_down.put(key, true);
        key = rl.getKeyPressed();
    }

    // check all keys that are marked "down" and update if they have been released
    var iter = keys_down.iterator();
    while (iter.next()) |kv| {
        if (kv.value_ptr.*) {
            const k = kv.key_ptr.*;
            if (!rl.isKeyDown(k)) {
                try keys_down.put(k, false);
            }
        } else {
            // key hasn't been pressed, ignore it
        }
    }
}

fn get_keys_down() RocList {

    // store the keys pressed as we read from the queue... assume max 1000 queued
    var key_queue: [1000]u64 = undefined;
    var count: u64 = 0;

    var iter = keys_down.iterator();
    while (iter.next()) |kv| {
        if (kv.value_ptr.*) {
            key_queue[count] = @intCast(@intFromEnum(kv.key_ptr.*));
            count = count + 1;
        } else {
            // key hasn't been pressed, ignore it
        }
    }

    return RocList.fromSlice(u64, key_queue[0..count], false);
}

fn get_mouse_down() RocList {
    var mouse_down: [6]u64 = undefined;
    var count: u64 = 0;

    if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_left)) {
        mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_left));
        count += 1;
    }

    if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_right)) {
        mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_right));
        count += 1;
    }
    if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_middle)) {
        mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_middle));
        count += 1;
    }
    if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_side)) {
        mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_side));
        count += 1;
    }
    if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_extra)) {
        mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_extra));
        count += 1;
    }
    if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_forward)) {
        mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_forward));
        count += 1;
    }
    if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_back)) {
        mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_back));
        count += 1;
    }

    return RocList.fromSlice(u64, mouse_down[0..count], false);
}

const PlatformState = extern struct {
    nanosTimestampUtc: i128,
    frameCount: u64,
    keysDown: RocList,
    mouseDown: RocList,
    mousePosX: f32,
    mousePosY: f32,
};
