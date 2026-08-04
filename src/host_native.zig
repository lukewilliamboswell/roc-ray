///! Platform host for roc-ray using the raylib graphics library.
const std = @import("std");
const builtin = @import("builtin");

// Import generated platform ABI (use for hosted function arg/ret types)
const abi = @import("roc_platform_abi.zig");

// Import FFI conversion utilities
const ffi = @import("roc_ffi.zig");
const host_resource = @import("host_resource.zig");
const tmx_loader = @import("tmx_loader.zig");

// Import backend
const raylib = @import("backend_raylib.zig");

// Type aliases
const RocBox = ffi.RocBox;
const RocResult = ffi.Try(ffi.RocBox, i64);
const HostState = ffi.HostState;
const RocHost = ffi.RocHost;
// read_env! returns Try(Str, [NotFound, ..]); the generated `abi.Try` (payload
// union of RocStr/err-ptr) is the correct 32-byte layout for it.
const ReadEnvResult = abi.HostRead_env_rawResult;
const HostReadFileRawResult = abi.HostRead_file_rawRetRecord;
const TilemapLoadTmxRawResult = abi.TilemapLoad_tmx_rawRetRecord;
const AppConfig = abi.App_config_for_host;
const TilemapRawMap = abi.TilemapLoad_tmx_rawMap;
const TilemapRawLayer = abi.TilemapLoad_tmx_rawMapLayers;
const TilemapRawObject = abi.TilemapLoad_tmx_rawMapObjects;
const TilemapRawPoint = abi.TilemapLoad_tmx_rawMapPoints;
const TilemapRawProperty = abi.TilemapLoad_tmx_rawMapProperties;
const TilemapRawTileProperties = abi.TilemapLoad_tmx_rawMapTileProperties;
const TilemapRawTileset = abi.TilemapLoad_tmx_rawMapTilesets;

const HOST_ERR_NOT_FOUND: u8 = 1;
const HOST_ERR_READ_FAILED: u8 = 2;
const TILEMAP_ERR_NOT_FOUND: u8 = 1;
const TILEMAP_ERR_READ_FAILED: u8 = 2;
const TILEMAP_ERR_PARSE_FAILED: u8 = 3;
const TILEMAP_ERR_UNSUPPORTED: u8 = 4;
const TRY_TAG_OK: u8 = 1;
const MAX_HOST_TEXT_FILE_BYTES: usize = 16 * 1024 * 1024;

extern fn app_config_for_host() callconv(.c) AppConfig;
extern fn init_for_host(arg0: HostState) callconv(.c) RocResult;
extern fn render_for_host(arg0: RocBox, arg1: HostState) callconv(.c) RocResult;
extern fn drop_model_for_host(arg0: RocBox) callconv(.c) void;

const TRACE_HOST = false;
const DEFAULT_HEADLESS_FRAMES: u64 = 3;
const HEADLESS_FRAME_NANOS: u64 = 16_666_667;
const HEADLESS_FRAME_TIME: f32 = 1.0 / 60.0;
const HEADLESS_RESOURCE_SIZE: f32 = 64;
/// Global flag to track if dbg or expect_failed was called.
/// If set, program exits with non-zero code to prevent accidental commits.
var debug_or_expect_called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Roc's symbol ABI calls runtime and hosted symbols directly, without passing
/// host context. Keep the active per-process helper context here for callbacks.
var active_roc_host: ?*RocHost = null;
var active_headless = false;
var active_mouse_cursor_code: u8 = 255;
var headless_screen_width: i32 = 800;
var headless_screen_height: i32 = 600;
var headless_random_state: u32 = 0x4d595df4;

const InvalidResourceBox = extern struct {
    refcount: isize = 0,
    token: u64 = 0,
};

var invalid_resource_box: InvalidResourceBox = .{};

const InvalidTextureBox = extern struct {
    refcount: isize = 0,
    payload: abi.AssetsLoad_texture_raw = .{ .handle = 0, .height = 0, .width = 0 },
};

var invalid_texture_box: InvalidTextureBox = .{};

const SoundResource = union(enum) {
    headless,
    native: raylib.Sound,
};

const MusicResource = union(enum) {
    headless,
    native: raylib.Music,
};

const FontResource = union(enum) {
    headless,
    native: raylib.Font,
};

const TextureResource = union(enum) {
    headless,
    native: raylib.Texture,
};

fn destroySound(resource: *SoundResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.unloadSound(sound),
    }
}

fn destroyMusic(resource: *MusicResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.unloadMusic(music),
    }
}

fn destroyFont(resource: *FontResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |font| raylib.unloadFont(font),
    }
}

fn destroyTexture(resource: *TextureResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |texture| raylib.unloadTexture(texture),
    }
}

fn writeU64Token(payload: *u64, token: u64) void {
    payload.* = token;
}

fn readU64Token(payload: *const u64) u64 {
    return payload.*;
}

fn writeTextureToken(payload: *abi.AssetsLoad_texture_raw, token: u64) void {
    payload.handle = token;
}

fn readTextureToken(payload: *const abi.AssetsLoad_texture_raw) u64 {
    return payload.handle;
}

const SoundHeap = host_resource.HostResourceHeap(u64, SoundResource, 128, 1, writeU64Token, readU64Token, destroySound);
const MusicHeap = host_resource.HostResourceHeap(u64, MusicResource, 16, 2, writeU64Token, readU64Token, destroyMusic);
const FontHeap = host_resource.HostResourceHeap(u64, FontResource, 32, 3, writeU64Token, readU64Token, destroyFont);
const TextureHeap = host_resource.HostResourceHeap(abi.AssetsLoad_texture_raw, TextureResource, 128, 4, writeTextureToken, readTextureToken, destroyTexture);

