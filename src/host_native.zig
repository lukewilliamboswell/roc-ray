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
const ReadEnvResult = abi.HostHostRead_envResult;
const HostReadFileRawResult = abi.HostHostRead_fileRetRecord;
const TilemapLoadTmxRawResult = abi.TilemapHostLoad_tmxRetRecord;
const AppConfig = abi.App_config_for_host;
const TilemapRawMap = abi.TilemapHostLoad_tmxMap;
const TilemapRawLayer = abi.TilemapHostLoad_tmxMapLayers;
const TilemapRawObject = abi.TilemapHostLoad_tmxMapObjects;
const TilemapRawPoint = abi.TilemapHostLoad_tmxMapPoints;
const TilemapRawProperty = abi.TilemapHostLoad_tmxMapProperties;
const TilemapRawTileProperties = abi.TilemapHostLoad_tmxMapTileProperties;
const TilemapRawTileset = abi.TilemapHostLoad_tmxMapTilesets;

const HOST_ERR_NOT_FOUND: u8 = 1;
const HOST_ERR_READ_FAILED: u8 = 2;
const TILEMAP_ERR_NOT_FOUND: u8 = 1;
const TILEMAP_ERR_READ_FAILED: u8 = 2;
const TILEMAP_ERR_PARSE_FAILED: u8 = 3;
const TILEMAP_ERR_UNSUPPORTED: u8 = 4;
const RESOURCE_ERR_NONE: u8 = 0;
const RESOURCE_ERR_FAILED: u8 = 1;
const RESOURCE_ERR_LIMIT: u8 = 2;
const TEXTURE_UPDATE_OK: u8 = 0;
const TEXTURE_UPDATE_PIXEL_COUNT: u8 = 1;
const TEXTURE_UPDATE_NOT_MUTABLE: u8 = 2;
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
var headless_screen_width: i32 = 800;
var headless_screen_height: i32 = 600;
var headless_random_state: u32 = 0x4d595df4;
var headless_render_texture_depth: u8 = 0;
var headless_shader_depth: u8 = 0;
var headless_blend_depth: u8 = 0;
const RESOURCE_SCOPE_LIMIT: usize = 64;
var render_texture_leases: [RESOURCE_SCOPE_LIMIT]?*abi.AssetsHostTextureResource = @splat(null);
var render_texture_lease_count: usize = 0;
var shader_leases: [RESOURCE_SCOPE_LIMIT]?*u64 = @splat(null);
var shader_lease_count: usize = 0;

const InvalidResourceBox = extern struct {
    refcount: isize = 0,
    token: u64 = 0,
};

var invalid_resource_box: InvalidResourceBox = .{};

const InvalidTextureBox = extern struct {
    refcount: isize = 0,
    payload: abi.AssetsHostTextureResource = .{ .handle = 0, .height = 0, .width = 0 },
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
    headless: struct { width: i32, height: i32 },
    native: raylib.Texture,
};

const RenderTextureResource = union(enum) {
    headless,
    native: raylib.RenderTexture,
};

const ShaderResource = union(enum) {
    headless,
    native: raylib.Shader,
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

fn destroyRenderTexture(resource: *RenderTextureResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |target| raylib.unloadRenderTexture(target),
    }
}

fn destroyShader(resource: *ShaderResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |shader| raylib.unloadShader(shader),
    }
}

fn writeU64Token(payload: *u64, token: u64) void {
    payload.* = token;
}

fn readU64Token(payload: *const u64) u64 {
    return payload.*;
}

fn writeTextureToken(payload: *abi.AssetsHostTextureResource, token: u64) void {
    payload.handle = token;
}

fn readTextureToken(payload: *const abi.AssetsHostTextureResource) u64 {
    return payload.handle;
}

const SoundHeap = host_resource.HostResourceHeap(u64, SoundResource, 128, 1, writeU64Token, readU64Token, destroySound);
const MusicHeap = host_resource.HostResourceHeap(u64, MusicResource, 16, 2, writeU64Token, readU64Token, destroyMusic);
const FontHeap = host_resource.HostResourceHeap(u64, FontResource, 32, 3, writeU64Token, readU64Token, destroyFont);
const TextureHeap = host_resource.HostResourceHeap(abi.AssetsHostTextureResource, TextureResource, 128, 4, writeTextureToken, readTextureToken, destroyTexture);
const RenderTextureHeap = host_resource.HostResourceHeap(abi.AssetsHostTextureResource, RenderTextureResource, 32, 5, writeTextureToken, readTextureToken, destroyRenderTexture);
const ShaderHeap = host_resource.HostResourceHeap(u64, ShaderResource, 32, 6, writeU64Token, readU64Token, destroyShader);

var sound_heap: SoundHeap = .{};
var music_heap: MusicHeap = .{};
var font_heap: FontHeap = .{};
var texture_heap: TextureHeap = .{};
var render_texture_heap: RenderTextureHeap = .{};
var shader_heap: ShaderHeap = .{};

fn releaseResourceBox(host: *RocHost, handle: anytype) void {
    const Payload = @TypeOf(handle.*);
    abi.decrefBoxWith(@ptrCast(handle), @alignOf(Payload), false, null, host);
}

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
    inline for (.{ &sound_heap, &music_heap, &font_heap, &texture_heap, &render_texture_heap, &shader_heap }) |heap| {
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

const OptionalTempCString = struct {
    value: ?TempCString,

    fn init(allocator: std.mem.Allocator, stack: *[CSTRING_STACK_CAPACITY:0]u8, bytes: []const u8) !OptionalTempCString {
        if (bytes.len == 0) return .{ .value = null };
        return .{ .value = try makeTempCString(allocator, stack, bytes) };
    }

    fn ptr(self: *const OptionalTempCString) ?[*:0]const u8 {
        return if (self.value) |value| value.ptr else null;
    }

    fn deinit(self: *OptionalTempCString) void {
        if (self.value) |*value| value.deinit();
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
    headless_render_texture_depth = 0;
    headless_shader_depth = 0;
    headless_blend_depth = 0;
    render_texture_lease_count = 0;
    shader_lease_count = 0;
}

fn headlessMeasureText(text: []const u8, size: f32, spacing: f32) abi.DrawHostMeasure_textRetRecord {
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

test "nested render and shader scopes lease last references until matching end" {
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        active_headless = false;
        active_roc_host = null;
    }

    const outer_target = storeRenderTexture(.headless, 160, 90).?;
    const inner_target = storeRenderTexture(.headless, 80, 45).?;
    try std.testing.expect(hostedDrawBeginRenderTextureRaw(.{ .resource = outer_target }));
    try std.testing.expect(hostedDrawBeginRenderTextureRaw(.{ .resource = inner_target }));
    try std.testing.expectEqual(@as(usize, 2), render_texture_heap.active());
    try std.testing.expectEqual(@as(u8, 2), headless_render_texture_depth);
    hostedDrawEndRenderTextureRaw();
    try std.testing.expectEqual(@as(usize, 1), render_texture_heap.active());
    hostedDrawEndRenderTextureRaw();
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    try std.testing.expectEqual(@as(u8, 0), headless_render_texture_depth);

    const outer_shader = storeShader(.headless).?;
    const inner_shader = storeShader(.headless).?;
    try std.testing.expect(hostedDrawBeginShaderRaw(.{ .arg0 = outer_shader }));
    try std.testing.expect(hostedDrawBeginShaderRaw(.{ .arg0 = inner_shader }));
    try std.testing.expectEqual(@as(usize, 2), shader_heap.active());
    try std.testing.expectEqual(@as(u8, 2), headless_shader_depth);
    hostedDrawEndShaderRaw();
    try std.testing.expectEqual(@as(usize, 1), shader_heap.active());
    hostedDrawEndShaderRaw();
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    try std.testing.expectEqual(@as(u8, 0), headless_shader_depth);

    try std.testing.expect(hostedDrawBeginBlendRaw(.{ .arg0 = 1 }));
    try std.testing.expectEqual(@as(u8, 1), headless_blend_depth);
    hostedDrawEndBlendRaw();
    try std.testing.expectEqual(@as(u8, 0), headless_blend_depth);

    try std.testing.expect(!hostedDrawBeginBlendRaw(.{ .arg0 = 6 }));
    try std.testing.expectEqual(@as(u8, 0), headless_blend_depth);
}

test "scope kind confusion fails and releases transferred owners" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        active_headless = false;
        active_roc_host = null;
    }

    const shader = storeShader(.headless).?;
    try std.testing.expect(!hostedDrawBeginRenderTextureRaw(.{ .resource = @ptrCast(shader) }));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    const target = storeRenderTexture(.headless, 16, 16).?;
    try std.testing.expect(!hostedDrawBeginShaderRaw(.{ .arg0 = @ptrCast(target) }));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
}

