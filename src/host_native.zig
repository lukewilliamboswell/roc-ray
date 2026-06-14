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
const HostState = ffi.HostState;
const RocOps = ffi.RocOps;
// read_env! returns Try(Str, [NotFound, ..]); the generated `abi.Try` (payload
// union of RocStr/err-ptr) is the correct 32-byte layout for it.
const ReadEnvResult = abi.Try;
const AppConfig = abi.__AnonStruct77;

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
fn nativeDbg(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    debug_or_expect_called.store(true, .release);
    const msg = bytes[0..len];
    std.debug.print("\x1b[36m[ROC DBG]\x1b[0m {s}\n", .{msg});
}

/// Custom expect handler that sets flag and prints to stderr.
fn nativeExpectFailed(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    debug_or_expect_called.store(true, .release);
    const msg = bytes[0..len];
    std.debug.print("\x1b[33m[ROC EXPECT]\x1b[0m {s}\n", .{msg});
}

/// Crash handler - prints to stderr and exits.
fn nativeCrashed(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    const msg = bytes[0..len];
    std.debug.print("\x1b[31m[ROC CRASHED]\x1b[0m {s}\n", .{msg});
    std.process.exit(1);
}

fn exportedRocAlloc(ops: *RocOps, length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return abi.DefaultAllocators.rocAlloc(ops, length, alignment);
}

fn exportedRocDealloc(ops: *RocOps, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    abi.DefaultAllocators.rocDealloc(ops, ptr, alignment);
}

fn exportedRocRealloc(ops: *RocOps, ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return abi.DefaultAllocators.rocRealloc(ops, ptr, new_length, alignment);
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

const CSTRING_STACK_CAPACITY: usize = 1024;

const TempCString = struct {
    ptr: [*:0]const u8,
    heap: ?[]u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *TempCString) void {
        if (self.heap) |buf| self.allocator.free(buf);
    }
};

fn allocatorFromOps(ops: *RocOps) std.mem.Allocator {
    const env: *abi.RocEnv = @ptrCast(@alignCast(ops.env));
    return env.allocator;
}

fn makeTempCString(allocator: std.mem.Allocator, stack: *[CSTRING_STACK_CAPACITY:0]u8, bytes: []const u8) !TempCString {
    const c_len = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    const c_bytes = bytes[0..c_len];

    if (c_len < stack.len) {
        @memcpy(stack[0..c_len], c_bytes);
        stack[c_len] = 0;
        return .{ .ptr = stack[0..c_len :0].ptr, .heap = null, .allocator = allocator };
    }

    const heap = try allocator.alloc(u8, c_len + 1);
    @memcpy(heap[0..c_len], c_bytes);
    heap[c_len] = 0;

    return .{ .ptr = heap[0..c_len :0].ptr, .heap = heap, .allocator = allocator };
}

fn positiveCInt(value: i32, fallback: c_int) c_int {
    return if (value > 0) @as(c_int, @intCast(value)) else fallback;
}

fn targetFpsCInt(value: i32) c_int {
    return if (value >= 0) @as(c_int, @intCast(value)) else 0;
}

test "makeTempCString uses stack storage for small strings" {
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var c_string = try makeTempCString(std.testing.allocator, &stack, "hello");
    defer c_string.deinit();

    try std.testing.expect(c_string.heap == null);
    try std.testing.expectEqualStrings("hello", std.mem.span(c_string.ptr));
}

test "makeTempCString allocates long strings" {
    var bytes: [CSTRING_STACK_CAPACITY + 10]u8 = undefined;
    @memset(&bytes, 'x');

    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var c_string = try makeTempCString(std.testing.allocator, &stack, bytes[0..]);
    defer c_string.deinit();

    try std.testing.expect(c_string.heap != null);
    try std.testing.expectEqual(@as(usize, CSTRING_STACK_CAPACITY + 10), std.mem.span(c_string.ptr).len);
}

test "makeTempCString stops at embedded nul" {
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var c_string = try makeTempCString(std.testing.allocator, &stack, "before\x00after");
    defer c_string.deinit();

    try std.testing.expectEqualStrings("before", std.mem.span(c_string.ptr));
}