var sound_heap: SoundHeap = .{};
var music_heap: MusicHeap = .{};
var font_heap: FontHeap = .{};
var texture_heap: TextureHeap = .{};

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

fn nativeRocDealloc(host: *RocHost, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    inline for (.{ &sound_heap, &music_heap, &font_heap, &texture_heap }) |heap| {
        switch (heap.routeDealloc(ptr)) {
            .not_owned => {},
            .deallocated => return,
            .corrupt => {
                std.debug.print("invalid host resource deallocation at 0x{x}\n", .{@intFromPtr(ptr)});
                std.process.exit(1);
            },
        }
    }
    abi.DefaultAllocators.rocDealloc(host, ptr, alignment);
}

fn exportedRocDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    nativeRocDealloc(activeHost(), ptr, alignment);
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

fn defaultIo() std.Io {
    if (comptime builtin.is_test) {
        return std.testing.io;
    } else {
        return std.Io.Threaded.global_single_threaded.io();
    }
}

fn emptyHostReadFileRawResult() HostReadFileRawResult {
    return .{ .contents = abi.RocStr.empty(), .err = 0, .ok = false };
}

fn emptyTilemapRawMap() TilemapRawMap {
    return .{
        .gids = abi.RocListWith(u64, false).empty(),
        .height = 0,
        .layers = abi.RocListWith(TilemapRawLayer, true).empty(),
        .map_property_count = 0,
        .map_property_start = 0,
        .objects = abi.RocListWith(TilemapRawObject, true).empty(),
        .points = abi.RocListWith(TilemapRawPoint, false).empty(),
        .properties = abi.RocListWith(TilemapRawProperty, true).empty(),
        .tile_properties = abi.RocListWith(TilemapRawTileProperties, false).empty(),
        .tilesets = abi.RocListWith(TilemapRawTileset, true).empty(),
        .width = 0,
        .tile_height = 0,
        .tile_width = 0,
    };
}

fn emptyTilemapLoadResult(err: u8) TilemapLoadTmxRawResult {
    return .{ .map = emptyTilemapRawMap(), .err = err, .ok = false };
}

fn tilemapLoadErrorCode(err: tmx_loader.LoadError) u8 {
    return switch (err) {
        error.NotFound => TILEMAP_ERR_NOT_FOUND,
        error.ReadFailed => TILEMAP_ERR_READ_FAILED,
        error.Unsupported => TILEMAP_ERR_UNSUPPORTED,
        else => TILEMAP_ERR_PARSE_FAILED,
    };
}

fn convertTilemapRawMap(host: *RocHost, raw: tmx_loader.RawMap) TilemapRawMap {
    return .{
        .gids = abi.RocListWith(u64, false).fromSlice(raw.gids, host),
        .height = raw.height,
        .layers = convertTilemapLayers(host, raw.layers),
        .map_property_count = raw.map_property_count,
        .map_property_start = raw.map_property_start,
        .objects = convertTilemapObjects(host, raw.objects),
        .points = convertTilemapPoints(host, raw.points),
        .properties = convertTilemapProperties(host, raw.properties),
        .tile_properties = convertTilemapTileProperties(host, raw.tile_properties),
        .tilesets = convertTilemapTilesets(host, raw.tilesets),
        .width = raw.width,
        .tile_height = raw.tile_height,
        .tile_width = raw.tile_width,
    };
}

fn convertTilemapLayers(host: *RocHost, layers: []const tmx_loader.Layer) abi.RocListWith(TilemapRawLayer, true) {
    const list = abi.RocListWith(TilemapRawLayer, true).allocate(layers.len, host);
    if (list.elements_ptr) |elements| {
        for (layers, 0..) |layer, i| {
            elements[i] = .{
                .gid_count = layer.gid_count,
                .gid_start = layer.gid_start,
                .height = layer.height,
                .name = abi.RocStr.fromSlice(layer.name, host),
                .property_count = layer.property_count,
                .property_start = layer.property_start,
                .width = layer.width,
                .opacity = layer.opacity,
                .visible = layer.visible,
            };
        }
    }
    return list;
}

fn convertTilemapObjects(host: *RocHost, objects: []const tmx_loader.Object) abi.RocListWith(TilemapRawObject, true) {
    const list = abi.RocListWith(TilemapRawObject, true).allocate(objects.len, host);
    if (list.elements_ptr) |elements| {
        for (objects, 0..) |object, i| {
            elements[i] = .{
                .id = object.id,
                .name = abi.RocStr.fromSlice(object.name, host),
                .point_count = object.point_count,
                .point_start = object.point_start,
                .property_count = object.property_count,
                .property_start = object.property_start,
                .type_name = abi.RocStr.fromSlice(object.type_name, host),
                .height = object.height,
                .rotation = object.rotation,
                .width = object.width,
                .x = object.x,
                .y = object.y,
                .kind = @intFromEnum(object.kind),
            };
        }
    }
    return list;
}

fn convertTilemapPoints(host: *RocHost, points: []const tmx_loader.Point) abi.RocListWith(TilemapRawPoint, false) {
    const list = abi.RocListWith(TilemapRawPoint, false).allocate(points.len, host);
    if (list.elements_ptr) |elements| {
        for (points, 0..) |point, i| {
            elements[i] = .{ .x = point.x, .y = point.y };
        }
    }
    return list;
}

