const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

// const w4 = @import("vendored/wasm4.zig");

const str = @import("vendored/str.zig");
const RocStr = str.RocStr;

const list = @import("vendored/list.zig");
const RocList = list.RocList;

const utils = @import("vendored/utils.zig");

const raylib = @import("raylib");
// const raygui = @import("raygui");

const DEBUG: bool = false;

const Align = 2 * @alignOf(usize);

extern fn malloc(size: usize) callconv(.C) ?*align(Align) anyopaque;
extern fn realloc(c_ptr: [*]align(Align) u8, size: usize) callconv(.C) ?*anyopaque;
extern fn free(c_ptr: [*]align(Align) u8) callconv(.C) void;
extern fn memcpy(dst: [*]u8, src: [*]u8, size: usize) callconv(.C) void;
extern fn memset(dst: [*]u8, value: i32, size: usize) callconv(.C) void;

export fn roc_alloc(size: usize, alignment: u32) callconv(.C) ?*anyopaque {
    if (DEBUG) {
        var ptr = malloc(size);
        const stdout = std.io.getStdOut().writer();
        stdout.print("alloc:   {d} (alignment {d}, size {d})\n", .{ ptr, alignment, size }) catch unreachable;
        return ptr;
    } else {
        return malloc(size);
    }
}

export fn roc_realloc(old_ptr: *anyopaque, new_size: usize, old_size: usize, alignment: u32) callconv(.C) ?*anyopaque {
    if (DEBUG) {
        const stdout = std.io.getStdOut().writer();
        stdout.print("realloc: {d} (alignment {d}, old_size {d})\n", .{ old_ptr, alignment, old_size }) catch unreachable;
    }

    return realloc(@as([*]align(Align) u8, @alignCast(@ptrCast(old_ptr))), new_size);
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
    // const msg = @as([*:0]const u8, @ptrCast(c_ptr));
    stderr.print("\n\nRoc crashed with the following error;\nMSG:{s}\nTAG:{d}\n\nShutting down\n", .{ msg.asSlice(), tag_id }) catch unreachable;
    std.process.exit(0);
}

export fn roc_dbg(loc: *RocStr, msg: *RocStr, src: *RocStr) callconv(.C) void {
    _ = loc;
    _ = src;
    _ = msg;

    @panic("Roc dbg not implemented");
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
        @export(roc_getppid, .{ .name = "roc_getppid", .linkage = .Strong });
        @export(roc_mmap, .{ .name = "roc_mmap", .linkage = .Strong });
        @export(roc_shm_open, .{ .name = "roc_shm_open", .linkage = .Strong });
    }

    if (builtin.os.tag == .windows) {
        @export(roc_getppid_windows_stub, .{ .name = "roc_getppid", .linkage = .Strong });
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

// export fn start() void {
//     const update_size = @as(usize, @intCast(roc__mainForHost_1_size()));
//     if (update_size != 0) {
//         w4.trace("This platform does not allow for the update function to have captures");
//         @panic("Invalid roc app: captures not allowed");
//     }

//     const size = @as(usize, @intCast(roc__mainForHost_1_exposed_size()));
//     const captures = roc_alloc(size, @alignOf(u128));
//     defer roc_dealloc(captures, @alignOf(u128));

//     roc__mainForHost_1_exposed_generic(captures);
//     roc__mainForHost_0_caller(undefined, captures, &model);

//     const update_task_size = @as(usize, @intCast(roc__mainForHost_2_size()));
//     update_captures = roc_alloc(update_task_size, @alignOf(u128));
// }

var update_captures: *anyopaque = undefined;

// export fn update() void {
//     roc__mainForHost_1_caller(&model, undefined, update_captures);
//     roc__mainForHost_2_caller(undefined, update_captures, &model);
// }

pub fn main() void {

    // THIS CODE EXAMPLE IS USING BOTH RAYLIB AND RAYGUI
    // raylib.InitWindow(800, 800, "hello world!");
    // raylib.SetConfigFlags(raylib.ConfigFlags{ .FLAG_WINDOW_RESIZABLE = true });
    // raylib.SetTargetFPS(60);

    // defer raylib.CloseWindow();

    // while (!raylib.WindowShouldClose()) {
    //     raylib.BeginDrawing();
    //     defer raylib.EndDrawing();

    //     raylib.ClearBackground(raylib.BLACK);
    //     raylib.DrawFPS(10, 10);

    //     if (1 == raygui.GuiButton(.{ .x = 100, .y = 100, .width = 200, .height = 100 }, "press me!")) {
    //         std.debug.print("pressed\n", .{});
    //     }
    // }

    // THIS CODE EXAMPLE IS ONLY USING RAYLIB
    raylib.SetConfigFlags(raylib.ConfigFlags{ .FLAG_WINDOW_RESIZABLE = true });
    raylib.InitWindow(800, 800, "hello world!");
    raylib.SetTargetFPS(60);

    defer raylib.CloseWindow();

    while (!raylib.WindowShouldClose()) {
        raylib.BeginDrawing();
        defer raylib.EndDrawing();

        raylib.ClearBackground(raylib.BLACK);
        raylib.DrawFPS(10, 10);

        raylib.DrawText("hello world!", 100, 100, 20, raylib.YELLOW);
    }
}