fn hostedAssetsLoadTextureRaw(ops: *RocOps, path_arg: abi.RocStr) callconv(.c) abi.__AnonStruct0 {
    defer path_arg.decref(ops);
    var result: abi.__AnonStruct0 = .{ .handle = 0, .height = 0, .width = 0 };

    const path_slice = path_arg.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromOps(ops), &stack, path_slice) catch return result;
    defer path.deinit();

    if (raylib.loadTexture(path.ptr)) |texture| {
        result = .{
            .handle = texture.handle,
            .height = texture.height,
            .width = texture.width,
        };
    }

    return result;
}

fn hostedDrawBeginFrame() callconv(.c) void {
    raylib.beginDrawing();
}

fn hostedDrawCircleRaw(args: abi.__AnonStruct10) callconv(.c) void {
    raylib.drawCircle(args);
}

fn hostedDrawCircleGradient(args: abi.__AnonStruct15) callconv(.c) void {
    raylib.drawCircleGradient(args);
}

fn hostedDrawCircleLinesRaw(args: abi.__AnonStruct16) callconv(.c) void {
    raylib.drawCircleLines(args);
}

fn hostedDrawClear(color: abi.Color) callconv(.c) void {
    raylib.clearBackground(color);
}

fn hostedDrawEndFrame() callconv(.c) void {
    raylib.endDrawing();
}

fn hostedDrawFps(args: abi.__AnonStruct17) callconv(.c) void {
    raylib.drawFps(args);
}

fn hostedDrawLineRaw(args: abi.__AnonStruct18) callconv(.c) void {
    raylib.drawLine(args);
}

fn hostedDrawPolygonRaw(ops: *RocOps, args: abi.__AnonStruct25) callconv(.c) void {
    defer args.points.decref(ops);
    raylib.drawPolygon(args.points.items(), args.color);
}

fn hostedDrawPolygonLinesRaw(ops: *RocOps, args: abi.__AnonStruct27) callconv(.c) void {
    defer args.points.decref(ops);
    raylib.drawPolygonLines(args.points.items(), args.thickness, args.color);
}

fn hostedDrawRectangleRaw(args: abi.__AnonStruct28) callconv(.c) void {
    raylib.drawRectangle(args);
}

fn hostedDrawRectangleLinesRaw(args: abi.__AnonStruct31) callconv(.c) void {
    raylib.drawRectangleLines(args);
}

fn hostedDrawRectangleGradientH(args: abi.__AnonStruct29) callconv(.c) void {
    raylib.drawRectangleGradientH(args);
}

fn hostedDrawRectangleGradientV(args: abi.__AnonStruct30) callconv(.c) void {
    raylib.drawRectangleGradientV(args);
}

fn hostedDrawRoundedRectangleRaw(args: abi.__AnonStruct32) callconv(.c) void {
    raylib.drawRoundedRectangle(args);
}

fn hostedDrawRoundedRectangleLinesRaw(args: abi.__AnonStruct33) callconv(.c) void {
    raylib.drawRoundedRectangleLines(args);
}

fn hostedDrawTriangleRaw(args: abi.__AnonStruct38) callconv(.c) void {
    raylib.drawTriangle(args);
}

fn hostedDrawTriangleLinesRaw(args: abi.__AnonStruct39) callconv(.c) void {
    raylib.drawTriangleLines(args);
}

fn hostedDrawLoadFontRaw(ops: *RocOps, args: abi.__AnonStruct20) callconv(.c) u64 {
    defer args.path.decref(ops);

    const path_slice = args.path.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromOps(ops), &stack, path_slice) catch return 0;
    defer path.deinit();

    return raylib.loadFont(path.ptr, args.size) orelse 0;
}

fn hostedDrawMeasureTextRaw(ops: *RocOps, args: abi.__AnonStruct24) callconv(.c) abi.__AnonStruct23 {
    defer args.text.decref(ops);
    var result: abi.__AnonStruct23 = .{ .height = 0, .width = 0 };

    const text_slice = args.text.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var text = makeTempCString(allocatorFromOps(ops), &stack, text_slice) catch return result;
    defer text.deinit();

    const measured = raylib.measureTextZ(text.ptr, args.font, args.size, args.spacing);
    result = .{ .height = measured.y, .width = measured.x };
    return result;
}