test "invalid headless render target dimensions do not consume a heap slot" {
    active_headless = true;
    defer active_headless = false;
    const before = render_texture_heap.active();
    const target = hostedDrawLoadRenderTextureRaw(.{ .height = 0, .width = 160 });
    try std.testing.expectEqual(RESOURCE_ERR_FAILED, target.err);
    try std.testing.expectEqual(@as(u64, 0), target.target.resource.handle);
    try std.testing.expectEqual(before, render_texture_heap.active());
}

test "last resource references remain live through owning host operations" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        active_headless = false;
        active_roc_host = null;
    }

    const sound = storeSound(.headless).?;
    hostedAudioPlay(sound);
    try std.testing.expectEqual(@as(usize, 0), sound_heap.active());

    const music = storeMusic(.headless).?;
    _ = hostedAudioMusicLength(music);
    try std.testing.expectEqual(@as(usize, 0), music_heap.active());

    const texture = storeTexture(.{ .headless = .{ .width = 2, .height = 2 } }, 2, 2).?;
    hostedAssetsSetTextureFilterRaw(.{ .resource = texture }, 1);
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());

    const font = storeFont(.headless).?;
    const loaded_font: abi.DefaultFontOrLoadedFont = .{ .payload = .{ .loaded_font = font }, .tag = .LoadedFont };
    _ = hostedDrawMeasureTextRaw(&roc_host, .{
        .font = loaded_font,
        .text = abi.RocStr.empty(),
        .size = 16,
        .spacing = 1,
    });
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());

    const shader = storeShader(.headless).?;
    hostedDrawSetShaderFloatRaw(.{ .uniform = .{ .shader = shader, .location = 0 }, .value = 1 });
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());

    const sampler_shader = storeShader(.headless).?;
    const sampler_texture = storeTexture(.{ .headless = .{ .width = 1, .height = 1 } }, 1, 1).?;
    hostedDrawSetShaderTextureRaw(.{
        .texture = .{ .resource = sampler_texture },
        .uniform = .{ .shader = sampler_shader, .location = 0 },
    });
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());

    const target = storeRenderTexture(.headless, 8, 8).?;
    hostedDrawTextureRaw(.{
        .texture = .{ .resource = target },
        .dest = .{ .height = 8, .width = 8, .x = 0, .y = 0 },
        .origin = .{ .x = 0, .y = 0 },
        .rotation = 0,
        .source = .{ .height = 8, .width = 8, .x = 0, .y = 0 },
        .tint = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    });
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
}

test "render target texture views report not mutable and release ownership" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        active_headless = false;
        active_roc_host = null;
    }

    const target = storeRenderTexture(.headless, 4, 4).?;
    const err = hostedAssetsUpdateTextureRaw(&roc_host, .{
        .pixels = abi.RocListWith(abi.Color, false).empty(),
        .texture = .{ .resource = target },
    });
    try std.testing.expectEqual(TEXTURE_UPDATE_NOT_MUTABLE, err);
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
}

test "every fixed resource heap reports capacity plus one as ResourceLimit" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        active_headless = false;
        active_roc_host = null;
    }

    var sounds: [128]*u64 = undefined;
    for (&sounds) |*sound| sound.* = storeSound(.headless).?;
    try std.testing.expectEqual(RESOURCE_ERR_LIMIT, hostedAudioGenTone(.{ .freq = 440, .ms = 20 }).err);
    for (sounds) |sound| releaseResourceBox(&roc_host, sound);

    var music: [16]*u64 = undefined;
    for (&music) |*item| item.* = storeMusic(.headless).?;
    try std.testing.expectEqual(RESOURCE_ERR_LIMIT, hostedAudioLoadMusic(&roc_host, abi.RocStr.fromSlice("README.md", &roc_host)).err);
    for (music) |item| releaseResourceBox(&roc_host, item);

    var fonts: [32]*u64 = undefined;
    for (&fonts) |*font| font.* = storeFont(.headless).?;
    try std.testing.expectEqual(RESOURCE_ERR_LIMIT, hostedDrawLoadFontRaw(&roc_host, .{
        .path = abi.RocStr.fromSlice("README.md", &roc_host),
        .size = 16,
    }).err);
    for (fonts) |font| releaseResourceBox(&roc_host, font);

    var textures: [128]*abi.AssetsHostTextureResource = undefined;
    for (&textures) |*texture| texture.* = storeTexture(.{ .headless = .{ .width = 1, .height = 1 } }, 1, 1).?;
    try std.testing.expectEqual(RESOURCE_ERR_LIMIT, hostedAssetsGenerateColorTextureRaw(.{
        .height = 1,
        .width = 1,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    }).err);
    for (textures) |texture| releaseResourceBox(&roc_host, texture);

    var targets: [32]*abi.AssetsHostTextureResource = undefined;
    for (&targets) |*target| target.* = storeRenderTexture(.headless, 1, 1).?;
    try std.testing.expectEqual(RESOURCE_ERR_LIMIT, hostedDrawLoadRenderTextureRaw(.{ .height = 1, .width = 1 }).err);
    for (targets) |target| releaseResourceBox(&roc_host, target);

    var shaders: [32]*u64 = undefined;
    for (&shaders) |*shader| shader.* = storeShader(.headless).?;
    try std.testing.expectEqual(RESOURCE_ERR_LIMIT, hostedDrawLoadShaderSourceRaw(&roc_host, .{
        .fragment_source = abi.RocStr.fromSlice("shader", &roc_host),
        .vertex_source = abi.RocStr.empty(),
    }).err);
    for (shaders) |shader| releaseResourceBox(&roc_host, shader);

    try std.testing.expectEqual(@as(usize, 0), sound_heap.active());
    try std.testing.expectEqual(@as(usize, 0), music_heap.active());
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
}

fn storeFont(resource: FontResource) ?*u64 {
    return font_heap.insert(0, resource) orelse {
        var rejected = resource;
        destroyFont(&rejected);
        return null;
    };
}

fn storeTexture(resource: TextureResource, width: f32, height: f32) ?*abi.AssetsHostTextureResource {
    return texture_heap.insert(.{ .handle = 0, .height = height, .width = width }, resource) orelse {
        var rejected = resource;
        destroyTexture(&rejected);
        return null;
    };
}

