///! Platform host for roc-ray using the raylib graphics library.
const std = @import("std");
const builtin = @import("builtin");

// Import generated platform ABI (use for hosted function arg/ret types)
const abi = @import("roc_abi.zig");

// Import FFI conversion utilities
const ffi = @import("roc_ffi.zig");

// Import backend
const raylib = @import("backend_raylib.zig");

// Type aliases
const RocBox = ffi.RocBox;
const RocResult = ffi.Try(ffi.RocBox, i64);
const HostState = ffi.HostState;
const RocHost = ffi.RocHost;
// read_env! returns Try(Str, [NotFound, ..]); the generated `abi.Try` (payload
// union of RocStr/err-ptr) is the correct 32-byte layout for it.
const ReadEnvResult = abi.Try;
const AppConfig = abi.__AnonStruct82;

extern fn app_config_for_host() callconv(.c) AppConfig;
extern fn init_for_host(arg0: HostState) callconv(.c) RocResult;
extern fn render_for_host(arg0: RocBox, arg1: HostState) callconv(.c) RocResult;
extern fn drop_model_for_host(arg0: RocBox) callconv(.c) void;

const TRACE_HOST = false;

/// Global flag to track if dbg or expect_failed was called.
/// If set, program exits with non-zero code to prevent accidental commits.
var debug_or_expect_called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Roc's symbol ABI calls runtime and hosted symbols directly, without passing
/// host context. Keep the active per-process helper context here for callbacks.
var active_roc_host: ?*RocHost = null;

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

fn activeHost() *RocHost {
    return active_roc_host orelse {
        std.debug.print("roc-ray host called before RocHost was initialized\n", .{});
        std.process.exit(1);
    };
}

/// Custom dbg handler that sets flag and prints to stderr.
fn nativeDbg(_: *RocHost, bytes: [*]const u8, len: usize) callconv(.c) void {
    debug_or_expect_called.store(true, .release);
    const msg = bytes[0..len];
    std.debug.print("\x1b[36m[ROC DBG]\x1b[0m {s}\n", .{msg});
}

/// Custom expect handler that sets flag and prints to stderr.
fn nativeExpectFailed(_: *RocHost, bytes: [*]const u8, len: usize) callconv(.c) void {
    debug_or_expect_called.store(true, .release);
    const msg = bytes[0..len];
    std.debug.print("\x1b[33m[ROC EXPECT]\x1b[0m {s}\n", .{msg});
}

/// Crash handler - prints to stderr and exits.
fn nativeCrashed(_: *RocHost, bytes: [*]const u8, len: usize) callconv(.c) void {
    const msg = bytes[0..len];
    std.debug.print("\x1b[31m[ROC CRASHED]\x1b[0m {s}\n", .{msg});
    std.process.exit(1);
}

fn exportedRocAlloc(length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return abi.DefaultAllocators.rocAlloc(activeHost(), length, alignment);
}

fn exportedRocDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    abi.DefaultAllocators.rocDealloc(activeHost(), ptr, alignment);
}

fn exportedRocRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return abi.DefaultAllocators.rocRealloc(activeHost(), ptr, new_length, alignment);
}

fn exportedRocDbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    nativeDbg(activeHost(), bytes, len);
}

fn exportedRocExpectFailed(bytes: [*]const u8, len: usize) callconv(.c) void {
    nativeExpectFailed(activeHost(), bytes, len);
}

fn exportedRocCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    nativeCrashed(activeHost(), bytes, len);
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