fn hostedDrawTextRaw(ops: *RocOps, args: abi.__AnonStruct34) callconv(.c) void {
    defer args.text.decref(ops);

    const text_slice = args.text.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var text = makeTempCString(allocatorFromOps(ops), &stack, text_slice) catch return;
    defer text.deinit();

    raylib.drawTextZ(
        text.ptr,
        args.font,
        .{ .x = args.pos.x, .y = args.pos.y },
        args.size,
        args.spacing,
        args.color,
    );
}

fn hostedDrawTextureRaw(args: abi.__AnonStruct35) callconv(.c) void {
    raylib.drawTexture(args);
}

/// Global flag for deferred exit request (exit after current frame completes)
var exit_requested: ?i64 = null;

fn decrefHostArg(ops: *RocOps, host: *const abi.Host) void {
    host.keys.decref(ops);
    host.keys_pressed.decref(ops);
    host.keys_released.decref(ops);
    host.mouse.buttons.decref(ops);
    host.mouse.buttons_pressed.decref(ops);
    host.mouse.buttons_released.decref(ops);
}

fn hostedReadEnvWindows(ops: *RocOps, host: abi.Host, key_arg: abi.RocStr) callconv(.c) ReadEnvResult {
    // Windows doesn't link libc, so env var reading is not yet supported
    var result: ReadEnvResult = undefined;
    result.tag = .Err;

    // Roc transfers ownership of refcounted args to the hosted fn; release them.
    decrefHostArg(ops, &host);
    key_arg.decref(ops);
    return result;
}

fn hostedReadEnvPosix(ops: *RocOps, host: abi.Host, key_arg: abi.RocStr) callconv(.c) ReadEnvResult {
    var result: ReadEnvResult = undefined;
    const key = key_arg.asSlice();
    const value = hostGetEnv(key);

    if (value) |v| {
        result.payload = .{ .ok = abi.RocStr.fromSlice(v, ops) };
        result.tag = .Ok;
    } else {
        result.tag = .Err;
    }

    // Roc transfers ownership of refcounted args to the hosted fn; release them.
    // `key` (a slice into key_arg) is fully consumed above before key_arg is dropped.
    decrefHostArg(ops, &host);
    key_arg.decref(ops);
    return result;
}

fn hostedExit(code: i32) callconv(.c) void {
    exit_requested = @as(i64, code);
}

fn hostedGetScreenSize() callconv(.c) abi.__AnonStruct42 {
    return .{ .height = raylib.getScreenHeight(), .width = raylib.getScreenWidth() };
}

fn hostedSetScreenSize(args: abi.__AnonStruct55) callconv(.c) abi.Try {
    raylib.setWindowSize(@intFromFloat(args.width), @intFromFloat(args.height));
    var result: abi.Try = undefined;
    result.tag = .Ok;
    return result;
}

fn hostedSetTargetFps(fps: i32) callconv(.c) void {
    raylib.setTargetFps(fps);
}

fn hostedRandomI32(min: i32, max: i32) callconv(.c) i32 {
    return raylib.getRandomValue(min, max);
}

fn hostedAudioGenTone(args: abi.__AnonStruct5) callconv(.c) u64 {
    return @intCast(raylib.genTone(args.freq, args.ms));
}

fn hostedAudioPlay(handle: u64) callconv(.c) void {
    raylib.playSoundHandle(@intCast(handle));
}

