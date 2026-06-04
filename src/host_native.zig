///! Platform host for roc-ray using the raylib graphics library.
const std = @import("std");
const builtin = @import("builtin");

// Import generated platform ABI (use for hosted function arg/ret types)
const abi = @import("roc_platform_abi.zig");

// Import FFI conversion utilities
const ffi = @import("roc_ffi.zig");

// Import backend
const raylib = @import("backend_raylib.zig");

// Type aliases
const RocBox = ffi.RocBox;
const RocResult = ffi.Try(ffi.RocBox, i64);
const RenderArgs = ffi.RenderArgs;
const RocOps = ffi.RocOps;
// read_env! returns Try(Str, [NotFound, ..]); the generated `abi.Try` (payload
// union of RocStr/err-ptr) is the correct 32-byte layout for it.
const ReadEnvResult = abi.Try;

const TRACE_HOST = false;

/// Global flag to track if dbg or expect_failed was called.
/// If set, program exits with non-zero code to prevent accidental commits.
var debug_or_expect_called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Captured `envp` for the process. On Linux the host runs with `-nostdlib`, so
/// glibc never populates an environ global; we capture it from the process stack
/// in `platform_main`. Other (libc-linked) targets read `std.c.environ` instead.
var host_environ: []const [*:0]u8 = &.{};

/// Look up an environment variable without `std.posix.getenv` (removed in 0.16).
/// Scans `host_environ`, which is captured once in `platform_main`.
fn hostGetEnv(key: []const u8) ?[]const u8 {
    for (host_environ) |entry| {
        if (matchEnvEntry(std.mem.span(entry), key)) |value| return value;
    }
    return null;
}

/// If `entry` is `KEY=VALUE` for the given `key`, return `VALUE`.
fn matchEnvEntry(entry: [:0]const u8, key: []const u8) ?[]const u8 {
    if (entry.len > key.len and entry[key.len] == '=' and std.mem.eql(u8, entry[0..key.len], key)) {
        return entry[key.len + 1 ..];
    }
    return null;
}

/// Custom dbg handler that sets flag and prints to stderr.
fn nativeDbg(dbg_args: *const abi.RocDbg, _: *anyopaque) callconv(.c) void {
    debug_or_expect_called.store(true, .release);
    const msg = dbg_args.utf8_bytes[0..dbg_args.len];
    std.debug.print("\x1b[36m[ROC DBG]\x1b[0m {s}\n", .{msg});
}

/// Custom expect handler that sets flag and prints to stderr.
fn nativeExpectFailed(expect_args: *const abi.RocExpectFailed, _: *anyopaque) callconv(.c) void {
    debug_or_expect_called.store(true, .release);
    const msg = expect_args.utf8_bytes[0..expect_args.len];
    std.debug.print("\x1b[33m[ROC EXPECT]\x1b[0m {s}\n", .{msg});
}

/// Crash handler - prints to stderr and exits.
fn nativeCrashed(crash_args: *const abi.RocCrashed, _: *anyopaque) callconv(.c) void {
    const msg = crash_args.utf8_bytes[0..crash_args.len];
    std.debug.print("\x1b[31m[ROC CRASHED]\x1b[0m {s}\n", .{msg});
    std.process.exit(1);
}


// OS-specific entry point handling (not exported during tests)
comptime {
    if (!builtin.is_test) {
        // Export main for all platforms (including WASM/emscripten)
        @export(&main, .{ .name = "main" });

        // Windows MinGW/MSVCRT compatibility: export __main stub
        if (builtin.os.tag == .windows) {
            @export(&__main, .{ .name = "__main" });
        }
    }
}

// Windows MinGW/MSVCRT compatibility stub
// The C runtime on Windows calls __main from main for constructor initialization
fn __main() callconv(.c) void {}

// C compatible main for runtime
fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return platform_main(@intCast(argc), argv);
}

fn hostedDrawBeginFrame(_: *RocOps, _: *anyopaque, _: *anyopaque) callconv(.c) void {
    raylib.beginDrawing();
}

fn hostedDrawCircle(_: *RocOps, _: *anyopaque, args: *const abi.DrawCircleArgs) callconv(.c) void {
    raylib.drawCircle(args.*);
}

fn hostedDrawCircleGradient(_: *RocOps, _: *anyopaque, args: *const abi.DrawCircle_gradientArgs) callconv(.c) void {
    raylib.drawCircleGradient(args.*);
}

fn hostedDrawClear(_: *RocOps, _: *anyopaque, args: *const abi.DrawClearArgs) callconv(.c) void {
    raylib.clearBackground(args.arg0);
}

fn hostedDrawEndFrame(_: *RocOps, _: *anyopaque, _: *anyopaque) callconv(.c) void {
    // Show FPS counter in debug builds
    if (builtin.mode == .Debug) {
        raylib.drawFps(10, 10);
    }

    raylib.endDrawing();
}