fn allocatorFromHost(host: *RocHost) std.mem.Allocator {
    const env: *abi.RocEnv = @ptrCast(@alignCast(host.env));
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

fn hostedAssetsLoadTextureRaw(host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.__AnonStruct0 {
    defer path_arg.decref(host);
    var result: abi.__AnonStruct0 = .{ .handle = 0, .height = 0, .width = 0 };

    const path_slice = path_arg.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromHost(host), &stack, path_slice) catch return result;
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

fn exportedAssetsLoadTextureRaw(path_arg: abi.RocStr) callconv(.c) abi.__AnonStruct0 {
    return hostedAssetsLoadTextureRaw(activeHost(), path_arg);
}

fn hostedDrawBeginFrame() callconv(.c) void {
    raylib.beginDrawing();
}

fn hostedDrawBeginCamera(args: abi.DrawBegin_cameraArgs) callconv(.c) void {
    raylib.beginMode2D(args);
}

fn hostedDrawCircleRaw(args: abi.DrawCircle_rawArgs) callconv(.c) void {
    raylib.drawCircle(args);
}

fn hostedDrawCircleGradient(args: abi.DrawCircle_gradientArgs) callconv(.c) void {
    raylib.drawCircleGradient(args);
}

fn hostedDrawCircleLinesRaw(args: abi.DrawCircle_lines_rawArgs) callconv(.c) void {
    raylib.drawCircleLines(args);
}

fn hostedDrawClear(color: abi.Color) callconv(.c) void {
    raylib.clearBackground(color);
}

fn hostedDrawEndFrame() callconv(.c) void {
    raylib.endDrawing();
}

fn hostedDrawEndCamera() callconv(.c) void {
    raylib.endMode2D();
}

fn hostedDrawFps(args: abi.DrawFpsArgs) callconv(.c) void {
    raylib.drawFps(args);
}

fn hostedDrawLineRaw(args: abi.DrawLine_rawArgs) callconv(.c) void {
    raylib.drawLine(args);
}

fn hostedDrawPolygonRaw(host: *RocHost, args: abi.DrawPolygon_rawArgs) callconv(.c) void {
    defer args.points.decref(host);
    raylib.drawPolygon(args.points.items(), args.color);
}

fn exportedDrawPolygonRaw(args: abi.DrawPolygon_rawArgs) callconv(.c) void {
    hostedDrawPolygonRaw(activeHost(), args);
}

fn hostedDrawPolygonLinesRaw(host: *RocHost, args: abi.DrawPolygon_lines_rawArgs) callconv(.c) void {
    defer args.points.decref(host);
    raylib.drawPolygonLines(args.points.items(), args.thickness, args.color);
}

fn exportedDrawPolygonLinesRaw(args: abi.DrawPolygon_lines_rawArgs) callconv(.c) void {
    hostedDrawPolygonLinesRaw(activeHost(), args);
}

fn hostedDrawRectangleRaw(args: abi.DrawRectangle_rawArgs) callconv(.c) void {
    raylib.drawRectangle(args);
}

fn hostedDrawRectangleLinesRaw(args: abi.DrawRectangle_lines_rawArgs) callconv(.c) void {
    raylib.drawRectangleLines(args);
}

fn hostedDrawRectangleGradientH(args: abi.DrawRectangle_gradient_hArgs) callconv(.c) void {
    raylib.drawRectangleGradientH(args);
}

fn hostedDrawRectangleGradientV(args: abi.DrawRectangle_gradient_vArgs) callconv(.c) void {
    raylib.drawRectangleGradientV(args);
}

fn hostedDrawRoundedRectangleRaw(args: abi.DrawRounded_rectangle_rawArgs) callconv(.c) void {
    raylib.drawRoundedRectangle(args);
}

fn hostedDrawRoundedRectangleLinesRaw(args: abi.DrawRounded_rectangle_lines_rawArgs) callconv(.c) void {
    raylib.drawRoundedRectangleLines(args);
}

fn hostedDrawTriangleRaw(args: abi.DrawTriangle_rawArgs) callconv(.c) void {
    raylib.drawTriangle(args);
}

fn hostedDrawTriangleLinesRaw(args: abi.DrawTriangle_lines_rawArgs) callconv(.c) void {
    raylib.drawTriangleLines(args);
}

fn hostedDrawLoadFontRaw(host: *RocHost, args: abi.DrawLoad_font_rawArgs) callconv(.c) u64 {
    defer args.path.decref(host);

    const path_slice = args.path.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromHost(host), &stack, path_slice) catch return 0;
    defer path.deinit();

    return raylib.loadFont(path.ptr, args.size) orelse 0;
}

fn exportedDrawLoadFontRaw(args: abi.DrawLoad_font_rawArgs) callconv(.c) u64 {
    return hostedDrawLoadFontRaw(activeHost(), args);
}

fn hostedDrawMeasureTextRaw(host: *RocHost, args: abi.DrawMeasure_text_rawArgs) callconv(.c) abi.DrawMeasure_text_rawRetRecord {
    defer args.text.decref(host);
    var result: abi.DrawMeasure_text_rawRetRecord = .{ .height = 0, .width = 0 };

    const text_slice = args.text.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var text = makeTempCString(allocatorFromHost(host), &stack, text_slice) catch return result;
    defer text.deinit();

    const measured = raylib.measureTextZ(text.ptr, args.font, args.size, args.spacing);
    result = .{ .height = measured.y, .width = measured.x };
    return result;
}

fn exportedDrawMeasureTextRaw(args: abi.DrawMeasure_text_rawArgs) callconv(.c) abi.DrawMeasure_text_rawRetRecord {
    return hostedDrawMeasureTextRaw(activeHost(), args);
}

fn hostedDrawTextRaw(host: *RocHost, args: abi.DrawText_rawArgs) callconv(.c) void {
    defer args.text.decref(host);

    const text_slice = args.text.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var text = makeTempCString(allocatorFromHost(host), &stack, text_slice) catch return;
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

fn exportedDrawTextRaw(args: abi.DrawText_rawArgs) callconv(.c) void {
    hostedDrawTextRaw(activeHost(), args);
}

fn hostedDrawTextureRaw(args: abi.DrawDraw_texture_rawArgs) callconv(.c) void {
    raylib.drawTexture(args);
}

/// Global flag for deferred exit request (exit after current frame completes)
var exit_requested: ?i64 = null;

fn decrefHostArg(roc_host: *RocHost, host: *const abi.Host) void {
    host.keys.decref(roc_host);
    host.keys_pressed.decref(roc_host);
    host.keys_released.decref(roc_host);
    host.mouse.buttons.decref(roc_host);
    host.mouse.buttons_pressed.decref(roc_host);
    host.mouse.buttons_released.decref(roc_host);
}

fn hostedReadEnvWindows(roc_host: *RocHost, host: abi.Host, key_arg: abi.RocStr) callconv(.c) ReadEnvResult {
    // Windows doesn't link libc, so env var reading is not yet supported
    var result: ReadEnvResult = undefined;
    result.tag = .Err;

    // Roc transfers ownership of refcounted args to the hosted fn; release them.
    decrefHostArg(roc_host, &host);
    key_arg.decref(roc_host);
    return result;
}

fn exportedReadEnvWindows(host: abi.Host, key_arg: abi.RocStr) callconv(.c) ReadEnvResult {
    return hostedReadEnvWindows(activeHost(), host, key_arg);
}

fn hostedReadEnvPosix(roc_host: *RocHost, host: abi.Host, key_arg: abi.RocStr) callconv(.c) ReadEnvResult {
    var result: ReadEnvResult = undefined;
    const key = key_arg.asSlice();
    const value = hostGetEnv(key);

    if (value) |v| {
        result.payload = .{ .ok = abi.RocStr.fromSlice(v, roc_host) };
        result.tag = .Ok;
    } else {
        result.tag = .Err;
    }

    // Roc transfers ownership of refcounted args to the hosted fn; release them.
    // `key` (a slice into key_arg) is fully consumed above before key_arg is dropped.
    decrefHostArg(roc_host, &host);
    key_arg.decref(roc_host);
    return result;
}

fn exportedReadEnvPosix(host: abi.Host, key_arg: abi.RocStr) callconv(.c) ReadEnvResult {
    return hostedReadEnvPosix(activeHost(), host, key_arg);
}

fn hostedExit(code: i32) callconv(.c) void {
    exit_requested = @as(i64, code);
}

fn hostedGetScreenSize() callconv(.c) abi.HostGet_screen_sizeRetRecord {
    return .{ .height = raylib.getScreenHeight(), .width = raylib.getScreenWidth() };
}

fn hostedSetScreenSize(args: abi.HostSet_screen_sizeArgs) callconv(.c) abi.Try {
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

fn hostedAudioGenTone(args: abi.AudioGen_tone_rawArgs) callconv(.c) u64 {
    return raylib.genTone(args.freq, args.ms);
}

fn hostedAudioGenSound(args: abi.AudioGen_sound_rawArgs) callconv(.c) u64 {
    return raylib.genSound(args);
}

fn hostedAudioLoadSound(host: *RocHost, path_arg: abi.RocStr) callconv(.c) u64 {
    defer path_arg.decref(host);

    const path_slice = path_arg.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromHost(host), &stack, path_slice) catch return 0;
    defer path.deinit();

    return raylib.loadSound(path.ptr);
}

fn exportedAudioLoadSound(path_arg: abi.RocStr) callconv(.c) u64 {
    return hostedAudioLoadSound(activeHost(), path_arg);
}

fn hostedAudioLoadMusic(host: *RocHost, path_arg: abi.RocStr) callconv(.c) u64 {
    defer path_arg.decref(host);

    const path_slice = path_arg.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromHost(host), &stack, path_slice) catch return 0;
    defer path.deinit();

    return raylib.loadMusic(path.ptr);
}

fn exportedAudioLoadMusic(path_arg: abi.RocStr) callconv(.c) u64 {
    return hostedAudioLoadMusic(activeHost(), path_arg);
}

fn hostedAudioPlay(handle: u64) callconv(.c) void {
    raylib.playSoundHandle(handle);
}

fn hostedAudioSetVolume(handle: u64, volume: f32) callconv(.c) void {
    raylib.setSoundVolumeHandle(handle, volume);
}

fn hostedAudioSetPitch(handle: u64, pitch: f32) callconv(.c) void {
    raylib.setSoundPitchHandle(handle, pitch);
}

fn hostedAudioSetPan(handle: u64, pan: f32) callconv(.c) void {
    raylib.setSoundPanHandle(handle, pan);
}

fn hostedAudioPlayMusic(handle: u64) callconv(.c) void {
    raylib.playMusicHandle(handle);
}

fn hostedAudioStopMusic(handle: u64) callconv(.c) void {
    raylib.stopMusicHandle(handle);
}

fn hostedAudioPauseMusic(handle: u64) callconv(.c) void {
    raylib.pauseMusicHandle(handle);
}

fn hostedAudioResumeMusic(handle: u64) callconv(.c) void {
    raylib.resumeMusicHandle(handle);
}

fn hostedAudioSetMusicVolume(handle: u64, volume: f32) callconv(.c) void {
    raylib.setMusicVolumeHandle(handle, volume);
}

fn hostedAudioSetMusicPitch(handle: u64, pitch: f32) callconv(.c) void {
    raylib.setMusicPitchHandle(handle, pitch);
}

fn hostedAudioSetMusicPan(handle: u64, pan: f32) callconv(.c) void {
    raylib.setMusicPanHandle(handle, pan);
}

fn hostedAudioSetMusicLooping(handle: u64, looping: bool) callconv(.c) void {
    raylib.setMusicLoopingHandle(handle, looping);
}

comptime {
    if (!builtin.is_test) {
        @export(&exportedRocAlloc, .{ .name = "roc_alloc" });
        @export(&exportedRocDealloc, .{ .name = "roc_dealloc" });
        @export(&exportedRocRealloc, .{ .name = "roc_realloc" });
        @export(&exportedRocDbg, .{ .name = "roc_dbg" });
        @export(&exportedRocExpectFailed, .{ .name = "roc_expect_failed" });
        @export(&exportedRocCrashed, .{ .name = "roc_crashed" });

        @export(&exportedAssetsLoadTextureRaw, .{ .name = "roc_assets_load_texture_raw" });
        @export(&hostedAudioGenSound, .{ .name = "roc_audio_gen_sound_raw" });
        @export(&hostedAudioGenTone, .{ .name = "roc_audio_gen_tone_raw" });
        @export(&exportedAudioLoadMusic, .{ .name = "roc_audio_load_music_raw" });
        @export(&exportedAudioLoadSound, .{ .name = "roc_audio_load_sound_raw" });
        @export(&hostedAudioPauseMusic, .{ .name = "roc_audio_pause_music_raw" });
        @export(&hostedAudioPlayMusic, .{ .name = "roc_audio_play_music_raw" });
        @export(&hostedAudioPlay, .{ .name = "roc_audio_play_raw" });
        @export(&hostedAudioResumeMusic, .{ .name = "roc_audio_resume_music_raw" });
        @export(&hostedAudioSetMusicLooping, .{ .name = "roc_audio_set_music_looping_raw" });
        @export(&hostedAudioSetMusicPan, .{ .name = "roc_audio_set_music_pan_raw" });
        @export(&hostedAudioSetMusicPitch, .{ .name = "roc_audio_set_music_pitch_raw" });
        @export(&hostedAudioSetMusicVolume, .{ .name = "roc_audio_set_music_volume_raw" });
        @export(&hostedAudioSetPan, .{ .name = "roc_audio_set_pan_raw" });
        @export(&hostedAudioSetPitch, .{ .name = "roc_audio_set_pitch_raw" });
        @export(&hostedAudioSetVolume, .{ .name = "roc_audio_set_volume_raw" });
        @export(&hostedAudioStopMusic, .{ .name = "roc_audio_stop_music_raw" });
        @export(&hostedDrawBeginCamera, .{ .name = "roc_draw_begin_camera" });
        @export(&hostedDrawBeginFrame, .{ .name = "roc_draw_begin_frame" });
        @export(&hostedDrawCircleGradient, .{ .name = "roc_draw_circle_gradient" });
        @export(&hostedDrawCircleLinesRaw, .{ .name = "roc_draw_circle_lines_raw" });
        @export(&hostedDrawCircleRaw, .{ .name = "roc_draw_circle_raw" });
        @export(&hostedDrawClear, .{ .name = "roc_draw_clear" });
        @export(&hostedDrawTextureRaw, .{ .name = "roc_draw_draw_texture_raw" });
        @export(&hostedDrawEndCamera, .{ .name = "roc_draw_end_camera" });
        @export(&hostedDrawEndFrame, .{ .name = "roc_draw_end_frame" });
        @export(&hostedDrawFps, .{ .name = "roc_draw_fps" });
        @export(&hostedDrawLineRaw, .{ .name = "roc_draw_line_raw" });
        @export(&exportedDrawLoadFontRaw, .{ .name = "roc_draw_load_font_raw" });
        @export(&exportedDrawMeasureTextRaw, .{ .name = "roc_draw_measure_text_raw" });
        @export(&exportedDrawPolygonLinesRaw, .{ .name = "roc_draw_polygon_lines_raw" });
        @export(&exportedDrawPolygonRaw, .{ .name = "roc_draw_polygon_raw" });
        @export(&hostedDrawRectangleGradientH, .{ .name = "roc_draw_rectangle_gradient_h" });
        @export(&hostedDrawRectangleGradientV, .{ .name = "roc_draw_rectangle_gradient_v" });
        @export(&hostedDrawRectangleLinesRaw, .{ .name = "roc_draw_rectangle_lines_raw" });
        @export(&hostedDrawRectangleRaw, .{ .name = "roc_draw_rectangle_raw" });
        @export(&hostedDrawRoundedRectangleLinesRaw, .{ .name = "roc_draw_rounded_rectangle_lines_raw" });
        @export(&hostedDrawRoundedRectangleRaw, .{ .name = "roc_draw_rounded_rectangle_raw" });
        @export(&exportedDrawTextRaw, .{ .name = "roc_draw_text_raw" });
        @export(&hostedDrawTriangleLinesRaw, .{ .name = "roc_draw_triangle_lines_raw" });
        @export(&hostedDrawTriangleRaw, .{ .name = "roc_draw_triangle_raw" });
        @export(&hostedExit, .{ .name = "roc_host_exit" });
        @export(&hostedGetScreenSize, .{ .name = "roc_host_get_screen_size" });
        @export(&hostedRandomI32, .{ .name = "roc_host_random_i32" });
        @export(if (builtin.os.tag == .windows) &exportedReadEnvWindows else &exportedReadEnvPosix, .{ .name = "roc_host_read_env" });
        @export(&hostedSetScreenSize, .{ .name = "roc_host_set_screen_size" });
        @export(&hostedSetTargetFps, .{ .name = "roc_host_set_target_fps" });
    }
}

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

    // Create the host-internal helper context used by generated helpers.
    var roc_host = RocHost{
        .env = @ptrCast(&roc_env),
        .roc_alloc = &abi.DefaultAllocators.rocAlloc,
        .roc_dealloc = &abi.DefaultAllocators.rocDealloc,
        .roc_realloc = &abi.DefaultAllocators.rocRealloc,
        .roc_dbg = &nativeDbg,
        .roc_expect_failed = &nativeExpectFailed,
        .roc_crashed = &nativeCrashed,
    };

    active_roc_host = &roc_host;
    defer active_roc_host = null;

    var app_config = app_config_for_host();
    defer app_config.title.decref(&roc_host);

    var title_stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var window_title = makeTempCString(gpa.allocator(), &title_stack, app_config.title.asSlice()) catch {
        std.log.err("failed to allocate app window title", .{});
        return 1;
    };
    defer window_title.deinit();

    // Keyboard state manager (handles RocList allocation and refcounting)
    // We incref before each pass to Roc, and Roc decrefs when it drops the old Host.
    var keys = ffi.Keys.init(&roc_host);
    defer keys.decref();
    // Edge (pressed-this-frame) state, kept in a separate RocList.
    var keys_pressed = ffi.Keys.init(&roc_host);
    defer keys_pressed.decref();
    // Edge (released-this-frame) state, kept in a separate RocList.
    var keys_released = ffi.Keys.init(&roc_host);
    defer keys_released.decref();

    var mouse_buttons = ffi.MouseButtons.init(&roc_host);
    defer mouse_buttons.decref();
    var mouse_buttons_pressed = ffi.MouseButtons.init(&roc_host);
    defer mouse_buttons_pressed.decref();
    var mouse_buttons_released = ffi.MouseButtons.init(&roc_host);
    defer mouse_buttons_released.decref();

    // Initialize raylib window
    raylib.setConfigFlags(raylib.windowConfigFlags(
        app_config.resizable,
        app_config.fullscreen,
        app_config.vsync,
    ));
    raylib.initWindow(
        positiveCInt(app_config.width, 800),
        positiveCInt(app_config.height, 600),
        window_title.ptr,
    );
    defer raylib.closeWindow();
    raylib.setTargetFps(targetFpsCInt(app_config.target_fps));
    if (app_config.cursor_visible) raylib.showCursor() else raylib.hideCursor();

    // Seed raylib's PRNG with a run-varying value. We avoid OS entropy APIs
    // (not uniformly available across our -nostdlib targets) and instead use
    // ASLR: the address of a live object differs run-to-run on PIE builds.
    raylib.setRandomSeed(@truncate(@intFromPtr(&roc_host)));

    // Audio device must be ready before init! generates/plays any sounds.
    raylib.initAudioDevice();
    defer raylib.closeAudioDevice();

    // Call Roc init! to build the initial model
    if (TRACE_HOST) std.log.debug("[HOST] Calling init_for_host...", .{});

    var boxed_model: RocBox = null;
    {
        // Create initial host state for init (frame 0, no input)
        keys.incref(); // Prevent Roc from freeing our list
        keys_pressed.incref();
        keys_released.incref();
        mouse_buttons.incref();
        mouse_buttons_pressed.incref();
        mouse_buttons_released.incref();
        const init_state = HostState{
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
        const init_result = init_for_host(init_state);

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
        raylib.updateMusicStreams();

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
        const render_result = render_for_host(boxed_model, platform_state);

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
        drop_model_for_host(model);
    }

    // If dbg or expect_failed was called, ensure non-zero exit code
    // to prevent accidental commits with debug statements or failing tests
    if (debug_or_expect_called.load(.acquire) and exit_code == 0) {
        return 1;
    }

    return exit_code;
}