fn invalidTexture() abi.AssetsHostTexture {
    return .{ .resource = &invalid_texture_box.payload };
}

fn texturePixelCount(width: i32, height: i32) ?usize {
    if (width <= 0 or height <= 0) return null;
    return std.math.mul(usize, @intCast(width), @intCast(height)) catch null;
}

test "texture pixel count validates dimensions" {
    try std.testing.expectEqual(@as(?usize, 16), texturePixelCount(4, 4));
    try std.testing.expectEqual(@as(?usize, null), texturePixelCount(0, 4));
    try std.testing.expectEqual(@as(?usize, null), texturePixelCount(4, -1));
}

fn hostedAssetsLoadTextureRaw(host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.AssetsHostLoad_textureRetRecord {
    defer path_arg.decref(host);

    const path_slice = path_arg.asSlice();
    if (active_headless) {
        if (!pathExists(path_slice)) return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_FAILED };
        const texture = storeTexture(.{ .headless = .{ .width = @intFromFloat(HEADLESS_RESOURCE_SIZE), .height = @intFromFloat(HEADLESS_RESOURCE_SIZE) } }, HEADLESS_RESOURCE_SIZE, HEADLESS_RESOURCE_SIZE) orelse
            return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_LIMIT };
        return .{ .texture = .{ .resource = texture }, .err = RESOURCE_ERR_NONE };
    }

    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromHost(host), &stack, path_slice) catch return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_FAILED };
    defer path.deinit();

    if (raylib.loadTexture(path.ptr)) |texture| {
        const height = raylib.textureHeight(texture);
        const width = raylib.textureWidth(texture);
        const stored = storeTexture(.{ .native = texture }, width, height) orelse
            return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_LIMIT };
        return .{ .texture = .{ .resource = stored }, .err = RESOURCE_ERR_NONE };
    }

    return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_FAILED };
}

fn exportedAssetsLoadTextureRaw(path_arg: abi.RocStr) callconv(.c) abi.AssetsHostLoad_textureRetRecord {
    return hostedAssetsLoadTextureRaw(activeHost(), path_arg);
}

fn hostedAssetsGenerateColorTextureRaw(args: abi.AssetsHostGenerate_color_textureArgs) callconv(.c) abi.AssetsHostGenerate_color_textureRetRecord {
    if (args.width <= 0 or args.height <= 0) return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_FAILED };
    if (active_headless) {
        const texture = storeTexture(.{ .headless = .{ .width = args.width, .height = args.height } }, @floatFromInt(args.width), @floatFromInt(args.height)) orelse
            return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_LIMIT };
        return .{ .texture = .{ .resource = texture }, .err = RESOURCE_ERR_NONE };
    }
    const texture = raylib.generateColorTexture(args.width, args.height, args.color) orelse return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_FAILED };
    const stored = storeTexture(.{ .native = texture }, raylib.textureWidth(texture), raylib.textureHeight(texture)) orelse
        return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_LIMIT };
    return .{ .texture = .{ .resource = stored }, .err = RESOURCE_ERR_NONE };
}

fn hostedAssetsGenerateCheckedTextureRaw(args: abi.AssetsHostGenerate_checked_textureArgs) callconv(.c) abi.AssetsHostGenerate_checked_textureRetRecord {
    if (args.width <= 0 or args.height <= 0 or args.checks_x <= 0 or args.checks_y <= 0) return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_FAILED };
    if (active_headless) {
        const texture = storeTexture(.{ .headless = .{ .width = args.width, .height = args.height } }, @floatFromInt(args.width), @floatFromInt(args.height)) orelse
            return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_LIMIT };
        return .{ .texture = .{ .resource = texture }, .err = RESOURCE_ERR_NONE };
    }
    const texture = raylib.generateCheckedTexture(args) orelse return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_FAILED };
    const stored = storeTexture(.{ .native = texture }, raylib.textureWidth(texture), raylib.textureHeight(texture)) orelse
        return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_LIMIT };
    return .{ .texture = .{ .resource = stored }, .err = RESOURCE_ERR_NONE };
}

fn hostedAssetsUpdateTextureRaw(host: *RocHost, args: abi.AssetsHostUpdate_textureArgs) callconv(.c) u8 {
    defer args.pixels.decref(host);
    defer args.texture.decref(host);
    const token = args.texture.resource.handle;
    if (render_texture_heap.get(token) != null) return TEXTURE_UPDATE_NOT_MUTABLE;
    const resource = texture_heap.get(token) orelse return TEXTURE_UPDATE_NOT_MUTABLE;
    const expected: usize = switch (resource.*) {
        .headless => |texture| texturePixelCount(texture.width, texture.height) orelse return TEXTURE_UPDATE_PIXEL_COUNT,
        .native => |texture| texturePixelCount(texture.width, texture.height) orelse return TEXTURE_UPDATE_PIXEL_COUNT,
    };
    if (args.pixels.len() != expected) return TEXTURE_UPDATE_PIXEL_COUNT;
    switch (resource.*) {
        .headless => {},
        .native => |texture| raylib.updateTexture(texture, args.pixels.items()),
    }
    return TEXTURE_UPDATE_OK;
}

fn exportedAssetsUpdateTextureRaw(args: abi.AssetsHostUpdate_textureArgs) callconv(.c) u8 {
    return hostedAssetsUpdateTextureRaw(activeHost(), args);
}

fn hostedAssetsSetTextureFilterRaw(texture_owner: abi.AssetsHostTexture, code: u8) callconv(.c) void {
    defer texture_owner.decref(activeHost());
    const texture = nativeTextureForToken(texture_owner.resource.handle) orelse return;
    raylib.setTextureFilter(texture, code);
}

fn hostedAssetsSetTextureWrapRaw(texture_owner: abi.AssetsHostTexture, code: u8) callconv(.c) void {
    defer texture_owner.decref(activeHost());
    const texture = nativeTextureForToken(texture_owner.resource.handle) orelse return;
    raylib.setTextureWrap(texture, code);
}

fn storeRenderTexture(resource: RenderTextureResource, width: f32, height: f32) ?*abi.AssetsHostTextureResource {
    return render_texture_heap.insert(.{ .handle = 0, .height = height, .width = width }, resource) orelse {
        var rejected = resource;
        destroyRenderTexture(&rejected);
        return null;
    };
}

fn storeShader(resource: ShaderResource) ?*u64 {
    return shader_heap.insert(0, resource) orelse {
        var rejected = resource;
        destroyShader(&rejected);
        return null;
    };
}

fn hostedDrawLoadRenderTextureRaw(args: abi.DrawHostLoad_render_textureArgs) callconv(.c) abi.DrawHostLoad_render_textureRetRecord {
    if (args.width <= 0 or args.height <= 0) return .{ .target = .{ .resource = &invalid_texture_box.payload }, .err = RESOURCE_ERR_FAILED };
    if (active_headless) {
        const target = storeRenderTexture(.headless, @floatFromInt(args.width), @floatFromInt(args.height)) orelse
            return .{ .target = .{ .resource = &invalid_texture_box.payload }, .err = RESOURCE_ERR_LIMIT };
        return .{ .target = .{ .resource = target }, .err = RESOURCE_ERR_NONE };
    }
    const target = raylib.loadRenderTexture(args.width, args.height) orelse
        return .{ .target = .{ .resource = &invalid_texture_box.payload }, .err = RESOURCE_ERR_FAILED };
    const stored = storeRenderTexture(.{ .native = target }, @floatFromInt(args.width), @floatFromInt(args.height)) orelse
        return .{ .target = .{ .resource = &invalid_texture_box.payload }, .err = RESOURCE_ERR_LIMIT };
    return .{ .target = .{ .resource = stored }, .err = RESOURCE_ERR_NONE };
}