fn convertTilemapProperties(host: *RocHost, properties: []const tmx_loader.Property) abi.RocListWith(TilemapRawProperty, true) {
    const list = abi.RocListWith(TilemapRawProperty, true).allocate(properties.len, host);
    if (list.elements_ptr) |elements| {
        for (properties, 0..) |property, i| {
            elements[i] = .{
                .integer = property.integer,
                .name = abi.RocStr.fromSlice(property.name, host),
                .text = abi.RocStr.fromSlice(property.text, host),
                .number = property.number,
                .bool_value = property.bool_value,
                .kind = property.kind,
            };
        }
    }
    return list;
}

fn convertTilemapTileProperties(host: *RocHost, ranges: []const tmx_loader.TileProperties) abi.RocListWith(TilemapRawTileProperties, false) {
    const list = abi.RocListWith(TilemapRawTileProperties, false).allocate(ranges.len, host);
    if (list.elements_ptr) |elements| {
        for (ranges, 0..) |range, i| {
            elements[i] = .{
                .gid = range.gid,
                .property_count = range.property_count,
                .property_start = range.property_start,
            };
        }
    }
    return list;
}

fn convertTilemapTilesets(host: *RocHost, tilesets: []const tmx_loader.Tileset) abi.RocListWith(TilemapRawTileset, true) {
    const list = abi.RocListWith(TilemapRawTileset, true).allocate(tilesets.len, host);
    if (list.elements_ptr) |elements| {
        for (tilesets, 0..) |tileset, i| {
            elements[i] = .{
                .columns = tileset.columns,
                .first_gid = tileset.first_gid,
                .image_source = abi.RocStr.fromSlice(tileset.image_source, host),
                .name = abi.RocStr.fromSlice(tileset.name, host),
                .property_count = tileset.property_count,
                .property_start = tileset.property_start,
                .tile_count = tileset.tile_count,
                .image_height = tileset.image_height,
                .image_width = tileset.image_width,
                .tile_height = tileset.tile_height,
                .tile_width = tileset.tile_width,
            };
        }
    }
    return list;
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

fn positiveI32(value: i32, fallback: i32) i32 {
    return if (value > 0) value else fallback;
}

fn targetFpsCInt(value: i32) c_int {
    return if (value >= 0) @as(c_int, @intCast(value)) else 0;
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(defaultIo(), path, .{}) catch return false;
    return true;
}

fn resetHeadlessRuntime(app_config: AppConfig) void {
    headless_screen_width = positiveI32(app_config.width, 800);
    headless_screen_height = positiveI32(app_config.height, 600);
    headless_random_state = 0x4d595df4;
}

fn headlessMeasureText(text: []const u8, size: f32, spacing: f32) abi.DrawMeasure_text_rawRetRecord {
    const font_size = if (size > 0) size else 1;
    const glyph_count: f32 = @floatFromInt(text.len);
    const gap_count: f32 = if (text.len > 1) @floatFromInt(text.len - 1) else 0;
    return .{
        .height = font_size,
        .width = @max(0, glyph_count * font_size * 0.5 + gap_count * spacing),
    };
}

fn headlessRandomI32(min: i32, max: i32) i32 {
    if (max <= min) return min;

    headless_random_state = headless_random_state *% 1664525 +% 1013904223;
    const span_i64 = @as(i64, max) - @as(i64, min) + 1;
    const offset: i32 = @intCast(@as(u64, headless_random_state) % @as(u64, @intCast(span_i64)));
    return min + offset;
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

fn storeFont(resource: FontResource) *u64 {
    return font_heap.insert(0, resource) orelse {
        var rejected = resource;
        destroyFont(&rejected);
        return invalidResourceHandle();
    };
}

fn storeTexture(resource: TextureResource, width: f32, height: f32) *abi.AssetsLoad_texture_raw {
    return texture_heap.insert(.{ .handle = 0, .height = height, .width = width }, resource) orelse {
        var rejected = resource;
        destroyTexture(&rejected);
        return &invalid_texture_box.payload;
    };
}

fn hostedAssetsLoadTextureRaw(host: *RocHost, path_arg: abi.RocStr) callconv(.c) *abi.AssetsLoad_texture_raw {
    defer path_arg.decref(host);

    const path_slice = path_arg.asSlice();
    if (active_headless) {
        if (!pathExists(path_slice)) return &invalid_texture_box.payload;
        return storeTexture(.headless, HEADLESS_RESOURCE_SIZE, HEADLESS_RESOURCE_SIZE);
    }

    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromHost(host), &stack, path_slice) catch return &invalid_texture_box.payload;
    defer path.deinit();

    if (raylib.loadTexture(path.ptr)) |texture| {
        const height = raylib.textureHeight(texture);
        const width = raylib.textureWidth(texture);
        return storeTexture(.{ .native = texture }, width, height);
    }

    return &invalid_texture_box.payload;
}

fn exportedAssetsLoadTextureRaw(path_arg: abi.RocStr) callconv(.c) *abi.AssetsLoad_texture_raw {
    return hostedAssetsLoadTextureRaw(activeHost(), path_arg);
}

fn hostedDrawBeginFrame() callconv(.c) void {
    if (active_headless) return;
    raylib.beginDrawing();
}

/// Forward Roc scissor bounds to the raylib backend.
fn hostedDrawBeginScissorRaw(args: abi.DrawBegin_scissor_rawArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.beginScissor(args.x, args.y, args.width, args.height);
}

/// End the scissor region opened by the Roc renderer.
fn hostedDrawEndScissorRaw() callconv(.c) void {
    if (active_headless) return;
    raylib.endScissor();
}

fn hostedDrawBeginCamera(args: abi.DrawBegin_cameraArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.beginMode2D(args);
}

fn hostedDrawCircleRaw(args: abi.DrawCircle_rawArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawCircle(args);
}

fn hostedDrawCircleGradient(args: abi.DrawCircle_gradientArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawCircleGradient(args);
}

fn hostedDrawCircleLinesRaw(args: abi.DrawCircle_lines_rawArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawCircleLines(args);
}

fn hostedDrawClear(color: abi.Color) callconv(.c) void {
    if (active_headless) return;
    raylib.clearBackground(color);
}

fn hostedDrawEndFrame() callconv(.c) void {
    if (active_headless) return;
    raylib.endDrawing();
}

fn hostedDrawEndCamera() callconv(.c) void {
    if (active_headless) return;
    raylib.endMode2D();
}

fn hostedDrawFps(args: abi.DrawFpsArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawFps(args);
}

fn hostedDrawLineRaw(args: abi.DrawLine_rawArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawLine(args);
}

fn hostedDrawPolygonRaw(host: *RocHost, args: abi.DrawPolygon_rawArgs) callconv(.c) void {
    defer args.points.decref(host);
    if (active_headless) return;
    raylib.drawPolygon(args.points.items(), args.color);
}

fn exportedDrawPolygonRaw(args: abi.DrawPolygon_rawArgs) callconv(.c) void {
    hostedDrawPolygonRaw(activeHost(), args);
}

fn hostedDrawPolygonLinesRaw(host: *RocHost, args: abi.DrawPolygon_lines_rawArgs) callconv(.c) void {
    defer args.points.decref(host);
    if (active_headless) return;
    raylib.drawPolygonLines(args.points.items(), args.thickness, args.color);
}

fn exportedDrawPolygonLinesRaw(args: abi.DrawPolygon_lines_rawArgs) callconv(.c) void {
    hostedDrawPolygonLinesRaw(activeHost(), args);
}

fn hostedDrawRectangleRaw(args: abi.DrawRectangle_rawArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawRectangle(args);
}

fn hostedDrawRectangleLinesRaw(args: abi.DrawRectangle_lines_rawArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawRectangleLines(args);
}

fn hostedDrawRectangleGradientH(args: abi.DrawRectangle_gradient_hArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawRectangleGradientH(args);
}

fn hostedDrawRectangleGradientV(args: abi.DrawRectangle_gradient_vArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawRectangleGradientV(args);
}

fn hostedDrawRoundedRectangleRaw(args: abi.DrawRounded_rectangle_rawArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawRoundedRectangle(args);
}

fn hostedDrawRoundedRectangleLinesRaw(args: abi.DrawRounded_rectangle_lines_rawArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawRoundedRectangleLines(args);
}

fn hostedDrawTriangleRaw(args: abi.DrawTriangle_rawArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawTriangle(args);
}

fn hostedDrawTriangleLinesRaw(args: abi.DrawTriangle_lines_rawArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawTriangleLines(args);
}

fn hostedDrawLoadFontRaw(host: *RocHost, args: abi.DrawLoad_font_rawArgs) callconv(.c) *u64 {
    defer args.path.decref(host);

    const path_slice = args.path.asSlice();
    if (active_headless) {
        if (!pathExists(path_slice)) return invalidResourceHandle();
        return storeFont(.headless);
    }

    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromHost(host), &stack, path_slice) catch return invalidResourceHandle();
    defer path.deinit();

    const font = raylib.loadFont(path.ptr, args.size) orelse return invalidResourceHandle();
    return storeFont(.{ .native = font });
}