fn hostedDrawLine(_: *RocOps, _: *anyopaque, args: *const abi.DrawLineArgs) callconv(.c) void {
    raylib.drawLine(args.*);
}

fn hostedDrawRectangle(_: *RocOps, _: *anyopaque, args: *const abi.DrawRectangleArgs) callconv(.c) void {
    raylib.drawRectangle(args.*);
}

fn hostedDrawRectangleGradientH(_: *RocOps, _: *anyopaque, args: *const abi.DrawRectangle_gradient_hArgs) callconv(.c) void {
    raylib.drawRectangleGradientH(args.*);
}

fn hostedDrawRectangleGradientV(_: *RocOps, _: *anyopaque, args: *const abi.DrawRectangle_gradient_vArgs) callconv(.c) void {
    raylib.drawRectangleGradientV(args.*);
}

fn hostedDrawText(_: *RocOps, _: *anyopaque, args: *const abi.DrawTextArgs) callconv(.c) void {
    const text_slice = args.text.asSlice();

    // raylib expects null-terminated string, use stack buffer for small strings
    var buf: [256:0]u8 = undefined;
    if (text_slice.len < buf.len) {
        @memcpy(buf[0..text_slice.len], text_slice);
        buf[text_slice.len] = 0;
        raylib.drawTextZ(buf[0..text_slice.len :0], @intFromFloat(args.pos.x), @intFromFloat(args.pos.y), args.size, args.color);
    }
}

/// Global flag for deferred exit request (exit after current frame completes)
var exit_requested: ?i64 = null;

fn hostedReadEnvWindows(_: *RocOps, result: *ReadEnvResult, _: *const abi.HostRead_envArgs) callconv(.c) void {
    // Windows doesn't link libc, so env var reading is not yet supported
    result.tag = .Err;
}

fn hostedReadEnvPosix(ops: *RocOps, result: *ReadEnvResult, args: *const abi.HostRead_envArgs) callconv(.c) void {
    const key = args.arg1.asSlice();
    const value = hostGetEnv(key);

    if (value) |v| {
        result.payload = .{ .ok = abi.RocStr.fromSlice(v, ops) };
        result.tag = .Ok;
    } else {
        result.tag = .Err;
    }
}

fn hostedExit(_: *RocOps, _: *anyopaque, args: *const abi.HostExitArgs) callconv(.c) void {
    exit_requested = @as(i64, args.arg0);
}

fn hostedGetScreenSize(_: *RocOps, result: *abi.HostGet_screen_sizeRetRecord, _: *anyopaque) callconv(.c) void {
    result.* = .{ .height = raylib.getScreenHeight(), .width = raylib.getScreenWidth() };
}

fn hostedSetScreenSize(_: *RocOps, result: *ffi.Try(void, void), args: *const abi.HostSet_screen_sizeArgs) callconv(.c) void {
    raylib.setWindowSize(@intFromFloat(args.width), @intFromFloat(args.height));
    result.tag = .Ok;
}

fn hostedSetTargetFps(_: *RocOps, _: *anyopaque, args: *const abi.HostSet_target_fpsArgs) callconv(.c) void {
    raylib.setTargetFps(args.arg0);
}

/// Hosted function dispatch table built from PlatformHostedFns.
const hosted_fns = abi.hostedFunctions(.{
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
    .host_read_env = if (builtin.os.tag == .windows) &hostedReadEnvWindows else &hostedReadEnvPosix,
    // set_screen_size! returns Try({}, [NotSupported, ..]), whose real layout is
    // smaller than the glue's shared `Try` type (the glue deduplicates both Try
    // result types by name). Use the correctly-sized `ffi.Try(void, void)` and
    // cast past the dispatch field type. TODO: drop the cast once glue emits a
    // distinct type per Try instantiation.
    .host_set_screen_size = @ptrCast(&hostedSetScreenSize),
    .host_set_target_fps = &hostedSetTargetFps,
});