comptime {
    if (!builtin.is_test) {
        @export(&exportedRocAlloc, .{ .name = "roc_alloc" });
        @export(&exportedRocDealloc, .{ .name = "roc_dealloc" });
        @export(&exportedRocRealloc, .{ .name = "roc_realloc" });
        @export(&nativeDbg, .{ .name = "roc_dbg" });
        @export(&nativeExpectFailed, .{ .name = "roc_expect_failed" });
        @export(&nativeCrashed, .{ .name = "roc_crashed" });

        @export(&hostedAssetsLoadTextureRaw, .{ .name = "roc_assets_load_texture_raw" });
        @export(&hostedAudioGenTone, .{ .name = "roc_audio_gen_tone_raw" });
        @export(&hostedAudioPlay, .{ .name = "roc_audio_play_raw" });
        @export(&hostedDrawBeginFrame, .{ .name = "roc_draw_begin_frame" });
        @export(&hostedDrawCircleGradient, .{ .name = "roc_draw_circle_gradient" });
        @export(&hostedDrawCircleLinesRaw, .{ .name = "roc_draw_circle_lines_raw" });
        @export(&hostedDrawCircleRaw, .{ .name = "roc_draw_circle_raw" });
        @export(&hostedDrawClear, .{ .name = "roc_draw_clear" });
        @export(&hostedDrawTextureRaw, .{ .name = "roc_draw_draw_texture_raw" });
        @export(&hostedDrawEndFrame, .{ .name = "roc_draw_end_frame" });
        @export(&hostedDrawFps, .{ .name = "roc_draw_fps" });
        @export(&hostedDrawLineRaw, .{ .name = "roc_draw_line_raw" });
        @export(&hostedDrawLoadFontRaw, .{ .name = "roc_draw_load_font_raw" });
        @export(&hostedDrawMeasureTextRaw, .{ .name = "roc_draw_measure_text_raw" });
        @export(&hostedDrawPolygonLinesRaw, .{ .name = "roc_draw_polygon_lines_raw" });
        @export(&hostedDrawPolygonRaw, .{ .name = "roc_draw_polygon_raw" });
        @export(&hostedDrawRectangleGradientH, .{ .name = "roc_draw_rectangle_gradient_h" });
        @export(&hostedDrawRectangleGradientV, .{ .name = "roc_draw_rectangle_gradient_v" });
        @export(&hostedDrawRectangleLinesRaw, .{ .name = "roc_draw_rectangle_lines_raw" });
        @export(&hostedDrawRectangleRaw, .{ .name = "roc_draw_rectangle_raw" });
        @export(&hostedDrawRoundedRectangleLinesRaw, .{ .name = "roc_draw_rounded_rectangle_lines_raw" });
        @export(&hostedDrawRoundedRectangleRaw, .{ .name = "roc_draw_rounded_rectangle_raw" });
        @export(&hostedDrawTextRaw, .{ .name = "roc_draw_text_raw" });
        @export(&hostedDrawTriangleLinesRaw, .{ .name = "roc_draw_triangle_lines_raw" });
        @export(&hostedDrawTriangleRaw, .{ .name = "roc_draw_triangle_raw" });
        @export(&hostedExit, .{ .name = "roc_host_exit" });
        @export(&hostedGetScreenSize, .{ .name = "roc_host_get_screen_size" });
        @export(&hostedRandomI32, .{ .name = "roc_host_random_i32" });
        @export(if (builtin.os.tag == .windows) &hostedReadEnvWindows else &hostedReadEnvPosix, .{ .name = "roc_host_read_env" });
        @export(&hostedSetScreenSize, .{ .name = "roc_host_set_screen_size" });
        @export(&hostedSetTargetFps, .{ .name = "roc_host_set_target_fps" });
    }
}