fn shaderPathsExist(vertex: []const u8, fragment: []const u8) bool {
    if (vertex.len == 0 and fragment.len == 0) return false;
    return (vertex.len == 0 or pathExists(vertex)) and (fragment.len == 0 or pathExists(fragment));
}

fn hostedDrawLoadShaderRaw(host: *RocHost, args: abi.DrawHostLoad_shaderArgs) callconv(.c) abi.DrawHostLoad_shaderRetRecord {
    defer args.vertex_path.decref(host);
    defer args.fragment_path.decref(host);
    const vertex_slice = args.vertex_path.asSlice();
    const fragment_slice = args.fragment_path.asSlice();
    if (!shaderPathsExist(vertex_slice, fragment_slice)) return .{ .shader = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    if (active_headless) {
        const shader = storeShader(.headless) orelse return .{ .shader = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .shader = shader, .err = RESOURCE_ERR_NONE };
    }

    const allocator = allocatorFromHost(host);
    var vertex_stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var fragment_stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var vertex = OptionalTempCString.init(allocator, &vertex_stack, vertex_slice) catch return .{ .shader = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    defer vertex.deinit();
    var fragment = OptionalTempCString.init(allocator, &fragment_stack, fragment_slice) catch return .{ .shader = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    defer fragment.deinit();
    const shader = raylib.loadShader(vertex.ptr(), fragment.ptr()) orelse return .{ .shader = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeShader(.{ .native = shader }) orelse return .{ .shader = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .shader = stored, .err = RESOURCE_ERR_NONE };
}

fn exportedDrawLoadShaderRaw(args: abi.DrawHostLoad_shaderArgs) callconv(.c) abi.DrawHostLoad_shaderRetRecord {
    return hostedDrawLoadShaderRaw(activeHost(), args);
}

fn hostedDrawLoadShaderSourceRaw(host: *RocHost, args: abi.DrawHostLoad_shader_sourceArgs) callconv(.c) abi.DrawHostLoad_shader_sourceRetRecord {
    defer args.vertex_source.decref(host);
    defer args.fragment_source.decref(host);
    const vertex_slice = args.vertex_source.asSlice();
    const fragment_slice = args.fragment_source.asSlice();
    if (vertex_slice.len == 0 and fragment_slice.len == 0) return .{ .shader = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    if (active_headless) {
        const shader = storeShader(.headless) orelse return .{ .shader = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .shader = shader, .err = RESOURCE_ERR_NONE };
    }

    const allocator = allocatorFromHost(host);
    var vertex_stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var fragment_stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var vertex = OptionalTempCString.init(allocator, &vertex_stack, vertex_slice) catch return .{ .shader = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    defer vertex.deinit();
    var fragment = OptionalTempCString.init(allocator, &fragment_stack, fragment_slice) catch return .{ .shader = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    defer fragment.deinit();
    const shader = raylib.loadShaderFromMemory(vertex.ptr(), fragment.ptr()) orelse return .{ .shader = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeShader(.{ .native = shader }) orelse return .{ .shader = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .shader = stored, .err = RESOURCE_ERR_NONE };
}

fn exportedDrawLoadShaderSourceRaw(args: abi.DrawHostLoad_shader_sourceArgs) callconv(.c) abi.DrawHostLoad_shader_sourceRetRecord {
    return hostedDrawLoadShaderSourceRaw(activeHost(), args);
}

fn nativeTextureForToken(token: u64) ?raylib.Texture {
    if (texture_heap.get(token)) |resource| {
        return switch (resource.*) {
            .headless => null,
            .native => |texture| texture,
        };
    }
    if (render_texture_heap.get(token)) |resource| {
        return switch (resource.*) {
            .headless => null,
            .native => |target| raylib.renderTextureColor(target),
        };
    }
    return null;
}

fn hostedDrawBeginRenderTextureRaw(args: abi.DrawHostBegin_render_textureArgs) callconv(.c) bool {
    const host = activeHost();
    const owner = args.resource;
    if (render_texture_lease_count == RESOURCE_SCOPE_LIMIT) {
        releaseResourceBox(host, owner);
        return false;
    }
    const resource = render_texture_heap.get(owner.handle) orelse {
        releaseResourceBox(host, owner);
        return false;
    };
    switch (resource.*) {
        .headless => headless_render_texture_depth +|= 1,
        .native => |target| raylib.beginTextureMode(target),
    }
    render_texture_leases[render_texture_lease_count] = owner;
    render_texture_lease_count += 1;
    return true;
}

fn hostedDrawEndRenderTextureRaw() callconv(.c) void {
    if (render_texture_lease_count == 0) return;
    if (active_headless) headless_render_texture_depth -|= 1 else raylib.endTextureMode();
    render_texture_lease_count -= 1;
    const owner = render_texture_leases[render_texture_lease_count].?;
    render_texture_leases[render_texture_lease_count] = null;
    if (!active_headless and render_texture_lease_count > 0) {
        const outer = render_texture_leases[render_texture_lease_count - 1].?;
        if (render_texture_heap.get(outer.handle)) |resource| raylib.beginTextureMode(resource.native);
    }
    releaseResourceBox(activeHost(), owner);
}

fn hostedDrawBeginShaderRaw(args: abi.DrawHostBegin_shaderArgs) callconv(.c) bool {
    const host = activeHost();
    const owner = args.arg0;
    if (shader_lease_count == RESOURCE_SCOPE_LIMIT) {
        releaseResourceBox(host, owner);
        return false;
    }
    const resource = shader_heap.get(owner.*) orelse {
        releaseResourceBox(host, owner);
        return false;
    };
    switch (resource.*) {
        .headless => headless_shader_depth +|= 1,
        .native => |shader| raylib.beginShaderMode(shader),
    }
    shader_leases[shader_lease_count] = owner;
    shader_lease_count += 1;
    return true;
}

fn hostedDrawEndShaderRaw() callconv(.c) void {
    if (shader_lease_count == 0) return;
    if (active_headless) headless_shader_depth -|= 1 else raylib.endShaderMode();
    shader_lease_count -= 1;
    const owner = shader_leases[shader_lease_count].?;
    shader_leases[shader_lease_count] = null;
    if (!active_headless and shader_lease_count > 0) {
        const outer = shader_leases[shader_lease_count - 1].?;
        if (shader_heap.get(outer.*)) |resource| raylib.beginShaderMode(resource.native);
    }
    releaseResourceBox(activeHost(), owner);
}

fn hostedDrawBeginBlendRaw(args: abi.DrawHostBegin_blendArgs) callconv(.c) bool {
    if (args.arg0 > 5) return false;
    if (active_headless) {
        headless_blend_depth +|= 1;
        return true;
    }
    raylib.beginBlendMode(args.arg0);
    return true;
}

fn hostedDrawEndBlendRaw() callconv(.c) void {
    if (active_headless) {
        headless_blend_depth -|= 1;
        return;
    }
    raylib.endBlendMode();
}

fn hostedDrawShaderLocationRaw(host: *RocHost, args: abi.DrawHostShader_locationArgs) callconv(.c) i32 {
    defer args.name.decref(host);
    defer releaseResourceBox(host, args.shader);
    const resource = shader_heap.get(args.shader.*) orelse return -1;
    const name_slice = args.name.asSlice();
    if (name_slice.len == 0) return -1;
    switch (resource.*) {
        .headless => return 0,
        .native => |shader| {
            var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
            var name = makeTempCString(allocatorFromHost(host), &stack, name_slice) catch return -1;
            defer name.deinit();
            return raylib.shaderLocation(shader, name.ptr);
        },
    }
}

fn exportedDrawShaderLocationRaw(args: abi.DrawHostShader_locationArgs) callconv(.c) i32 {
    return hostedDrawShaderLocationRaw(activeHost(), args);
}

fn hostedDrawSetShaderFloatRaw(args: abi.DrawHostSet_shader_floatArgs) callconv(.c) void {
    defer args.uniform.decref(activeHost());
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderFloat(resource.native, args.uniform.location, args.value);
}

fn hostedDrawSetShaderIntRaw(args: abi.DrawHostSet_shader_intArgs) callconv(.c) void {
    defer args.uniform.decref(activeHost());
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderInt(resource.native, args.uniform.location, args.value);
}

fn hostedDrawSetShaderVec2Raw(args: abi.DrawHostSet_shader_vec2Args) callconv(.c) void {
    defer args.uniform.decref(activeHost());
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderVec2(resource.native, args.uniform.location, .{ args.value.x, args.value.y });
}

fn hostedDrawSetShaderVec3Raw(args: abi.DrawHostSet_shader_vec3Args) callconv(.c) void {
    defer args.uniform.decref(activeHost());
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderVec3(resource.native, args.uniform.location, .{ args.value.x, args.value.y, args.value.z });
}

fn hostedDrawSetShaderVec4Raw(args: abi.DrawHostSet_shader_vec4Args) callconv(.c) void {
    defer args.uniform.decref(activeHost());
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderVec4(resource.native, args.uniform.location, .{ args.value.x, args.value.y, args.value.z, args.value.w });
}

fn hostedDrawSetShaderTextureRaw(args: abi.DrawHostSet_shader_textureArgs) callconv(.c) void {
    defer args.uniform.decref(activeHost());
    defer args.texture.decref(activeHost());
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    const texture = nativeTextureForToken(args.texture.resource.handle) orelse return;
    raylib.setShaderTexture(resource.native, args.uniform.location, texture);
}

fn hostedDrawBeginFrame() callconv(.c) void {
    if (active_headless) return;
    raylib.beginDrawing();
}

/// Forward Roc scissor bounds to the raylib backend.
fn hostedDrawBeginScissorRaw(args: abi.DrawHostBegin_scissorArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.beginScissor(args.x, args.y, args.width, args.height);
}

/// End the scissor region opened by the Roc renderer.
fn hostedDrawEndScissorRaw() callconv(.c) void {
    if (active_headless) return;
    raylib.endScissor();
}

fn hostedDrawBeginCamera(args: abi.DrawHostBegin_cameraArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.beginMode2D(args);
}

fn hostedDrawCircleRaw(args: abi.DrawHostCircleArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawCircle(args);
}

fn hostedDrawCircleGradient(args: abi.DrawHostCircle_gradientArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawCircleGradient(args);
}

fn hostedDrawCircleLinesRaw(args: abi.DrawHostCircle_linesArgs) callconv(.c) void {
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

fn hostedDrawFps(args: abi.DrawHostFpsArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawFps(args);
}

fn hostedDrawLineRaw(args: abi.DrawHostLineArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawLine(args);
}

fn hostedDrawPolygonRaw(host: *RocHost, args: abi.DrawHostPolygonArgs) callconv(.c) void {
    defer args.points.decref(host);
    if (active_headless) return;
    raylib.drawPolygon(args.points.items(), args.color);
}

fn exportedDrawPolygonRaw(args: abi.DrawHostPolygonArgs) callconv(.c) void {
    hostedDrawPolygonRaw(activeHost(), args);
}

fn hostedDrawPolygonLinesRaw(host: *RocHost, args: abi.DrawHostPolygon_linesArgs) callconv(.c) void {
    defer args.points.decref(host);
    if (active_headless) return;
    raylib.drawPolygonLines(args.points.items(), args.thickness, args.color);
}

fn exportedDrawPolygonLinesRaw(args: abi.DrawHostPolygon_linesArgs) callconv(.c) void {
    hostedDrawPolygonLinesRaw(activeHost(), args);
}

fn hostedDrawRectangleRaw(args: abi.DrawHostRectangleArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawRectangle(args);
}

fn hostedDrawRectangleLinesRaw(args: abi.DrawHostRectangle_linesArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawRectangleLines(args);
}

fn hostedDrawRectangleGradientH(args: abi.DrawHostRectangle_gradient_hArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawRectangleGradientH(args);
}

fn hostedDrawRectangleGradientV(args: abi.DrawHostRectangle_gradient_vArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawRectangleGradientV(args);
}

fn hostedDrawRoundedRectangleRaw(args: abi.DrawHostRounded_rectangleArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawRoundedRectangle(args);
}

fn hostedDrawRoundedRectangleLinesRaw(args: abi.DrawHostRounded_rectangle_linesArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawRoundedRectangleLines(args);
}

fn hostedDrawTriangleRaw(args: abi.DrawHostTriangleArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawTriangle(args);
}

fn hostedDrawTriangleLinesRaw(args: abi.DrawHostTriangle_linesArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.drawTriangleLines(args);
}

fn hostedDrawLoadFontRaw(host: *RocHost, args: abi.DrawHostLoad_fontArgs) callconv(.c) abi.DrawHostLoad_fontRetRecord {
    defer args.path.decref(host);

    const path_slice = args.path.asSlice();
    if (active_headless) {
        if (!pathExists(path_slice)) return .{ .font = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
        const font = storeFont(.headless) orelse return .{ .font = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .font = font, .err = RESOURCE_ERR_NONE };
    }

    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromHost(host), &stack, path_slice) catch return .{ .font = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    defer path.deinit();

    const font = raylib.loadFont(path.ptr, args.size) orelse return .{ .font = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeFont(.{ .native = font }) orelse return .{ .font = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .font = stored, .err = RESOURCE_ERR_NONE };
}

fn exportedDrawLoadFontRaw(args: abi.DrawHostLoad_fontArgs) callconv(.c) abi.DrawHostLoad_fontRetRecord {
    return hostedDrawLoadFontRaw(activeHost(), args);
}

fn fontForValue(font_value: *const abi.DefaultFontOrLoadedFont) raylib.Font {
    if (font_value.tag == .DefaultFont) return raylib.defaultFont();
    const resource = font_heap.get(font_value.payload_loaded_font().*) orelse return raylib.defaultFont();
    return switch (resource.*) {
        .headless => raylib.defaultFont(),
        .native => |font| font,
    };
}

fn hostedDrawMeasureTextRaw(host: *RocHost, args: abi.DrawHostMeasure_textArgs) callconv(.c) abi.DrawHostMeasure_textRetRecord {
    defer args.text.decref(host);
    defer args.font.decref(host);
    var result: abi.DrawHostMeasure_textRetRecord = .{ .height = 0, .width = 0 };

    const text_slice = args.text.asSlice();
    if (active_headless) return headlessMeasureText(text_slice, args.size, args.spacing);

    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var text = makeTempCString(allocatorFromHost(host), &stack, text_slice) catch return result;
    defer text.deinit();

    const measured = raylib.measureTextZ(text.ptr, fontForValue(&args.font), args.size, args.spacing);
    result = .{ .height = measured.y, .width = measured.x };
    return result;
}

fn exportedDrawMeasureTextRaw(args: abi.DrawHostMeasure_textArgs) callconv(.c) abi.DrawHostMeasure_textRetRecord {
    return hostedDrawMeasureTextRaw(activeHost(), args);
}

fn hostedDrawTextRaw(host: *RocHost, args: abi.DrawHostTextArgs) callconv(.c) void {
    defer args.text.decref(host);
    defer args.font.decref(host);
    if (active_headless) return;

    const text_slice = args.text.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var text = makeTempCString(allocatorFromHost(host), &stack, text_slice) catch return;
    defer text.deinit();

    raylib.drawTextZ(
        text.ptr,
        fontForValue(&args.font),
        .{ .x = args.pos.x, .y = args.pos.y },
        args.size,
        args.spacing,
        args.color,
    );
}

fn exportedDrawTextRaw(args: abi.DrawHostTextArgs) callconv(.c) void {
    hostedDrawTextRaw(activeHost(), args);
}

fn hostedDrawTextAlignedRaw(host: *RocHost, args: abi.DrawHostText_alignedArgs) callconv(.c) void {
    defer args.text.decref(host);
    defer args.font.decref(host);
    if (active_headless) return;

    const text_slice = args.text.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var text = makeTempCString(allocatorFromHost(host), &stack, text_slice) catch return;
    defer text.deinit();

    raylib.drawTextAlignedZ(
        text.ptr,
        fontForValue(&args.font),
        .{ .x = args.pos.x, .y = args.pos.y },
        args.size,
        args.spacing,
        args.color,
        .{ .x = args.align_x, .y = args.align_y },
    );
}

fn exportedDrawTextAlignedRaw(args: abi.DrawHostText_alignedArgs) callconv(.c) void {
    hostedDrawTextAlignedRaw(activeHost(), args);
}

fn hostedDrawTextureRaw(args: abi.DrawHostDraw_textureArgs) callconv(.c) void {
    defer args.texture.decref(activeHost());
    if (active_headless) return;
    const texture = nativeTextureForToken(args.texture.resource.handle) orelse return;
    raylib.drawTexture(texture, args);
}

fn hostedDrawTextureQuadRaw(args: abi.DrawHostDraw_texture_quadArgs) callconv(.c) void {
    defer args.texture.decref(activeHost());
    if (active_headless) return;
    const texture = nativeTextureForToken(args.texture.resource.handle) orelse return;
    raylib.drawTextureQuad(texture, args);
}

/// Global flag for deferred exit request (exit after current frame completes)
var exit_requested: ?i64 = null;

fn hostedReadEnvWindows(roc_host: *RocHost, key_arg: abi.RocStr) callconv(.c) ReadEnvResult {
    // Windows doesn't link libc, so env var reading is not yet supported
    var result: ReadEnvResult = undefined;
    result.tag = .Err;

    key_arg.decref(roc_host);
    return result;
}

fn exportedReadEnvWindows(key_arg: abi.RocStr) callconv(.c) ReadEnvResult {
    return hostedReadEnvWindows(activeHost(), key_arg);
}

fn hostedReadEnvPosix(roc_host: *RocHost, key_arg: abi.RocStr) callconv(.c) ReadEnvResult {
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
    key_arg.decref(roc_host);
    return result;
}

fn exportedReadEnvPosix(key_arg: abi.RocStr) callconv(.c) ReadEnvResult {
    return hostedReadEnvPosix(activeHost(), key_arg);
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

fn hostedSetScreenSize(args: abi.HostHostSet_screen_sizeArgs) callconv(.c) u8 {
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

fn hostedMouseShowCursor() callconv(.c) void {
    if (!active_headless) raylib.showCursor();
}

fn hostedMouseHideCursor() callconv(.c) void {
    if (!active_headless) raylib.hideCursor();
}

fn hostedMouseLockCursor() callconv(.c) void {
    if (!active_headless) raylib.disableCursor();
}

fn hostedMouseUnlockCursor() callconv(.c) void {
    if (!active_headless) raylib.enableCursor();
}

fn mouseCursorFromCode(code: u8) raylib.MouseCursor {
    if (code > @intFromEnum(raylib.MouseCursor.not_allowed)) return .default;
    return @enumFromInt(code);
}

fn hostedMouseSetCursorRaw(cursor: u8) callconv(.c) void {
    if (active_headless) return;
    raylib.setMouseCursor(mouseCursorFromCode(cursor));
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

fn storeSound(resource: SoundResource) ?*u64 {
    return sound_heap.insert(0, resource) orelse {
        var rejected = resource;
        destroySound(&rejected);
        return null;
    };
}

fn storeMusic(resource: MusicResource) ?*u64 {
    return music_heap.insert(0, resource) orelse {
        var rejected = resource;
        destroyMusic(&rejected);
        return null;
    };
}

fn hostedAudioGenTone(args: abi.AudioHostGen_toneArgs) callconv(.c) abi.AudioHostGen_toneRetRecord {
    if (active_headless) {
        const sound = storeSound(.headless) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .sound = sound, .err = RESOURCE_ERR_NONE };
    }
    const sound = raylib.genTone(args.freq, args.ms) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeSound(.{ .native = sound }) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .sound = stored, .err = RESOURCE_ERR_NONE };
}

fn hostedAudioGenSound(args: abi.AudioHostGen_soundArgs) callconv(.c) abi.AudioHostGen_soundRetRecord {
    if (active_headless) {
        const sound = storeSound(.headless) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .sound = sound, .err = RESOURCE_ERR_NONE };
    }
    const sound = raylib.genSound(args) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeSound(.{ .native = sound }) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .sound = stored, .err = RESOURCE_ERR_NONE };
}

fn hostedAudioLoadSound(host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.AudioHostLoad_soundRetRecord {
    defer path_arg.decref(host);

    const path_slice = path_arg.asSlice();
    if (active_headless) {
        if (!pathExists(path_slice)) return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
        const sound = storeSound(.headless) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .sound = sound, .err = RESOURCE_ERR_NONE };
    }

    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromHost(host), &stack, path_slice) catch return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    defer path.deinit();

    const sound = raylib.loadSound(path.ptr) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeSound(.{ .native = sound }) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .sound = stored, .err = RESOURCE_ERR_NONE };
}

fn exportedAudioLoadSound(path_arg: abi.RocStr) callconv(.c) abi.AudioHostLoad_soundRetRecord {
    return hostedAudioLoadSound(activeHost(), path_arg);
}

fn hostedAudioLoadMusic(host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.AudioHostLoad_musicRetRecord {
    defer path_arg.decref(host);

    const path_slice = path_arg.asSlice();
    if (active_headless) {
        if (!pathExists(path_slice)) return .{ .music = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
        const music = storeMusic(.headless) orelse return .{ .music = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .music = music, .err = RESOURCE_ERR_NONE };
    }

    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var path = makeTempCString(allocatorFromHost(host), &stack, path_slice) catch return .{ .music = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    defer path.deinit();

    const music = raylib.loadMusic(path.ptr) orelse return .{ .music = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeMusic(.{ .native = music }) orelse return .{ .music = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .music = stored, .err = RESOURCE_ERR_NONE };
}

fn exportedAudioLoadMusic(path_arg: abi.RocStr) callconv(.c) abi.AudioHostLoad_musicRetRecord {
    return hostedAudioLoadMusic(activeHost(), path_arg);
}

fn hostedAudioPlay(handle: *u64) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.playSound(sound),
    }
}

fn hostedAudioStop(handle: *u64) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.stopSound(sound),
    }
}

fn hostedAudioPause(handle: *u64) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.pauseSound(sound),
    }
}

fn hostedAudioResume(handle: *u64) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.resumeSound(sound),
    }
}

fn hostedAudioIsPlaying(handle: *u64) callconv(.c) bool {
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return false;
    return switch (resource.*) {
        .headless => false,
        .native => |sound| raylib.isSoundPlaying(sound),
    };
}

fn hostedAudioSetVolume(handle: *u64, volume: f32) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.setSoundVolume(sound, volume),
    }
}

fn hostedAudioSetPitch(handle: *u64, pitch: f32) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.setSoundPitch(sound, pitch),
    }
}