fn exportedDrawLoadFontRaw(args: abi.DrawLoad_font_rawArgs) callconv(.c) *u64 {
    return hostedDrawLoadFontRaw(activeHost(), args);
}

fn fontForToken(token: u64) raylib.Font {
    if (token == 0) return raylib.defaultFont();
    const resource = font_heap.get(token) orelse return raylib.defaultFont();
    return switch (resource.*) {
        .headless => raylib.defaultFont(),
        .native => |font| font,
    };
}

fn hostedDrawMeasureTextRaw(host: *RocHost, args: abi.DrawMeasure_text_rawArgs) callconv(.c) abi.DrawMeasure_text_rawRetRecord {
    defer args.text.decref(host);
    var result: abi.DrawMeasure_text_rawRetRecord = .{ .height = 0, .width = 0 };

    const text_slice = args.text.asSlice();
    if (active_headless) return headlessMeasureText(text_slice, args.size, args.spacing);

    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var text = makeTempCString(allocatorFromHost(host), &stack, text_slice) catch return result;
    defer text.deinit();

    const measured = raylib.measureTextZ(text.ptr, fontForToken(args.font), args.size, args.spacing);
    result = .{ .height = measured.y, .width = measured.x };
    return result;
}

fn exportedDrawMeasureTextRaw(args: abi.DrawMeasure_text_rawArgs) callconv(.c) abi.DrawMeasure_text_rawRetRecord {
    return hostedDrawMeasureTextRaw(activeHost(), args);
}

fn hostedDrawTextRaw(host: *RocHost, args: abi.DrawText_rawArgs) callconv(.c) void {
    defer args.text.decref(host);
    if (active_headless) return;

    const text_slice = args.text.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var text = makeTempCString(allocatorFromHost(host), &stack, text_slice) catch return;
    defer text.deinit();

    raylib.drawTextZ(
        text.ptr,
        fontForToken(args.font),
        .{ .x = args.pos.x, .y = args.pos.y },
        args.size,
        args.spacing,
        args.color,
    );
}

fn exportedDrawTextRaw(args: abi.DrawText_rawArgs) callconv(.c) void {
    hostedDrawTextRaw(activeHost(), args);
}