/// Hosted function dispatch table built from PlatformHostedFns.
const hosted_fns = abi.hostedFunctions(.{
    .assets_load_texture_raw = &hostedAssetsLoadTextureRaw,
    .audio_gen_tone_raw = &hostedAudioGenTone,
    .audio_play_raw = &hostedAudioPlay,
    .draw_begin_frame = &hostedDrawBeginFrame,
    .draw_circle_gradient = &hostedDrawCircleGradient,
    .draw_circle_lines_raw = &hostedDrawCircleLinesRaw,
    .draw_circle_raw = &hostedDrawCircleRaw,
    .draw_clear = &hostedDrawClear,
    .draw_draw_texture_raw = &hostedDrawTextureRaw,
    .draw_end_frame = &hostedDrawEndFrame,
    .draw_fps = &hostedDrawFps,
    .draw_line_raw = &hostedDrawLineRaw,
    .draw_load_font_raw = &hostedDrawLoadFontRaw,
    .draw_measure_text_raw = &hostedDrawMeasureTextRaw,
    .draw_polygon_lines_raw = &hostedDrawPolygonLinesRaw,
    .draw_polygon_raw = &hostedDrawPolygonRaw,
    .draw_rectangle_gradient_h = &hostedDrawRectangleGradientH,
    .draw_rectangle_gradient_v = &hostedDrawRectangleGradientV,
    .draw_rectangle_lines_raw = &hostedDrawRectangleLinesRaw,
    .draw_rectangle_raw = &hostedDrawRectangleRaw,
    .draw_rounded_rectangle_lines_raw = &hostedDrawRoundedRectangleLinesRaw,
    .draw_rounded_rectangle_raw = &hostedDrawRoundedRectangleRaw,
    .draw_text_raw = &hostedDrawTextRaw,
    .draw_triangle_lines_raw = &hostedDrawTriangleLinesRaw,
    .draw_triangle_raw = &hostedDrawTriangleRaw,
    .host_exit = &hostedExit,
    .host_get_screen_size = &hostedGetScreenSize,
    .host_random_i32 = &hostedRandomI32,
    .host_read_env = if (builtin.os.tag == .windows) &hostedReadEnvWindows else &hostedReadEnvPosix,
    .host_set_screen_size = &hostedSetScreenSize,
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

    var app_config: AppConfig = undefined;
    abi.app_config_for_host(&roc_ops, &app_config, null);
    defer app_config.@"title".decref(&roc_ops);

    var title_stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var window_title = makeTempCString(gpa.allocator(), &title_stack, app_config.@"title".asSlice()) catch {
        std.log.err("failed to allocate app window title", .{});
        return 1;
    };
    defer window_title.deinit();

    // Keyboard state manager (handles RocList allocation and refcounting)
    // We incref before each pass to Roc, and Roc decrefs when it drops the old Host.
    var keys = ffi.Keys.init(&roc_ops);
    defer keys.decref();
    // Edge (pressed-this-frame) state, kept in a separate RocList.
    var keys_pressed = ffi.Keys.init(&roc_ops);
    defer keys_pressed.decref();
    // Edge (released-this-frame) state, kept in a separate RocList.
    var keys_released = ffi.Keys.init(&roc_ops);
    defer keys_released.decref();

    var mouse_buttons = ffi.MouseButtons.init(&roc_ops);
    defer mouse_buttons.decref();
    var mouse_buttons_pressed = ffi.MouseButtons.init(&roc_ops);
    defer mouse_buttons_pressed.decref();
    var mouse_buttons_released = ffi.MouseButtons.init(&roc_ops);
    defer mouse_buttons_released.decref();

    // Initialize raylib window
    raylib.setConfigFlags(raylib.windowConfigFlags(
        app_config.@"resizable",
        app_config.@"fullscreen",
        app_config.@"vsync",
    ));
    raylib.initWindow(
        positiveCInt(app_config.@"width", 800),
        positiveCInt(app_config.@"height", 600),
        window_title.ptr,
    );
    defer raylib.closeWindow();
    raylib.setTargetFps(targetFpsCInt(app_config.@"target_fps"));
    if (app_config.@"cursor_visible") raylib.showCursor() else raylib.hideCursor();

    // Seed raylib's PRNG with a run-varying value. We avoid OS entropy APIs
    // (not uniformly available across our -nostdlib targets) and instead use
    // ASLR: the address of a live object differs run-to-run on PIE builds.
    raylib.setRandomSeed(@truncate(@intFromPtr(&roc_ops)));

    // Audio device must be ready before init! generates/plays any sounds.
    raylib.initAudioDevice();
    defer raylib.closeAudioDevice();

    // Call Roc init! to build the initial model
    if (TRACE_HOST) std.log.debug("[HOST] Calling init_for_host...", .{});

    var boxed_model: RocBox = null;
    {
        var init_result: RocResult = undefined;
        // Create initial host state for init (frame 0, no input)
        keys.incref(); // Prevent Roc from freeing our list
        keys_pressed.incref();
        keys_released.incref();
        mouse_buttons.incref();
        mouse_buttons_pressed.incref();
        mouse_buttons_released.incref();
        var init_state = HostState{
            .frame_count = 0,
            .timestamp_nanos = 0,
            .frame_time = 0,
            .keys = keys.list,
            .keys_pressed = keys_pressed.list,
            .keys_released = keys_released.list,
            .mouse_buttons = mouse_buttons.list,
            .mouse_buttons_pressed = mouse_buttons_pressed.list,
            .mouse_buttons_released = mouse_buttons_released.list,
            .mouse_wheel = 0,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_left = false,
            .mouse_middle = false,
            .mouse_right = false,
        };
        abi.init_for_host(&roc_ops, @ptrCast(&init_result), @ptrCast(&init_state));

        if (TRACE_HOST) std.log.debug("[HOST] init returned, tag={d}", .{@intFromEnum(init_result.tag)});

        if (init_result.isErr()) {
            const err_code = init_result.getErr();
            if (TRACE_HOST) std.log.debug("[HOST] init returned Err({d})", .{err_code});
            // Ensure non-zero exit code (use 1 if err_code is 0 due to Roc wildcard match bug)
            return if (err_code == 0) 1 else @intCast(err_code);
        }

        boxed_model = init_result.getOk();
    }

    // Main render loop
    var exit_code: i32 = 0;
    var frame_count: u64 = 0;

    while (!raylib.windowShouldClose()) {
        // Sample raylib's monotonic clock (seconds since window init) at the
        // start of the frame and expose it as nanoseconds. frame_time is
        // raylib's own delta, forced to 0 on the first frame.
        const now_ns: u64 = @intFromFloat(raylib.getTime() * 1_000_000_000.0);
        const frame_time: f32 = if (frame_count == 0) 0 else raylib.getFrameTime();

        // Capture real inputs from raylib
        raylib.updateKeyboardState();
        keys.update(raylib.getKeyState());
        keys.incref(); // Prevent Roc from freeing our list
        keys_pressed.update(raylib.getKeyPressedState());
        keys_pressed.incref();
        keys_released.update(raylib.getKeyReleasedState());
        keys_released.incref();
        raylib.updateMouseButtonState();
        mouse_buttons.update(raylib.getMouseButtonState());
        mouse_buttons.incref();
        mouse_buttons_pressed.update(raylib.getMouseButtonPressedState());
        mouse_buttons_pressed.incref();
        mouse_buttons_released.update(raylib.getMouseButtonReleasedState());
        mouse_buttons_released.incref();
        const mouse_pos = raylib.getMousePosition();
        const platform_state = HostState{
            .frame_count = frame_count,
            .timestamp_nanos = now_ns,
            .frame_time = frame_time,
            .keys = keys.list,
            .keys_pressed = keys_pressed.list,
            .keys_released = keys_released.list,
            .mouse_buttons = mouse_buttons.list,
            .mouse_buttons_pressed = mouse_buttons_pressed.list,
            .mouse_buttons_released = mouse_buttons_released.list,
            .mouse_wheel = raylib.getMouseWheelMove(),
            .mouse_x = mouse_pos.x,
            .mouse_y = mouse_pos.y,
            .mouse_left = raylib.isMouseButtonDown(.left),
            .mouse_middle = raylib.isMouseButtonDown(.middle),
            .mouse_right = raylib.isMouseButtonDown(.right),
        };

        // Call Roc render with the platform state
        var render_args = RenderArgs{ .model = boxed_model, .state = platform_state };
        var render_result: RocResult = undefined;
        abi.render_for_host(&roc_ops, @ptrCast(&render_result), @ptrCast(&render_args));

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

    // Clean up final model (always clean up if we have one, regardless of exit code).
    // We hand the box back to Roc to drop: only the compiler knows the Model layout,
    // and a box whose payload holds refcounted fields uses a wider allocation header
    // than the host could safely assume.
    if (boxed_model) |model| {
        if (TRACE_HOST) std.log.debug("[HOST] Dropping final model box=0x{x}", .{@intFromPtr(model)});
        var box_slot: *anyopaque = model;
        var drop_ret: u8 = undefined;
        abi.drop_model_for_host(&roc_ops, @ptrCast(&drop_ret), @ptrCast(&box_slot));
    }

    // If dbg or expect_failed was called, ensure non-zero exit code
    // to prevent accidental commits with debug statements or failing tests
    if (debug_or_expect_called.load(.acquire) and exit_code == 0) {
        return 1;
    }

    return exit_code;
}
