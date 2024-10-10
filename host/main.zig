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
extern fn roc__mainForHost_1_caller(**anyopaque, *anyopaque, *anyopaque) callconv(.C) void;
extern fn roc__mainForHost_1_size() callconv(.C) i64;
// Update Task
extern fn roc__mainForHost_2_caller(*anyopaque, *anyopaque, **anyopaque) callconv(.C) void;
extern fn roc__mainForHost_2_size() callconv(.C) i64;

// VARIABLES THAT ROC CHANGES
var window_size_width: c_int = 800;
var window_size_height: c_int = 600;
var show_fps: bool = true;
var should_exit: bool = false;

pub fn main() void {

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

        rl.clearBackground(rl.Color.black);

        // UPDATE ROC
        roc__mainForHost_1_caller(&model, undefined, update_captures);
        roc__mainForHost_2_caller(undefined, update_captures, &model);
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

export fn roc_fx_drawText(x: i32, y: i32, size: i32, text: *RocStr, r: u8, g: u8, b: u8, a: u8) callconv(.C) RocResult(void, void) {
    rl.drawText(str_to_c(text), x, y, size, rl.Color{ .r = r, .g = g, .b = b, .a = a });
    return ok_void;
}

export fn roc_fx_measureText(text: *RocStr, size: i32) callconv(.C) RocResult(i64, void) {
    return .{ .payload = .{ .ok = rl.measureText(str_to_c(text), size) }, .tag = .RocOk };
}

export fn roc_fx_drawRectangle(x: i32, y: i32, width: i32, height: i32, r: u8, g: u8, b: u8, a: u8) callconv(.C) RocResult(void, void) {
    rl.drawRectangle(x, y, width, height, rl.Color{ .r = r, .g = g, .b = b, .a = a });

    return ok_void;
}

export fn roc_fx_drawCircle(centerX: i32, centerY: i32, radius: f32, r: u8, g: u8, b: u8, a: u8) callconv(.C) RocResult(void, void) {
    rl.drawCircle(centerX, centerY, radius, rl.Color{ .r = r, .g = g, .b = b, .a = a });

    return ok_void;
}

export fn roc_fx_drawCircleGradient(centerX: i32, centerY: i32, radius: f32, r1: u8, g1: u8, b1: u8, a1: u8, r2: u8, g2: u8, b2: u8, a2: u8) callconv(.C) RocResult(void, void) {
    rl.drawCircleGradient(
        centerX,
        centerY,
        radius,
        rl.Color{ .r = r1, .g = g1, .b = b1, .a = a1 },
        rl.Color{ .r = r2, .g = g2, .b = b2, .a = a2 },
    );

    return ok_void;
}

export fn roc_fx_drawRectangleGradientV(x: i32, y: i32, width: i32, height: i32, r1: u8, g1: u8, b1: u8, a1: u8, r2: u8, g2: u8, b2: u8, a2: u8) callconv(.C) RocResult(void, void) {
    rl.drawRectangleGradientV(
        x,
        y,
        width,
        height,
        rl.Color{ .r = r1, .g = g1, .b = b1, .a = a1 },
        rl.Color{ .r = r2, .g = g2, .b = b2, .a = a2 },
    );

    return ok_void;
}

export fn roc_fx_setWindowTitle(text: *RocStr) callconv(.C) RocResult(void, void) {
    rl.setWindowTitle(str_to_c(text));
    return ok_void;
}