fn hostedDrawTextAlignedRaw(host: *RocHost, args: abi.DrawText_aligned_rawArgs) callconv(.c) void {
    defer args.text.decref(host);
    if (active_headless) return;

    const text_slice = args.text.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var text = makeTempCString(allocatorFromHost(host), &stack, text_slice) catch return;
    defer text.deinit();

    raylib.drawTextAlignedZ(
        text.ptr,
        fontForToken(args.font),
        .{ .x = args.pos.x, .y = args.pos.y },
        args.size,
        args.spacing,
        args.color,
        .{ .x = args.align_x, .y = args.align_y },
    );
}

fn exportedDrawTextAlignedRaw(args: abi.DrawText_aligned_rawArgs) callconv(.c) void {
    hostedDrawTextAlignedRaw(activeHost(), args);
}

fn hostedDrawTextureRaw(args: abi.DrawDraw_texture_rawArgs) callconv(.c) void {
    if (active_headless) return;
    const resource = texture_heap.get(args.texture) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |texture| raylib.drawTexture(texture, args),
    }
}

fn hostedDrawTextureQuadRaw(args: abi.DrawDraw_texture_quad_rawArgs) callconv(.c) void {
    if (active_headless) return;
    const resource = texture_heap.get(args.texture) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |texture| raylib.drawTextureQuad(texture, args),
    }
}

/// Global flag for deferred exit request (exit after current frame completes)
var exit_requested: ?i64 = null;

fn decrefHostArg(roc_host: *RocHost, host: *const abi.Host) void {
    host.keys.decref(roc_host);
    host.mouse.buttons.decref(roc_host);
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

fn hostedReadFileRaw(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) HostReadFileRawResult {
    defer path_arg.decref(roc_host);

    const allocator = allocatorFromHost(roc_host);
    const path = path_arg.asSlice();
    const bytes = std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, allocator, .limited(MAX_HOST_TEXT_FILE_BYTES)) catch |err| {
        var result = emptyHostReadFileRawResult();
        result.err = switch (err) {
            error.FileNotFound => HOST_ERR_NOT_FOUND,
            else => HOST_ERR_READ_FAILED,
        };
        return result;
    };
    defer allocator.free(bytes);

    return .{
        .contents = abi.RocStr.fromSlice(bytes, roc_host),
        .err = 0,
        .ok = true,
    };
}

fn exportedReadFileRaw(path_arg: abi.RocStr) callconv(.c) HostReadFileRawResult {
    return hostedReadFileRaw(activeHost(), path_arg);
}

fn hostedTilemapLoadTmxRaw(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) TilemapLoadTmxRawResult {
    defer path_arg.decref(roc_host);

    const path = path_arg.asSlice();
    var map = tmx_loader.load(allocatorFromHost(roc_host), defaultIo(), path) catch |err| {
        return emptyTilemapLoadResult(tilemapLoadErrorCode(err));
    };
    defer map.deinit();

    return .{
        .map = convertTilemapRawMap(roc_host, map.raw),
        .err = 0,
        .ok = true,
    };
}

fn exportedTilemapLoadTmxRaw(path_arg: abi.RocStr) callconv(.c) TilemapLoadTmxRawResult {
    return hostedTilemapLoadTmxRaw(activeHost(), path_arg);
}

fn hostedExit(code: i32) callconv(.c) void {
    exit_requested = @as(i64, code);
}

fn hostedSetScreenSize(args: abi.HostSet_screen_size_rawArgs) callconv(.c) u8 {
    if (active_headless) {
        headless_screen_width = positiveI32(@intFromFloat(args.width), headless_screen_width);
        headless_screen_height = positiveI32(@intFromFloat(args.height), headless_screen_height);
    } else {
        raylib.setWindowSize(@intFromFloat(args.width), @intFromFloat(args.height));
    }
    return TRY_TAG_OK;
}

fn hostedSetTargetFps(fps: i32) callconv(.c) void {
    if (active_headless) return;
    raylib.setTargetFps(fps);
}

fn mouseCursorFromCode(code: u8) raylib.MouseCursor {
    if (code > @intFromEnum(raylib.MouseCursor.not_allowed)) return .default;
    return @enumFromInt(code);
}

fn hostedMouseSetCursorRaw(cursor: u8) callconv(.c) void {
    if (active_headless) return;
    const next = mouseCursorFromCode(cursor);
    const next_code: u8 = @intCast(@intFromEnum(next));
    if (active_mouse_cursor_code == next_code) return;
    raylib.setMouseCursor(next);
    active_mouse_cursor_code = next_code;
}

test "mouse cursor codes map invalid values to default" {
    try std.testing.expectEqual(raylib.MouseCursor.pointing_hand, mouseCursorFromCode(4));
    try std.testing.expectEqual(raylib.MouseCursor.default, mouseCursorFromCode(255));
}

fn hostedRandomI32(min: i32, max: i32) callconv(.c) i32 {
    if (active_headless) return headlessRandomI32(min, max);
    return raylib.getRandomValue(min, max);
}

fn invalidResourceHandle() *u64 {
    return &invalid_resource_box.token;
}

fn storeSound(resource: SoundResource) *u64 {
    return sound_heap.insert(0, resource) orelse {
        var rejected = resource;
        destroySound(&rejected);
        return invalidResourceHandle();
    };
}

fn storeMusic(resource: MusicResource) *u64 {
    return music_heap.insert(0, resource) orelse {
        var rejected = resource;
        destroyMusic(&rejected);
        return invalidResourceHandle();
    };
}

fn hostedAudioGenTone(args: abi.AudioGen_tone_rawArgs) callconv(.c) *u64 {
    if (active_headless) return storeSound(.headless);
    const sound = raylib.genTone(args.freq, args.ms) orelse return invalidResourceHandle();
    return storeSound(.{ .native = sound });
}