fn hostedAudioSetPan(handle: *u64, pan: f32) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.setSoundPan(sound, pan),
    }
}

fn hostedAudioPlayMusic(handle: *u64) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.playMusic(music),
    }
}

fn hostedAudioStopMusic(handle: *u64) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.stopMusic(music),
    }
}

fn hostedAudioPauseMusic(handle: *u64) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.pauseMusic(music),
    }
}

fn hostedAudioResumeMusic(handle: *u64) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.resumeMusic(music),
    }
}

fn hostedAudioSetMusicVolume(handle: *u64, volume: f32) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.setMusicVolume(music, volume),
    }
}

fn hostedAudioSetMusicPitch(handle: *u64, pitch: f32) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.setMusicPitch(music, pitch),
    }
}

fn hostedAudioSetMusicPan(handle: *u64, pan: f32) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.setMusicPan(music, pan),
    }
}

fn hostedAudioSetMusicLooping(handle: *u64, looping: bool) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |*music| raylib.setMusicLooping(music, looping),
    }
}

fn hostedAudioIsMusicPlaying(handle: *u64) callconv(.c) bool {
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return false;
    return switch (resource.*) {
        .headless => false,
        .native => |music| raylib.isMusicPlaying(music),
    };
}

fn hostedAudioSeekMusic(handle: *u64, seconds: f32) callconv(.c) void {
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.seekMusic(music, seconds),
    }
}