/// Platform host entrypoint
fn platform_main(argc: usize, argv: [*][*:0]u8) c_int {
    // Capture envp on Linux. Roc links with -nostdlib, so glibc's
    // __libc_start_main (which normally initializes environ) doesn't run. We
    // manually extract envp from the stack where the kernel placed it:
    // [argc, argv..., NULL, envp..., NULL, auxv...]
    if (comptime builtin.os.tag == .linux) {
        const envp_ptr: [*][*:0]u8 = @ptrCast(argv + argc + 1);
        var envp_len: usize = 0;
        while (@intFromPtr(envp_ptr[envp_len]) != 0) : (envp_len += 1) {}
        host_environ = envp_ptr[0..envp_len];
    } else if (comptime builtin.os.tag != .windows) {
        // libc-linked targets (e.g. macOS): use the C runtime's environ global.
        var n: usize = 0;
        while (std.c.environ[n] != null) : (n += 1) {}
        host_environ = @as([*]const [*:0]u8, @ptrCast(std.c.environ))[0..n];
    }

    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer {
        if (gpa.deinit() == .leak) std.log.warn("Memory leak detected", .{});
    }

    // The Roc runtime environment: allocator + I/O backend. We supply our own
    // dbg/expect/crashed handlers below, so the I/O backend (only used by the
    // generated DefaultHandlers) is left as a no-op freestanding implementation.
    var roc_env = abi.RocEnv{
        .allocator = gpa.allocator(),
        .roc_io = abi.RocIo.freestanding(),
    };

    // Create the RocOps struct
    var roc_ops = RocOps{
        .env = @ptrCast(&roc_env),
        .roc_alloc = &abi.DefaultAllocators.rocAlloc,
        .roc_dealloc = &abi.DefaultAllocators.rocDealloc,
        .roc_realloc = &abi.DefaultAllocators.rocRealloc,
        .roc_dbg = &nativeDbg,
        .roc_expect_failed = &nativeExpectFailed,
        .roc_crashed = &nativeCrashed,
        .hosted_fns = hosted_fns,
    };

    // Keyboard state manager (handles RocList allocation and refcounting)
    // We incref before each pass to Roc, and Roc decrefs when it drops the old Host.
    var keys = ffi.Keys.init(&roc_ops);
    defer keys.decref();

    // Initialize raylib window
    raylib.initWindow(800, 600, "Roc + Raylib");
    defer raylib.closeWindow();
    raylib.setTargetFps(60);

    // Call Roc init! to build the initial model
    if (TRACE_HOST) std.log.debug("[HOST] Calling roc__init_for_host...", .{});

    var boxed_model: RocBox = null;
    {
        var init_result: RocResult = undefined;
        // Create initial host state for init (frame 0, no input)
        keys.incref(); // Prevent Roc from freeing our list
        var init_state = abi.Host{
            .frame_count = 0,
            .keys = keys.list,
            .mouse = .{ .wheel = 0, .x = 0, .y = 0, .left = false, .right = false, .middle = false },
        };
        abi.roc__init_for_host(&roc_ops, @ptrCast(&init_result), @ptrCast(&init_state));

        if (TRACE_HOST) std.log.debug("[HOST] init returned, tag={d}", .{@intFromEnum(init_result.tag)});

        if (init_result.isErr()) {
            const err_code = init_result.getErr();
            if (TRACE_HOST) std.log.debug("[HOST] init returned Err({d})", .{err_code});
            // Ensure non-zero exit code (use 1 if err_code is 0 due to Roc wildcard match bug)
            return if (err_code == 0) 1 else @intCast(err_code);
        }

        boxed_model = init_result.getOk();
    }

    raylib.setTargetFps(240);

    // Main render loop
    var exit_code: i32 = 0;
    var frame_count: u64 = 0;

    while (!raylib.windowShouldClose()) {
        // Capture real inputs from raylib
        raylib.updateKeyboardState();
        keys.update(raylib.getKeyState());
        keys.incref(); // Prevent Roc from freeing our list
        const mouse_pos = raylib.getMousePosition();
        const platform_state = abi.Host{
            .frame_count = frame_count,
            .keys = keys.list,
            .mouse = .{
                .left = raylib.isMouseButtonDown(.left),
                .middle = raylib.isMouseButtonDown(.middle),
                .right = raylib.isMouseButtonDown(.right),
                .wheel = raylib.getMouseWheelMove(),
                .x = mouse_pos.x,
                .y = mouse_pos.y,
            },
        };

        // Call Roc render with the platform state
        var render_args = RenderArgs{ .model = boxed_model, .state = platform_state };
        var render_result: RocResult = undefined;
        abi.roc__render_for_host(&roc_ops, @ptrCast(&render_result), @ptrCast(&render_args));

        if (render_result.isErr()) {
            exit_code = @intCast(render_result.getErr());
            if (TRACE_HOST) std.log.debug("[HOST] render returned Err({d})", .{exit_code});
            break;
        }

        // Update boxed_model for next iteration
        boxed_model = render_result.getOk();
        frame_count += 1;

        // Check for exit request (deferred exit after frame completes)
        if (exit_requested) |code| {
            exit_code = @intCast(code);
            break;
        }
    }

    // Clean up final model (always clean up if we have one, regardless of exit code)
    if (boxed_model) |model| {
        if (TRACE_HOST) std.log.debug("[HOST] Decrementing refcount for final model box=0x{x}", .{@intFromPtr(model)});
        ffi.decrefBox(model, &roc_ops);
    }

    // If dbg or expect_failed was called, ensure non-zero exit code
    // to prevent accidental commits with debug statements or failing tests
    if (debug_or_expect_called.load(.acquire) and exit_code == 0) {
        return 1;
    }

    return exit_code;
}