fn hostedAudioGenSound(args: abi.AudioGen_sound_rawArgs) callconv(.c) *u64 {
    if (active_headless) return storeSound(.headless);
    const sound = raylib.genSound(args) orelse return invalidResourceHandle();
    return storeSound(.{ .native = sound });
}

fn hostedAudioLoadSound(host: *RocHost, path_arg: abi.RocStr) callconv(.c) *u64 {
    defer path_arg.decref(host);

    const path_slice = path_arg.asSlice();
    if (active_headless) {
        if (!pathExists(path_slice)) return invalidResourceHandle();
        return storeSound(.headless);
    }

    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromHost(host), &stack, path_slice) catch return invalidResourceHandle();
    defer path.deinit();

    const sound = raylib.loadSound(path.ptr) orelse return invalidResourceHandle();
    return storeSound(.{ .native = sound });
}

fn exportedAudioLoadSound(path_arg: abi.RocStr) callconv(.c) *u64 {
    return hostedAudioLoadSound(activeHost(), path_arg);
}

fn hostedAudioLoadMusic(host: *RocHost, path_arg: abi.RocStr) callconv(.c) *u64 {
    defer path_arg.decref(host);

    const path_slice = path_arg.asSlice();
    if (active_headless) {
        if (!pathExists(path_slice)) return invalidResourceHandle();
        return storeMusic(.headless);
    }

    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromHost(host), &stack, path_slice) catch return invalidResourceHandle();
    defer path.deinit();

    const music = raylib.loadMusic(path.ptr) orelse return invalidResourceHandle();
    return storeMusic(.{ .native = music });
}

fn exportedAudioLoadMusic(path_arg: abi.RocStr) callconv(.c) *u64 {
    return hostedAudioLoadMusic(activeHost(), path_arg);
}

fn hostedAudioPlay(handle: u64) callconv(.c) void {
    const resource = sound_heap.get(handle) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.playSound(sound),
    }
}

fn hostedAudioSetVolume(handle: u64, volume: f32) callconv(.c) void {
    const resource = sound_heap.get(handle) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.setSoundVolume(sound, volume),
    }
}

fn hostedAudioSetPitch(handle: u64, pitch: f32) callconv(.c) void {
    const resource = sound_heap.get(handle) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.setSoundPitch(sound, pitch),
    }
}

fn hostedAudioSetPan(handle: u64, pan: f32) callconv(.c) void {
    const resource = sound_heap.get(handle) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.setSoundPan(sound, pan),
    }
}

fn hostedAudioPlayMusic(handle: u64) callconv(.c) void {
    const resource = music_heap.get(handle) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.playMusic(music),
    }
}

fn hostedAudioStopMusic(handle: u64) callconv(.c) void {
    const resource = music_heap.get(handle) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.stopMusic(music),
    }
}

fn hostedAudioPauseMusic(handle: u64) callconv(.c) void {
    const resource = music_heap.get(handle) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.pauseMusic(music),
    }
}

fn hostedAudioResumeMusic(handle: u64) callconv(.c) void {
    const resource = music_heap.get(handle) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.resumeMusic(music),
    }
}

fn hostedAudioSetMusicVolume(handle: u64, volume: f32) callconv(.c) void {
    const resource = music_heap.get(handle) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.setMusicVolume(music, volume),
    }
}

fn hostedAudioSetMusicPitch(handle: u64, pitch: f32) callconv(.c) void {
    const resource = music_heap.get(handle) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.setMusicPitch(music, pitch),
    }
}

fn hostedAudioSetMusicPan(handle: u64, pan: f32) callconv(.c) void {
    const resource = music_heap.get(handle) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.setMusicPan(music, pan),
    }
}

fn hostedAudioSetMusicLooping(handle: u64, looping: bool) callconv(.c) void {
    const resource = music_heap.get(handle) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |*music| raylib.setMusicLooping(music, looping),
    }
}

fn updateMusicResource(resource: *MusicResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |*music| raylib.updateMusicStream(music),
    }
}

fn updateMusicStreams() void {
    music_heap.forEach(updateMusicResource);
}

fn deinitResources() void {
    // Roc should have released every handle by the time the final model is
    // dropped. Keep a shutdown drain for optimized builds, but catch lifecycle
    // regressions in the debug host used by the test suite.
    std.debug.assert(texture_heap.active() == 0);
    std.debug.assert(font_heap.active() == 0);
    std.debug.assert(music_heap.active() == 0);
    std.debug.assert(sound_heap.active() == 0);
    texture_heap.deinitAll();
    font_heap.deinitAll();
    music_heap.deinitAll();
    sound_heap.deinitAll();
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
        @export(&hostedDrawBeginScissorRaw, .{ .name = "roc_draw_begin_scissor_raw" });
        @export(&hostedDrawCircleGradient, .{ .name = "roc_draw_circle_gradient" });
        @export(&hostedDrawCircleLinesRaw, .{ .name = "roc_draw_circle_lines_raw" });
        @export(&hostedDrawCircleRaw, .{ .name = "roc_draw_circle_raw" });
        @export(&hostedDrawClear, .{ .name = "roc_draw_clear" });
        @export(&hostedDrawTextureRaw, .{ .name = "roc_draw_draw_texture_raw" });
        @export(&hostedDrawTextureQuadRaw, .{ .name = "roc_draw_draw_texture_quad_raw" });
        @export(&hostedDrawEndCamera, .{ .name = "roc_draw_end_camera" });
        @export(&hostedDrawEndFrame, .{ .name = "roc_draw_end_frame" });
        @export(&hostedDrawEndScissorRaw, .{ .name = "roc_draw_end_scissor_raw" });
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
        @export(&exportedDrawTextAlignedRaw, .{ .name = "roc_draw_text_aligned_raw" });
        @export(&exportedDrawTextRaw, .{ .name = "roc_draw_text_raw" });
        @export(&hostedDrawTriangleLinesRaw, .{ .name = "roc_draw_triangle_lines_raw" });
        @export(&hostedDrawTriangleRaw, .{ .name = "roc_draw_triangle_raw" });
        @export(&hostedExit, .{ .name = "roc_host_exit" });
        @export(&hostedRandomI32, .{ .name = "roc_host_random_i32" });
        @export(if (builtin.os.tag == .windows) &exportedReadEnvWindows else &exportedReadEnvPosix, .{ .name = "roc_host_read_env" });
        @export(&exportedReadFileRaw, .{ .name = "roc_host_read_file_raw" });
        @export(&hostedSetScreenSize, .{ .name = "roc_host_set_screen_size" });
        @export(&hostedSetTargetFps, .{ .name = "roc_host_set_target_fps" });
        @export(&hostedMouseSetCursorRaw, .{ .name = "roc_mouse_set_cursor_raw" });
        @export(&exportedTilemapLoadTmxRaw, .{ .name = "roc_tilemap_load_tmx_raw" });
    }
}