fn hostedAudioMusicLength(handle: *u64) callconv(.c) f32 {
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return 0;
    return switch (resource.*) {
        .headless => 0,
        .native => |music| raylib.musicLength(music),
    };
}

fn hostedAudioMusicTimePlayed(handle: *u64) callconv(.c) f32 {
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return 0;
    return switch (resource.*) {
        .headless => 0,
        .native => |music| raylib.musicTimePlayed(music),
    };
}

fn hostedAudioSetMasterVolume(volume: f32) callconv(.c) void {
    if (active_headless) return;
    raylib.setMasterVolume(volume);
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
    std.debug.assert(render_texture_lease_count == 0);
    std.debug.assert(shader_lease_count == 0);
    std.debug.assert(texture_heap.active() == 0);
    std.debug.assert(render_texture_heap.active() == 0);
    std.debug.assert(shader_heap.active() == 0);
    std.debug.assert(font_heap.active() == 0);
    std.debug.assert(music_heap.active() == 0);
    std.debug.assert(sound_heap.active() == 0);
    shader_heap.deinitAll();
    render_texture_heap.deinitAll();
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
        @export(&hostedAssetsGenerateColorTextureRaw, .{ .name = "roc_assets_generate_color_texture_raw" });
        @export(&hostedAssetsGenerateCheckedTextureRaw, .{ .name = "roc_assets_generate_checked_texture_raw" });
        @export(&exportedAssetsUpdateTextureRaw, .{ .name = "roc_assets_update_texture_raw" });
        @export(&hostedAssetsSetTextureFilterRaw, .{ .name = "roc_assets_set_texture_filter_raw" });
        @export(&hostedAssetsSetTextureWrapRaw, .{ .name = "roc_assets_set_texture_wrap_raw" });
        @export(&hostedAudioGenSound, .{ .name = "roc_audio_gen_sound_raw" });
        @export(&hostedAudioGenTone, .{ .name = "roc_audio_gen_tone_raw" });
        @export(&exportedAudioLoadMusic, .{ .name = "roc_audio_load_music_raw" });
        @export(&exportedAudioLoadSound, .{ .name = "roc_audio_load_sound_raw" });
        @export(&hostedAudioPauseMusic, .{ .name = "roc_audio_pause_music_raw" });
        @export(&hostedAudioPause, .{ .name = "roc_audio_pause_raw" });
        @export(&hostedAudioPlayMusic, .{ .name = "roc_audio_play_music_raw" });
        @export(&hostedAudioPlay, .{ .name = "roc_audio_play_raw" });
        @export(&hostedAudioResumeMusic, .{ .name = "roc_audio_resume_music_raw" });
        @export(&hostedAudioResume, .{ .name = "roc_audio_resume_raw" });
        @export(&hostedAudioIsMusicPlaying, .{ .name = "roc_audio_is_music_playing_raw" });
        @export(&hostedAudioIsPlaying, .{ .name = "roc_audio_is_playing_raw" });
        @export(&hostedAudioSeekMusic, .{ .name = "roc_audio_seek_music_raw" });
        @export(&hostedAudioMusicLength, .{ .name = "roc_audio_music_length_raw" });
        @export(&hostedAudioMusicTimePlayed, .{ .name = "roc_audio_music_time_played_raw" });
        @export(&hostedAudioSetMasterVolume, .{ .name = "roc_audio_set_master_volume_raw" });
        @export(&hostedAudioSetMusicLooping, .{ .name = "roc_audio_set_music_looping_raw" });
        @export(&hostedAudioSetMusicPan, .{ .name = "roc_audio_set_music_pan_raw" });
        @export(&hostedAudioSetMusicPitch, .{ .name = "roc_audio_set_music_pitch_raw" });
        @export(&hostedAudioSetMusicVolume, .{ .name = "roc_audio_set_music_volume_raw" });
        @export(&hostedAudioSetPan, .{ .name = "roc_audio_set_pan_raw" });
        @export(&hostedAudioSetPitch, .{ .name = "roc_audio_set_pitch_raw" });
        @export(&hostedAudioSetVolume, .{ .name = "roc_audio_set_volume_raw" });
        @export(&hostedAudioStopMusic, .{ .name = "roc_audio_stop_music_raw" });
        @export(&hostedAudioStop, .{ .name = "roc_audio_stop_raw" });
        @export(&hostedDrawBeginCamera, .{ .name = "roc_draw_begin_camera" });
        @export(&hostedDrawBeginBlendRaw, .{ .name = "roc_draw_begin_blend_raw" });
        @export(&hostedDrawBeginFrame, .{ .name = "roc_draw_begin_frame" });
        @export(&hostedDrawBeginRenderTextureRaw, .{ .name = "roc_draw_begin_render_texture_raw" });
        @export(&hostedDrawBeginScissorRaw, .{ .name = "roc_draw_begin_scissor_raw" });
        @export(&hostedDrawBeginShaderRaw, .{ .name = "roc_draw_begin_shader_raw" });
        @export(&hostedDrawCircleGradient, .{ .name = "roc_draw_circle_gradient" });
        @export(&hostedDrawCircleLinesRaw, .{ .name = "roc_draw_circle_lines_raw" });
        @export(&hostedDrawCircleRaw, .{ .name = "roc_draw_circle_raw" });
        @export(&hostedDrawClear, .{ .name = "roc_draw_clear" });
        @export(&hostedDrawTextureRaw, .{ .name = "roc_draw_draw_texture_raw" });
        @export(&hostedDrawTextureQuadRaw, .{ .name = "roc_draw_draw_texture_quad_raw" });
        @export(&hostedDrawEndCamera, .{ .name = "roc_draw_end_camera" });
        @export(&hostedDrawEndBlendRaw, .{ .name = "roc_draw_end_blend_raw" });
        @export(&hostedDrawEndFrame, .{ .name = "roc_draw_end_frame" });
        @export(&hostedDrawEndRenderTextureRaw, .{ .name = "roc_draw_end_render_texture_raw" });
        @export(&hostedDrawEndScissorRaw, .{ .name = "roc_draw_end_scissor_raw" });
        @export(&hostedDrawEndShaderRaw, .{ .name = "roc_draw_end_shader_raw" });
        @export(&hostedDrawFps, .{ .name = "roc_draw_fps" });
        @export(&hostedDrawLineRaw, .{ .name = "roc_draw_line_raw" });
        @export(&exportedDrawLoadFontRaw, .{ .name = "roc_draw_load_font_raw" });
        @export(&hostedDrawLoadRenderTextureRaw, .{ .name = "roc_draw_load_render_texture_raw" });
        @export(&exportedDrawLoadShaderRaw, .{ .name = "roc_draw_load_shader_raw" });
        @export(&exportedDrawLoadShaderSourceRaw, .{ .name = "roc_draw_load_shader_source_raw" });
        @export(&exportedDrawMeasureTextRaw, .{ .name = "roc_draw_measure_text_raw" });
        @export(&exportedDrawPolygonLinesRaw, .{ .name = "roc_draw_polygon_lines_raw" });
        @export(&exportedDrawPolygonRaw, .{ .name = "roc_draw_polygon_raw" });
        @export(&exportedDrawShaderLocationRaw, .{ .name = "roc_draw_shader_location_raw" });
        @export(&hostedDrawSetShaderFloatRaw, .{ .name = "roc_draw_set_shader_float_raw" });
        @export(&hostedDrawSetShaderIntRaw, .{ .name = "roc_draw_set_shader_int_raw" });
        @export(&hostedDrawSetShaderTextureRaw, .{ .name = "roc_draw_set_shader_texture_raw" });
        @export(&hostedDrawSetShaderVec2Raw, .{ .name = "roc_draw_set_shader_vec2_raw" });
        @export(&hostedDrawSetShaderVec3Raw, .{ .name = "roc_draw_set_shader_vec3_raw" });
        @export(&hostedDrawSetShaderVec4Raw, .{ .name = "roc_draw_set_shader_vec4_raw" });
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
        @export(&hostedMouseShowCursor, .{ .name = "roc_mouse_show_cursor" });
        @export(&hostedMouseHideCursor, .{ .name = "roc_mouse_hide_cursor" });
        @export(&hostedMouseLockCursor, .{ .name = "roc_mouse_lock_cursor" });
        @export(&hostedMouseUnlockCursor, .{ .name = "roc_mouse_unlock_cursor" });
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
    gamepad_available: ffi.GamepadAvailability,
    gamepad_buttons: ffi.GamepadButtons,
    gamepad_axes: ffi.GamepadAxes,
    text_input: ffi.TextInput,

    fn init(roc_host: *RocHost) InputState {
        return .{
            .keys = ffi.Keys.init(roc_host),
            .mouse_buttons = ffi.MouseButtons.init(roc_host),
            .gamepad_available = ffi.GamepadAvailability.init(roc_host),
            .gamepad_buttons = ffi.GamepadButtons.init(roc_host),
            .gamepad_axes = ffi.GamepadAxes.init(roc_host),
            .text_input = ffi.TextInput.init(roc_host),
        };
    }

    fn deinit(self: *InputState) void {
        self.text_input.decref();
        self.gamepad_axes.decref();
        self.gamepad_buttons.decref();
        self.gamepad_available.decref();
        self.mouse_buttons.decref();
        self.keys.decref();
    }

    fn retainForRoc(self: *InputState) void {
        self.text_input.incref();
        self.keys.incref();
        self.mouse_buttons.incref();
        self.gamepad_available.incref();
        self.gamepad_buttons.incref();
        self.gamepad_axes.incref();
    }

    fn hostState(
        self: *InputState,
        frame_count: u64,
        timestamp_nanos: u64,
        frame_time: f32,
        mouse_x: f32,
        mouse_y: f32,
        mouse_delta: raylib.Vec2,
        mouse_wheel: raylib.Vec2,
        text_input: []const u32,
    ) HostState {
        self.text_input.update(text_input);
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
            .text_input = self.text_input.list,
            .gamepads = .{
                .available = self.gamepad_available.list,
                .buttons = self.gamepad_buttons.list,
                .axes = self.gamepad_axes.list,
            },
            .mouse = .{
                .buttons = self.mouse_buttons.list,
                .left = self.mouse_buttons.hasFlag(0, ffi.INPUT_HELD),
                .middle = self.mouse_buttons.hasFlag(2, ffi.INPUT_HELD),
                .right = self.mouse_buttons.hasFlag(1, ffi.INPUT_HELD),
                .wheel = mouse_wheel.y,
                .wheel_x = mouse_wheel.x,
                .wheel_y = mouse_wheel.y,
                .delta_x = mouse_delta.x,
                .delta_y = mouse_delta.y,
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

        raylib.updateGamepadState();
        self.gamepad_available.update(raylib.getGamepadAvailability());
        self.gamepad_buttons.update(raylib.getGamepadButtonState());
        self.gamepad_axes.update(raylib.getGamepadAxes());
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

/// Transfer the host's current model reference into a Roc entrypoint.
///
/// `render_for_host` consumes its Box argument even when it returns `Err`, so
/// clear the host slot before the call. Only an `Ok` result installs a new
/// owned model reference.
fn takeModelForRender(boxed_model: *RocBox) RocBox {
    const transferred = boxed_model.*;
    boxed_model.* = null;
    return transferred;
}

test "taking a model for render clears the host-owned reference" {
    const model: *anyopaque = @ptrFromInt(@alignOf(usize));
    var boxed_model: RocBox = model;

    try std.testing.expectEqual(model, takeModelForRender(&boxed_model));
    try std.testing.expectEqual(null, boxed_model);
}

fn initModel(input: *InputState) RocResult {
    if (TRACE_HOST) std.log.debug("[HOST] Calling init_for_host...", .{});
    const init_state = input.hostState(0, 0, 0, 0, 0, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 }, &.{});
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
        const mouse_delta = raylib.getMouseDelta();
        const mouse_wheel = raylib.getMouseWheelMoveV();
        const text_input = raylib.getTextInput();
        const platform_state = input.hostState(
            frame_count,
            now_ns,
            frame_time,
            mouse_pos.x,
            mouse_pos.y,
            mouse_delta,
            mouse_wheel,
            text_input,
        );

        const render_result = render_for_host(takeModelForRender(&boxed_model), platform_state);
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
            .{ .x = 0, .y = 0 },
            .{ .x = 0, .y = 0 },
            &.{},
        );

        const render_result = render_for_host(takeModelForRender(&boxed_model), platform_state);
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