const RuntimeOptions = struct {
    headless: bool = false,
    headless_frames: u64 = DEFAULT_HEADLESS_FRAMES,
    debug_allocator: bool = false,
    help: bool = false,
};

const InputState = struct {
    keys: ffi.Keys,
    mouse_buttons: ffi.MouseButtons,

    fn init(roc_host: *RocHost) InputState {
        return .{
            .keys = ffi.Keys.init(roc_host),
            .mouse_buttons = ffi.MouseButtons.init(roc_host),
        };
    }

    fn deinit(self: *InputState) void {
        self.mouse_buttons.decref();
        self.keys.decref();
    }

    fn retainForRoc(self: *InputState) void {
        self.keys.incref();
        self.mouse_buttons.incref();
    }

    fn hostState(
        self: *InputState,
        frame_count: u64,
        timestamp_nanos: u64,
        frame_time: f32,
        mouse_x: f32,
        mouse_y: f32,
        mouse_wheel: f32,
    ) HostState {
        self.retainForRoc();
        return .{
            .frame_count = frame_count,
            .timestamp_nanos = timestamp_nanos,
            .frame_time = frame_time,
            .screen = .{
                .width = if (active_headless) headless_screen_width else raylib.getScreenWidth(),
                .height = if (active_headless) headless_screen_height else raylib.getScreenHeight(),
            },
            .keys = self.keys.list,
            .mouse = .{
                .buttons = self.mouse_buttons.list,
                .left = self.mouse_buttons.hasFlag(0, ffi.INPUT_HELD),
                .middle = self.mouse_buttons.hasFlag(2, ffi.INPUT_HELD),
                .right = self.mouse_buttons.hasFlag(1, ffi.INPUT_HELD),
                .wheel = mouse_wheel,
                .x = mouse_x,
                .y = mouse_y,
            },
        };
    }

    fn updateFromRaylib(self: *InputState) void {
        raylib.updateKeyboardState();
        self.keys.update(raylib.getKeyState());

        raylib.updateMouseButtonState();
        self.mouse_buttons.update(raylib.getMouseButtonState());
    }
};

fn printUsage() void {
    std.debug.print("usage: app [--headless] [--headless-frames=N] [--debug-allocator]\n", .{});
}

fn parseRuntimeOptions(argc: usize, argv: [*][*:0]u8) !RuntimeOptions {
    var options = RuntimeOptions{};
    var i: usize = 1;
    while (i < argc) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--headless")) {
            options.headless = true;
        } else if (std.mem.startsWith(u8, arg, "--headless-frames=")) {
            options.headless = true;
            const value = arg["--headless-frames=".len..];
            const frames = std.fmt.parseUnsigned(u64, value, 10) catch {
                std.debug.print("invalid --headless-frames value: {s}\n", .{value});
                return error.InvalidArgument;
            };
            if (frames == 0) {
                std.debug.print("--headless-frames must be greater than zero\n", .{});
                return error.InvalidArgument;
            }
            options.headless_frames = frames;
        } else if (std.mem.eql(u8, arg, "--debug-allocator")) {
            options.debug_allocator = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }
    return options;
}

fn finalExitCode(exit_code: i32) c_int {
    if (debug_or_expect_called.load(.acquire) and exit_code == 0) return 1;
    return exit_code;
}

fn initExitCode(err_code: i64) c_int {
    const code: i32 = if (err_code == 0) 1 else @intCast(err_code);
    return finalExitCode(code);
}

fn dropFinalModel(boxed_model: RocBox) void {
    if (boxed_model) |model| {
        if (TRACE_HOST) std.log.debug("[HOST] Dropping final model box=0x{x}", .{@intFromPtr(model)});
        drop_model_for_host(model);
    }
}

fn initModel(input: *InputState) RocResult {
    if (TRACE_HOST) std.log.debug("[HOST] Calling init_for_host...", .{});
    const init_state = input.hostState(0, 0, 0, 0, 0, 0);
    const init_result = init_for_host(init_state);
    if (TRACE_HOST) std.log.debug("[HOST] init returned, tag={d}", .{@intFromEnum(init_result.tag)});
    return init_result;
}

fn runNormalApp(roc_host: *RocHost, allocator: std.mem.Allocator, app_config: AppConfig) c_int {
    var title_stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var window_title = makeTempCString(allocator, &title_stack, app_config.title.asSlice()) catch {
        std.log.err("failed to allocate app window title", .{});
        return 1;
    };
    defer window_title.deinit();

    var input = InputState.init(roc_host);
    defer input.deinit();

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
    active_mouse_cursor_code = 255;

    // Seed raylib's PRNG with a run-varying value. We avoid OS entropy APIs
    // (not uniformly available across our -nostdlib targets) and instead use
    // ASLR: the address of a live object differs run-to-run on PIE builds.
    raylib.setRandomSeed(@truncate(@intFromPtr(roc_host)));

    // Audio device must be ready before init! generates/plays any sounds.
    raylib.initAudioDevice();
    defer raylib.closeAudioDevice();
    defer deinitResources();

    const init_result = initModel(&input);
    if (init_result.isErr()) {
        const err_code = init_result.getErr();
        if (TRACE_HOST) std.log.debug("[HOST] init returned Err({d})", .{err_code});
        return initExitCode(err_code);
    }

    var boxed_model = init_result.getOk();
    var exit_code: i32 = 0;
    var frame_count: u64 = 0;

    while (!raylib.windowShouldClose()) {
        // Sample raylib's monotonic clock (seconds since window init) at the
        // start of the frame and expose it as nanoseconds. frame_time is
        // raylib's own delta, forced to 0 on the first frame.
        const now_ns: u64 = @intFromFloat(raylib.getTime() * 1_000_000_000.0);
        const frame_time: f32 = if (frame_count == 0) 0 else raylib.getFrameTime();
        updateMusicStreams();

        input.updateFromRaylib();
        const mouse_pos = raylib.getMousePosition();
        const platform_state = input.hostState(
            frame_count,
            now_ns,
            frame_time,
            mouse_pos.x,
            mouse_pos.y,
            raylib.getMouseWheelMove(),
        );

        const render_result = render_for_host(boxed_model, platform_state);
        if (render_result.isErr()) {
            exit_code = @intCast(render_result.getErr());
            if (TRACE_HOST) std.log.debug("[HOST] render returned Err({d})", .{exit_code});
            break;
        }

        boxed_model = render_result.getOk();
        frame_count += 1;

        if (exit_requested) |code| {
            exit_code = @intCast(code);
            break;
        }
    }

    dropFinalModel(boxed_model);
    return finalExitCode(exit_code);
}

fn runHeadlessApp(roc_host: *RocHost, app_config: AppConfig, frames: u64) c_int {
    resetHeadlessRuntime(app_config);
    defer deinitResources();

    var input = InputState.init(roc_host);
    defer input.deinit();

    const init_result = initModel(&input);
    if (init_result.isErr()) {
        const err_code = init_result.getErr();
        if (TRACE_HOST) std.log.debug("[HOST] init returned Err({d})", .{err_code});
        return initExitCode(err_code);
    }

    var boxed_model = init_result.getOk();
    var exit_code: i32 = 0;
    var frame_count: u64 = 0;

    while (frame_count < frames) : (frame_count += 1) {
        const frame_time: f32 = if (frame_count == 0) 0 else HEADLESS_FRAME_TIME;
        const platform_state = input.hostState(
            frame_count,
            frame_count * HEADLESS_FRAME_NANOS,
            frame_time,
            0,
            0,
            0,
        );

        const render_result = render_for_host(boxed_model, platform_state);
        if (render_result.isErr()) {
            exit_code = @intCast(render_result.getErr());
            if (TRACE_HOST) std.log.debug("[HOST] render returned Err({d})", .{exit_code});
            break;
        }

        boxed_model = render_result.getOk();
        if (exit_requested) |code| {
            exit_code = @intCast(code);
            break;
        }
    }

    dropFinalModel(boxed_model);
    return finalExitCode(exit_code);
}

/// Platform host entrypoint
fn platform_main(argc: usize, argv: [*][*:0]u8) c_int {
    const options = parseRuntimeOptions(argc, argv) catch {
        printUsage();
        return 2;
    };
    if (options.help) {
        printUsage();
        return 0;
    }

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

    const use_debug_allocator = builtin.mode == .Debug and options.debug_allocator;
    var debug_allocator: std.heap.DebugAllocator(.{}) = .{};
    defer if (use_debug_allocator) {
        if (debug_allocator.deinit() == .leak) std.log.warn("Memory leak detected", .{});
    };

    const allocator = if (use_debug_allocator)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;

    // The Roc runtime environment: allocator + I/O backend. We supply our own
    // dbg/expect/crashed handlers below, so the I/O backend (only used by the
    // generated DefaultHandlers) is left as a no-op freestanding implementation.
    var roc_env = abi.RocEnv{
        .allocator = allocator,
        .roc_io = abi.RocIo.freestanding(),
    };

    // Create the host-internal helper context used by generated helpers.
    var roc_host = RocHost{
        .env = @ptrCast(&roc_env),
        .roc_alloc = &abi.DefaultAllocators.rocAlloc,
        .roc_dealloc = &nativeRocDealloc,
        .roc_realloc = &abi.DefaultAllocators.rocRealloc,
        .roc_dbg = &nativeDbg,
        .roc_expect_failed = &nativeExpectFailed,
        .roc_crashed = &nativeCrashed,
    };

    active_roc_host = &roc_host;
    active_headless = options.headless;
    exit_requested = null;
    debug_or_expect_called.store(false, .release);
    defer {
        active_headless = false;
        active_roc_host = null;
    }

    var app_config = app_config_for_host();
    defer app_config.title.decref(&roc_host);

    if (options.headless) {
        return runHeadlessApp(&roc_host, app_config, options.headless_frames);
    }

    return runNormalApp(&roc_host, allocator, app_config);
}
