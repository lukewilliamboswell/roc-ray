///! Platform host for roc-ray using the raylib graphics library.
const std = @import("std");
const builtin = @import("builtin");

// Import generated platform ABI (use for hosted function arg/ret types)
const abi = @import("roc_platform_abi.zig");

// Import FFI conversion utilities
const ffi = @import("roc_ffi.zig");
const capture = @import("capture.zig");
const capture_vp8 = @import("capture_vp8.zig");
const gif_encoder = @import("gif_encoder.zig");
const host_resource = @import("host_resource.zig");
const tilemap_batch = @import("tilemap_batch.zig");
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
const Color = abi.ColorRgba;
const ReadEnvResult = abi.HostHostRead_envResult;
// get_clipboard_text! returns Try(Str, [Unavailable]) -- the same shape as
// read_env!'s result, generated separately because the error tag differs.
const ClipboardTextResult = abi.HostHostGet_clipboard_textResult;
const ClipboardTextResultTag = abi.HostHostGet_clipboard_textResultTag;
const HostReadFileRawResult = abi.HostHostRead_fileRetRecord;
const TilemapLoadTmxRawResult = abi.TilemapHostLoad_tmxRetRecord;
const AppConfig = abi.App_config_for_host;
// One cycle of observations handed to update!. Unions do not cross this
// boundary, so completions arrive as flat records that Roc decodes.
const StepFromHost = abi.Update_for_hostArg1;
const UpdateResult = abi.Update_for_hostResult;
const CompletionFromHost = abi.Update_for_hostArg1Completed;
const CommandToHost = abi.Update_for_hostOkCommands;
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
const SCOPE_OK: u8 = 0;
const SCOPE_UNAVAILABLE: u8 = 1;
const SCOPE_LIMIT: u8 = 2;
const TEXTURE_UPDATE_OK: u8 = 0;
const TEXTURE_UPDATE_PIXEL_COUNT: u8 = 1;
const TEXTURE_UPDATE_NOT_MUTABLE: u8 = 2;
const TRY_TAG_OK: u8 = 1;
const MAX_HOST_TEXT_FILE_BYTES: usize = 16 * 1024 * 1024;
const HEADLESS_CLIPBOARD_CAPACITY: usize = 4096;

extern fn app_config_for_host() callconv(.c) AppConfig;
extern fn init_for_host(arg0: HostState) callconv(.c) RocResult;
extern fn update_for_host(arg0: RocBox, arg1: StepFromHost) callconv(.c) UpdateResult;
extern fn render_for_host(arg0: RocBox) callconv(.c) RocResult;
extern fn drop_model_for_host(arg0: RocBox) callconv(.c) void;

/// `kind` codes for a completion. Mirrored in `platform/Program.roc`.
const COMPLETION_FILE_READ: u8 = 0;
const COMPLETION_DELAY: u8 = 1;

/// `kind` codes for a command returned by `update!`. Mirrored in `platform/Program.roc`.
const CMD_READ_FILE: u8 = 0;
const CMD_DELAY: u8 = 1;

/// Read-error codes. Mirrored in `platform/Program.roc`.
///
/// `BUSY` and `UNAVAILABLE` are refusals rather than failures: the host declined
/// to start the work rather than running it on the frame thread.
const READ_ERR_NOT_FOUND: u8 = 1;
const READ_ERR_FAILED: u8 = 2;
const READ_ERR_BUSY: u8 = 3;
const READ_ERR_UNAVAILABLE: u8 = 4;






/// Blocking effects, run off the main thread.
///
/// The contract that makes this safe is narrow, and stating it plainly is the
/// point of the whole design: **the worker never calls Roc, never allocates or
/// frees Roc memory, never reads `active_roc_host`, and never touches a
/// resource heap.** It takes plain-Zig requests and posts plain-Zig results;
/// the main thread turns a result into a Roc value while draining the queue.
///
/// That is what buys non-blocking I/O without atomic refcounts. `roc_alloc`
/// and the resource heaps stay exactly as single-threaded as they were.
///
/// Two caveats the invariant does not cover, both currently satisfied:
/// the worker shares the host allocator, so that allocator must be thread-safe
/// (`std.heap.smp_allocator` is; `DebugAllocator` is unless `thread_safe` is
/// turned off); and `std.Io.Threaded.init` installs process-wide SIGPIPE and
/// SIGIO handlers, restoring them on `deinit`.
///
/// Both rings are single-producer/single-consumer -- main writes requests and
/// reads results, the worker does the reverse -- so acquire/release on the
/// indices is sufficient and no lock is involved. Zig 0.16 moved `Mutex` into
/// `std.Io` where locking is cancelable and takes an `Io`; sidestepping it
/// keeps the boundary obviously just data.
const EffectWorker = struct {
    /// Power of two so the index wrap is a mask.
    const capacity: usize = 64;
    const mask: usize = capacity - 1;

    const Request = struct {
        id: u64,
        path: [capture.path_capacity]u8,
        path_len: usize,
    };

    /// `bytes` is owned by `allocator` until the main thread copies it into a
    /// `RocStr` and frees it.
    const Result = struct {
        id: u64,
        bytes: ?[]u8,
        err: u8,
    };

    requests: [capacity]Request = undefined,
    request_write: std.atomic.Value(usize) = .init(0),
    request_read: std.atomic.Value(usize) = .init(0),

    results: [capacity]Result = undefined,
    result_write: std.atomic.Value(usize) = .init(0),
    result_read: std.atomic.Value(usize) = .init(0),

    should_stop: std.atomic.Value(bool) = .init(false),

    /// Whether requests will be serviced. Separate from `thread` so the ring
    /// can be tested without spawning one.
    accepting: bool = false,
    thread: ?std.Thread = null,
    allocator: std.mem.Allocator = undefined,

    fn start(self: *EffectWorker, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
        self.should_stop.store(false, .release);
        self.accepting = true;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            self.accepting = false;
            // Running effects inline still works; results just arrive on the
            // frame the command was issued rather than a later one.
            std.log.warn("roc-ray could not start the effect worker ({s}); effects run inline", .{@errorName(err)});
            return;
        };
    }

    fn stop(self: *EffectWorker) void {
        self.accepting = false;
        if (self.thread) |thread| {
            self.should_stop.store(true, .release);
            thread.join();
            self.thread = null;
        }
        // Results that completed after the final drain still own buffers.
        while (self.takeResult()) |result| {
            if (result.bytes) |bytes| self.allocator.free(bytes);
        }
    }

    /// Why a submission was refused, so the caller can report it rather than
    /// dropping the command or running it on the frame thread.
    const Submission = enum { accepted, busy, unavailable };

    /// Queue a read.
    fn submitReadFile(self: *EffectWorker, id: u64, path: []const u8) Submission {
        if (!self.accepting) return .unavailable;
        if (path.len > capture.path_capacity) return .unavailable;

        const write = self.request_write.load(.monotonic);
        if (write -% self.request_read.load(.acquire) >= capacity) return .busy;

        const slot = &self.requests[write & mask];
        // The worker cannot borrow the Roc string the path arrived in.
        @memcpy(slot.path[0..path.len], path);
        slot.path_len = path.len;
        slot.id = id;
        self.request_write.store(write +% 1, .release);
        return .accepted;
    }

    fn takeResult(self: *EffectWorker) ?Result {
        const read = self.result_read.load(.monotonic);
        if (read == self.result_write.load(.acquire)) return null;
        const result = self.results[read & mask];
        self.result_read.store(read +% 1, .release);
        return result;
    }

    fn postResult(self: *EffectWorker, result: Result) void {
        const write = self.result_write.load(.monotonic);
        if (write -% self.result_read.load(.acquire) >= capacity) {
            // The main thread has stopped draining; drop rather than block.
            if (result.bytes) |bytes| self.allocator.free(bytes);
            return;
        }
        self.results[write & mask] = result;
        self.result_write.store(write +% 1, .release);
    }

    /// The worker loop. Nothing in here may touch Roc.
    fn run(self: *EffectWorker) void {
        // Its own IO: `mainThreadIo` is explicitly single-threaded.
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        while (!self.should_stop.load(.acquire)) {
            const read = self.request_read.load(.monotonic);
            if (read == self.request_write.load(.acquire)) {
                // Polling rather than a futex keeps the boundary to plain data.
                // A millisecond of latency is immaterial next to a frame.
                std.Io.sleep(io, .fromMilliseconds(1), .awake) catch return;
                continue;
            }

            const request = self.requests[read & mask];
            self.request_read.store(read +% 1, .release);

            const path = request.path[0..request.path_len];
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(MAX_HOST_TEXT_FILE_BYTES)) catch |err| {
                self.postResult(.{
                    .id = request.id,
                    .bytes = null,
                    .err = switch (err) {
                        error.FileNotFound => HOST_ERR_NOT_FOUND,
                        else => HOST_ERR_READ_FAILED,
                    },
                });
                continue;
            };
            self.postResult(.{ .id = request.id, .bytes = bytes, .err = 0 });
        }
    }
};

var effect_worker = EffectWorker{};

/// The clock this frame reported to Roc, so a delay's deadline sits on the
/// timeline the app sees rather than on the wall clock.
var last_frame_nanos: u64 = 0;

/// Commands whose result is due once a deadline passes.
const PendingTimer = struct { id: u64, due_nanos: u64 };
var pending_timers: [32]PendingTimer = undefined;
var pending_timer_count: usize = 0;

/// How many finished commands one step may carry.
///
/// A burst of completions must not become an unbounded amount of work inside a
/// single frame, so the remainder waits for the next cycle.
const MAX_COMPLETIONS_PER_STEP: usize = 32;

/// Completions gathered for the step being assembled.
///
/// Staged in a fixed array and turned into a Roc list once, so an ordinary
/// frame -- which completes nothing -- allocates nothing at all.
const CompletionStaging = struct {
    items: [MAX_COMPLETIONS_PER_STEP]CompletionFromHost = undefined,
    len: usize = 0,

    fn full(self: *const CompletionStaging) bool {
        return self.len == MAX_COMPLETIONS_PER_STEP;
    }

    fn push(self: *CompletionStaging, item: CompletionFromHost) void {
        if (self.full()) return;
        self.items[self.len] = item;
        self.len += 1;
    }

    fn fileRead(self: *CompletionStaging, roc_host: *RocHost, id: u64, err: u8, contents: []const u8) void {
        self.push(.{
            .kind = COMPLETION_FILE_READ,
            .id = id,
            .err = err,
            .contents = if (contents.len == 0) abi.RocStr.empty() else abi.RocStr.fromSlice(contents, roc_host),
        });
    }

    fn delayElapsed(self: *CompletionStaging, id: u64) void {
        self.push(.{ .kind = COMPLETION_DELAY, .id = id, .err = 0, .contents = abi.RocStr.empty() });
    }

    /// Hand the staged completions to Roc as one list, transferring ownership.
    fn toRocList(self: *CompletionStaging, roc_host: *RocHost) abi.RocList(CompletionFromHost) {
        if (self.len == 0) return abi.RocList(CompletionFromHost).empty();
        return abi.RocList(CompletionFromHost).fromSlice(self.items[0..self.len], roc_host);
    }

    /// Release staged completions that never reached Roc.
    fn release(self: *CompletionStaging, roc_host: *RocHost) void {
        for (self.items[0..self.len]) |item| item.contents.decref(roc_host);
        self.len = 0;
    }
};

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

/// Unit tests exercise host ownership in headless mode; native rendering has
/// its own opt-in graphical smoke target and must not leak GUI link dependencies.
inline fn headlessMode() bool {
    return builtin.is_test or active_headless;
}

/// Recording policy and state for this process. See `capture.zig`.
var capture_session: capture.Session = .{};
/// Sandbox root every capture path is resolved beneath.
var capture_output_dir: [capture.path_capacity]u8 = undefined;
var capture_output_dir_len: usize = 0;
/// Output path of the active recording, copied out of the Roc-owned config.
var capture_recording_path: [capture.path_capacity]u8 = undefined;
var capture_recording_path_len: usize = 0;
/// A screenshot requested by Roc during this frame, serviced at frame end.
var capture_screenshot_path: [capture.path_capacity]u8 = undefined;
var capture_screenshot_path_len: usize = 0;
var capture_screenshot_pending: bool = false;
/// Outcome of the most recent serviced screenshot.
///
/// A screenshot is written at the end of the frame that asked for it, so the
/// effect cannot return the write's result. Latching it here lets the next
/// `Capture.screenshot!` report that the previous one failed rather than
/// letting the failure vanish.
var capture_screenshot_result: u8 = capture.err_none;
/// Frames written by the active recording, and their total size on disk.
var capture_recording_bytes: u64 = 0;
/// GIF encoder for the active recording, when its format is GIF.
var capture_gif: gif_encoder.Encoder = undefined;
var capture_gif_open: bool = false;
/// VP8/WebM encoder for the active recording, when its format is WebM.
var capture_webm: capture_vp8.Encoder = undefined;
var capture_webm_open: bool = false;
/// Render targets that shrink each frame on the GPU before it is read back.
///
/// Built on the first downscaled frame of a recording and kept for the rest of
/// it, so the per-frame cost is a blit and a readback rather than a
/// full-resolution allocation and a CPU resize. Released whenever a recording
/// ends -- see `closeCaptureSink` -- so an idle app holds no VRAM for it.
var capture_downscaler: ?raylib.CaptureDownscaler = null;
/// Latched when the GPU refuses the downscale chain, so the fallback is taken
/// once instead of retrying -- and failing -- on every captured frame.
var capture_downscale_unavailable: bool = false;
/// Scripted pointer state, replacing the hardware mouse while active.
///
/// Only what Roc is told changes; the real cursor is untouched, so a scripted
/// demo cannot run away with the user's pointer.
var virtual_mouse_active: bool = false;
var virtual_mouse_x: f32 = 0;
var virtual_mouse_y: f32 = 0;
var virtual_mouse_wheel: f32 = 0;
var virtual_mouse_buttons: [ffi.MOUSE_BUTTON_COUNT]bool = @splat(false);
/// Previous virtual position, so movement deltas match a real pointer's.
var virtual_mouse_last_x: f32 = 0;
var virtual_mouse_last_y: f32 = 0;
var virtual_mouse_has_last: bool = false;
/// Nanoseconds of divergence introduced by fixed-step recordings.
///
/// While a fixed-step recording runs we report exact `1/fps` deltas instead of
/// raylib's measured ones, so our clock and raylib's drift apart. Carrying the
/// difference keeps the clock Roc sees monotonic across the start and the end
/// of a recording, rather than jumping at each boundary.
var capture_clock_offset_ns: i128 = 0;
var capture_clock_last_real_ns: u64 = 0;

var headless_screen_width: i32 = 800;
var headless_screen_height: i32 = 600;
var headless_random_state: u32 = 0x4d595df4;
/// Headless runs never open a window, so there is no system clipboard to talk
/// to. Back the clipboard effects with a process-local buffer instead of a
/// no-op, so an example that round-trips the clipboard is still exercised by
/// the headless CI runs. Writes longer than the buffer are refused, leaving the
/// previous contents intact.
var headless_clipboard: [HEADLESS_CLIPBOARD_CAPACITY]u8 = undefined;
var headless_clipboard_len: usize = 0;
var headless_clipboard_set: bool = false;
var headless_render_texture_depth: u8 = 0;
var headless_shader_depth: u8 = 0;
const SCOPE_STACK_LIMIT: usize = 64;
var render_texture_leases: [SCOPE_STACK_LIMIT]?*abi.AssetsHostTextureResource = @splat(null);
var headless_tilemap_draw_calls: usize = 0;
var headless_tilemap_tiles: usize = 0;
var headless_tilemap_last_quad: ?TilemapQuadProbe = null;
var render_texture_lease_count: usize = 0;
var shader_leases: [SCOPE_STACK_LIMIT]?*u64 = @splat(null);
var shader_lease_count: usize = 0;
var blend_scopes: [SCOPE_STACK_LIMIT]u8 = undefined;
var blend_scope_count: usize = 0;
var camera_scopes: [SCOPE_STACK_LIMIT]abi.DrawHostBegin_cameraArgs = undefined;
var camera_scope_count: usize = 0;
var scissor_scopes: [SCOPE_STACK_LIMIT]abi.DrawHostBegin_scissorArgs = undefined;
var scissor_scope_count: usize = 0;

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

const PreparedTextResource = struct {
    allocator: std.mem.Allocator,
    text: [:0]u8,
    font: ?raylib.Font,
    font_owner: ?*u64,
    size: f32,
    spacing: f32,
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

const TilemapQuadProbe = tilemap_batch.Quad;

fn destroySound(resource: *SoundResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.unloadSound(sound),
    }
}

fn destroyMusic(resource: *MusicResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.unloadMusic(music),
    }
}

fn destroyFont(resource: *FontResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |font| if (!builtin.is_test) raylib.unloadFont(font),
    }
}

fn destroyPreparedText(resource: *PreparedTextResource) void {
    resource.allocator.free(resource.text.ptr[0 .. resource.text.len + 1]);
    if (resource.font_owner) |owner| releaseResourceBox(activeHost(), owner);
}

fn destroyTexture(resource: *TextureResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |texture| if (!builtin.is_test) raylib.unloadTexture(texture),
    }
}

fn destroyRenderTexture(resource: *RenderTextureResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |target| if (!builtin.is_test) raylib.unloadRenderTexture(target),
    }
}

fn destroyShader(resource: *ShaderResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |shader| if (!builtin.is_test) raylib.unloadShader(shader),
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
const PreparedTextHeap = host_resource.HostResourceHeap(u64, PreparedTextResource, 256, 7, writeU64Token, readU64Token, destroyPreparedText);

var sound_heap: SoundHeap = .{};
var music_heap: MusicHeap = .{};
var font_heap: FontHeap = .{};
var texture_heap: TextureHeap = .{};
var render_texture_heap: RenderTextureHeap = .{};
var shader_heap: ShaderHeap = .{};
var prepared_text_heap: PreparedTextHeap = .{};

var prepared_text_prepare_calls: usize = 0;
var prepared_text_draw_calls: usize = 0;
var prepared_text_storage_allocations: usize = 0;

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
    inline for (.{ &sound_heap, &music_heap, &font_heap, &texture_heap, &render_texture_heap, &shader_heap, &prepared_text_heap }) |heap| {
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

/// The main thread's IO implementation.
///
/// Named for the thread rather than for being a default because it is
/// explicitly single-threaded: handing this to the effect worker would be
/// unsound and would appear to work. The worker builds its own instead.
fn mainThreadIo() std.Io {
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

fn nonNegativeCInt(value: i32) c_int {
    return if (value > 0) @as(c_int, @intCast(value)) else 0;
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(mainThreadIo(), path, .{}) catch return false;
    return true;
}

fn resetHeadlessRuntime(app_config: AppConfig) void {
    capture_session.reset();
    virtual_mouse_active = false;
    virtual_mouse_has_last = false;
    virtual_mouse_buttons = @splat(false);
    virtual_mouse_wheel = 0;

    capture_screenshot_pending = false;
    capture_screenshot_result = capture.err_none;
    capture_screenshot_path_len = 0;
    capture_recording_path_len = 0;
    capture_output_dir_len = 0;
    capture_recording_bytes = 0;
    capture_clock_offset_ns = 0;
    capture_clock_last_real_ns = 0;
    headless_screen_width = positiveI32(app_config.width, 800);
    headless_screen_height = positiveI32(app_config.height, 600);
    headless_random_state = 0x4d595df4;
    headless_clipboard_len = 0;
    headless_clipboard_set = false;
    headless_render_texture_depth = 0;
    headless_shader_depth = 0;
    render_texture_lease_count = 0;
    shader_lease_count = 0;
    blend_scope_count = 0;
    camera_scope_count = 0;
    scissor_scope_count = 0;
    prepared_text_prepare_calls = 0;
    prepared_text_draw_calls = 0;
    prepared_text_storage_allocations = 0;
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

test "prepared text allocates long native bytes once and retains its loaded font" {
    try std.testing.expectEqual(@as(usize, 0), prepared_text_heap.active());
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        active_headless = false;
        active_roc_host = null;
    }

    prepared_text_prepare_calls = 0;
    prepared_text_draw_calls = 0;
    prepared_text_storage_allocations = 0;
    var long_text: [CSTRING_STACK_CAPACITY + 128]u8 = undefined;
    @memset(&long_text, 'x');
    const font = storeFont(.headless).?;
    const result = hostedDrawPrepareTextRaw(&roc_host, .{
        .font = .{ .payload = .{ .loaded_font = font }, .tag = .LoadedFont },
        .text = abi.RocStr.fromSlice(&long_text, &roc_host),
        .size = 18,
        .spacing = 1,
    });
    try std.testing.expectEqual(RESOURCE_ERR_NONE, result.err);
    try std.testing.expectEqual(@as(usize, 1), prepared_text_heap.active());
    try std.testing.expectEqual(@as(usize, 1), font_heap.active());
    const resource = prepared_text_heap.get(result.prepared.*).?;
    try std.testing.expectEqual(long_text.len, resource.text.len);
    try std.testing.expectEqual(@as(u8, 0), resource.text.ptr[resource.text.len]);

    for (0..10) |_| {
        abi.increfBox(@ptrCast(result.prepared), 1);
        hostedDrawPreparedTextRaw(&roc_host, .{
            .prepared = result.prepared,
            .pos = .{ .x = 20, .y = 30 },
            .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        });
    }
    try std.testing.expectEqual(@as(usize, 1), prepared_text_prepare_calls);
    try std.testing.expectEqual(@as(usize, 1), prepared_text_storage_allocations);
    try std.testing.expectEqual(@as(usize, 10), prepared_text_draw_calls);
    try std.testing.expectEqual(@as(usize, 1), prepared_text_heap.active());
    try std.testing.expectEqual(@as(usize, 1), font_heap.active());

    releaseResourceBox(&roc_host, result.prepared);
    try std.testing.expectEqual(@as(usize, 0), prepared_text_heap.active());
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());
}

test "prepared text rejects resource kind confusion and releases transferred owners" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        active_headless = false;
        active_roc_host = null;
    }

    const draw_shader = storeShader(.headless).?;
    hostedDrawPreparedTextRaw(&roc_host, .{
        .prepared = draw_shader,
        .pos = .{ .x = 0, .y = 0 },
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    });
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());

    const font_shader = storeShader(.headless).?;
    const result = hostedDrawPrepareTextRaw(&roc_host, .{
        .font = .{ .payload = .{ .loaded_font = font_shader }, .tag = .LoadedFont },
        .text = abi.RocStr.empty(),
        .size = 16,
        .spacing = 1,
    });
    try std.testing.expectEqual(RESOURCE_ERR_FAILED, result.err);
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    try std.testing.expectEqual(@as(usize, 0), prepared_text_heap.active());
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
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginRenderTextureRaw(.{ .resource = outer_target }));
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginRenderTextureRaw(.{ .resource = inner_target }));
    try std.testing.expectEqual(@as(usize, 2), render_texture_heap.active());
    try std.testing.expectEqual(@as(u8, 2), headless_render_texture_depth);
    hostedDrawEndRenderTextureRaw();
    try std.testing.expectEqual(@as(usize, 1), render_texture_heap.active());
    hostedDrawEndRenderTextureRaw();
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    try std.testing.expectEqual(@as(u8, 0), headless_render_texture_depth);

    const outer_shader = storeShader(.headless).?;
    const inner_shader = storeShader(.headless).?;
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginShaderRaw(.{ .arg0 = outer_shader }));
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginShaderRaw(.{ .arg0 = inner_shader }));
    try std.testing.expectEqual(@as(usize, 2), shader_heap.active());
    try std.testing.expectEqual(@as(u8, 2), headless_shader_depth);
    hostedDrawEndShaderRaw();
    try std.testing.expectEqual(@as(usize, 1), shader_heap.active());
    hostedDrawEndShaderRaw();
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    try std.testing.expectEqual(@as(u8, 0), headless_shader_depth);

    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginBlendRaw(.{ .arg0 = 1 }));
    try std.testing.expectEqual(@as(usize, 1), blend_scope_count);
    hostedDrawEndBlendRaw();
    try std.testing.expectEqual(@as(usize, 0), blend_scope_count);

    try std.testing.expectEqual(SCOPE_UNAVAILABLE, hostedDrawBeginBlendRaw(.{ .arg0 = 6 }));
    try std.testing.expectEqual(@as(usize, 0), blend_scope_count);
}

test "nested value scopes restore outer state and report bounded saturation" {
    const outer_camera = abi.DrawHostBegin_cameraArgs{
        .target = .{ .x = 10, .y = 20 },
        .offset = .{ .x = 30, .y = 40 },
        .rotation = 5,
        .zoom = 2,
    };
    const inner_camera = abi.DrawHostBegin_cameraArgs{
        .target = .{ .x = 1, .y = 2 },
        .offset = .{ .x = 3, .y = 4 },
        .rotation = 15,
        .zoom = 0.5,
    };
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginCamera(outer_camera));
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginCamera(inner_camera));
    hostedDrawEndCamera();
    try std.testing.expectEqual(@as(usize, 1), camera_scope_count);
    try std.testing.expectEqual(outer_camera.zoom, camera_scopes[0].zoom);
    hostedDrawEndCamera();

    const outer_scissor = abi.DrawHostBegin_scissorArgs{ .x = 10, .y = 20, .width = 300, .height = 200 };
    const inner_scissor = abi.DrawHostBegin_scissorArgs{ .x = 30, .y = 40, .width = 50, .height = 60 };
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginScissorRaw(outer_scissor));
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginScissorRaw(inner_scissor));
    hostedDrawEndScissorRaw();
    try std.testing.expectEqual(@as(usize, 1), scissor_scope_count);
    try std.testing.expectEqual(outer_scissor.width, scissor_scopes[0].width);
    hostedDrawEndScissorRaw();

    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginBlendRaw(.{ .arg0 = 2 }));
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginBlendRaw(.{ .arg0 = 1 }));
    hostedDrawEndBlendRaw();
    try std.testing.expectEqual(@as(usize, 1), blend_scope_count);
    try std.testing.expectEqual(@as(u8, 2), blend_scopes[0]);
    hostedDrawEndBlendRaw();

    for (0..SCOPE_STACK_LIMIT) |_| try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginBlendRaw(.{ .arg0 = 0 }));
    try std.testing.expectEqual(SCOPE_LIMIT, hostedDrawBeginBlendRaw(.{ .arg0 = 0 }));
    for (0..SCOPE_STACK_LIMIT) |_| hostedDrawEndBlendRaw();
    try std.testing.expectEqual(@as(usize, 0), blend_scope_count);

    for (0..SCOPE_STACK_LIMIT) |_| try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginCamera(outer_camera));
    try std.testing.expectEqual(SCOPE_LIMIT, hostedDrawBeginCamera(inner_camera));
    for (0..SCOPE_STACK_LIMIT) |_| hostedDrawEndCamera();
    try std.testing.expectEqual(@as(usize, 0), camera_scope_count);

    for (0..SCOPE_STACK_LIMIT) |_| try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginScissorRaw(outer_scissor));
    try std.testing.expectEqual(SCOPE_LIMIT, hostedDrawBeginScissorRaw(inner_scissor));
    for (0..SCOPE_STACK_LIMIT) |_| hostedDrawEndScissorRaw();
    try std.testing.expectEqual(@as(usize, 0), scissor_scope_count);
}

test "resource scopes report bounded saturation without leaking transferred owners" {
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

    const target = storeRenderTexture(.headless, 16, 16).?;
    abi.increfBox(@ptrCast(target), SCOPE_STACK_LIMIT);
    for (0..SCOPE_STACK_LIMIT) |_| try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginRenderTextureRaw(.{ .resource = target }));
    try std.testing.expectEqual(SCOPE_LIMIT, hostedDrawBeginRenderTextureRaw(.{ .resource = target }));
    for (0..SCOPE_STACK_LIMIT) |_| hostedDrawEndRenderTextureRaw();
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());

    const shader = storeShader(.headless).?;
    abi.increfBox(@ptrCast(shader), SCOPE_STACK_LIMIT);
    for (0..SCOPE_STACK_LIMIT) |_| try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginShaderRaw(.{ .arg0 = shader }));
    try std.testing.expectEqual(SCOPE_LIMIT, hostedDrawBeginShaderRaw(.{ .arg0 = shader }));
    for (0..SCOPE_STACK_LIMIT) |_| hostedDrawEndShaderRaw();
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
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
    try std.testing.expectEqual(SCOPE_UNAVAILABLE, hostedDrawBeginRenderTextureRaw(.{ .resource = @ptrCast(shader) }));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    const target = storeRenderTexture(.headless, 16, 16).?;
    try std.testing.expectEqual(SCOPE_UNAVAILABLE, hostedDrawBeginShaderRaw(.{ .arg0 = @ptrCast(target) }));
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

fn headlessTilemapRequest(
    host: *RocHost,
    texture: *abi.AssetsHostTextureResource,
    selector_kind: u8,
    selector_value: u64,
    culled: bool,
) abi.TilemapHostDrawArgs {
    const gids = [_]u64{
        1,
        TILED_FLIP_HORIZONTAL | 1,
        0,
        2,
        0,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
    };
    const layers = [_]abi.TilemapHostDrawArg0Layers{
        .{ .gid_count = 6, .gid_start = 0, .height = 2, .width = 3, .role = 0, .visible = true },
        .{ .gid_count = 6, .gid_start = 6, .height = 2, .width = 3, .role = TILEMAP_ROLE_HIDDEN, .visible = true },
    };
    const tilesets = [_]abi.TilemapHostDrawArg0Tilesets{
        .{
            .columns = 2,
            .first_gid = 1,
            .texture = .{ .resource = texture },
            .tile_height = 8,
            .tile_width = 8,
        },
    };
    return .{
        .culled = culled,
        .gids = abi.RocListWith(u64, false).fromSlice(&gids, host),
        .layers = abi.RocListWith(abi.TilemapHostDrawArg0Layers, false).fromSlice(&layers, host),
        .tilesets = abi.RocList(abi.TilemapHostDrawArg0Tilesets).fromSlice(&tilesets, host),
        .map_tile_height = 16,
        .map_tile_width = 16,
        .max_col = 1,
        .max_row = 0,
        .min_col = 0,
        .min_row = 0,
        .origin_x = 10,
        .origin_y = 20,
        .selector_kind = selector_kind,
        .selector_value = selector_value,
    };
}

test "one tilemap host call draws a culled batch and releases texture owners" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    headless_tilemap_draw_calls = 0;
    headless_tilemap_tiles = 0;
    headless_tilemap_last_quad = null;
    defer {
        active_headless = false;
        active_roc_host = null;
    }

    const texture = storeTexture(.{ .headless = .{ .width = 16, .height = 8 } }, 16, 8).?;
    hostedTilemapDrawRaw(&roc_host, headlessTilemapRequest(&roc_host, texture, TILEMAP_SELECTOR_ALL, 0, true));

    try std.testing.expectEqual(@as(usize, 1), headless_tilemap_draw_calls);
    try std.testing.expectEqual(@as(usize, 2), headless_tilemap_tiles);
    const quad = headless_tilemap_last_quad.?;
    try std.testing.expectEqual(TILED_FLIP_HORIZONTAL | 1, quad.raw_gid);
    try std.testing.expectEqual(@as(f32, 42), quad.top_left.x);
    try std.testing.expectEqual(@as(f32, 26), quad.top_right.x);
    try std.testing.expectEqual(@as(f32, 20), quad.top_left.y);
    try std.testing.expectEqual(@as(f32, 36), quad.bottom_left.y);
    try std.testing.expectEqual(@as(f32, 0), quad.source.x);
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());
}

test "role batching cannot select hidden layers but named selection can" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        active_headless = false;
        active_roc_host = null;
    }

    headless_tilemap_tiles = 0;
    const rejected_texture = storeTexture(.{ .headless = .{ .width = 16, .height = 8 } }, 16, 8).?;
    hostedTilemapDrawRaw(&roc_host, headlessTilemapRequest(&roc_host, rejected_texture, TILEMAP_SELECTOR_ROLE, TILEMAP_ROLE_HIDDEN, false));
    try std.testing.expectEqual(@as(usize, 0), headless_tilemap_tiles);

    const named_texture = storeTexture(.{ .headless = .{ .width = 16, .height = 8 } }, 16, 8).?;
    hostedTilemapDrawRaw(&roc_host, headlessTilemapRequest(&roc_host, named_texture, TILEMAP_SELECTOR_LAYER, 1, false));
    try std.testing.expectEqual(@as(usize, 6), headless_tilemap_tiles);
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());
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
        .pixels = abi.RocListWith(Color, false).empty(),
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

    var prepared_texts: [256]*u64 = undefined;
    for (&prepared_texts) |*prepared| {
        const result = hostedDrawPrepareTextRaw(&roc_host, .{
            .font = .{ .payload = undefined, .tag = .DefaultFont },
            .text = abi.RocStr.empty(),
            .size = 16,
            .spacing = 1,
        });
        try std.testing.expectEqual(RESOURCE_ERR_NONE, result.err);
        prepared.* = result.prepared;
    }
    try std.testing.expectEqual(RESOURCE_ERR_LIMIT, hostedDrawPrepareTextRaw(&roc_host, .{
        .font = .{ .payload = undefined, .tag = .DefaultFont },
        .text = abi.RocStr.empty(),
        .size = 16,
        .spacing = 1,
    }).err);
    for (prepared_texts) |prepared| releaseResourceBox(&roc_host, prepared);

    try std.testing.expectEqual(@as(usize, 0), sound_heap.active());
    try std.testing.expectEqual(@as(usize, 0), music_heap.active());
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    try std.testing.expectEqual(@as(usize, 0), prepared_text_heap.active());
}

fn storeFont(resource: FontResource) ?*u64 {
    return font_heap.insert(0, resource) orelse {
        var rejected = resource;
        destroyFont(&rejected);
        return null;
    };
}

fn storePreparedText(resource: PreparedTextResource) ?*u64 {
    return prepared_text_heap.insert(0, resource) orelse {
        var rejected = resource;
        destroyPreparedText(&rejected);
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
    if (headlessMode()) {
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
    if (headlessMode()) {
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
        .native => |texture| if (!builtin.is_test) raylib.updateTexture(texture, args.pixels.items()),
    }
    return TEXTURE_UPDATE_OK;
}

fn exportedAssetsUpdateTextureRaw(args: abi.AssetsHostUpdate_textureArgs) callconv(.c) u8 {
    return hostedAssetsUpdateTextureRaw(activeHost(), args);
}

fn hostedAssetsSetTextureFilterRaw(texture_owner: abi.AssetsHostTexture, code: u8) callconv(.c) void {
    defer texture_owner.decref(activeHost());
    if (builtin.is_test) return;
    const texture = nativeTextureForToken(texture_owner.resource.handle) orelse return;
    raylib.setTextureFilter(texture, code);
}

fn hostedAssetsSetTextureWrapRaw(texture_owner: abi.AssetsHostTexture, code: u8) callconv(.c) void {
    defer texture_owner.decref(activeHost());
    if (builtin.is_test) return;
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
    if (headlessMode()) {
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
    if (headlessMode()) {
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
    if (headlessMode()) {
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

fn hostedDrawBeginRenderTextureRaw(args: abi.DrawHostBegin_render_textureArgs) callconv(.c) u8 {
    const host = activeHost();
    const owner = args.resource;
    if (render_texture_lease_count == SCOPE_STACK_LIMIT) {
        releaseResourceBox(host, owner);
        return SCOPE_LIMIT;
    }
    const resource = render_texture_heap.get(owner.handle) orelse {
        releaseResourceBox(host, owner);
        return SCOPE_UNAVAILABLE;
    };
    switch (resource.*) {
        .headless => headless_render_texture_depth +|= 1,
        .native => |target| if (!builtin.is_test) raylib.beginTextureMode(target),
    }
    render_texture_leases[render_texture_lease_count] = owner;
    render_texture_lease_count += 1;
    return SCOPE_OK;
}

fn hostedDrawEndRenderTextureRaw() callconv(.c) void {
    if (render_texture_lease_count == 0) return;
    if (headlessMode()) headless_render_texture_depth -|= 1 else raylib.endTextureMode();
    render_texture_lease_count -= 1;
    const owner = render_texture_leases[render_texture_lease_count].?;
    render_texture_leases[render_texture_lease_count] = null;
    if (!headlessMode() and render_texture_lease_count > 0) {
        const outer = render_texture_leases[render_texture_lease_count - 1].?;
        if (render_texture_heap.get(outer.handle)) |resource| raylib.beginTextureMode(resource.native);
    }
    releaseResourceBox(activeHost(), owner);
}

fn hostedDrawBeginShaderRaw(args: abi.DrawHostBegin_shaderArgs) callconv(.c) u8 {
    const host = activeHost();
    const owner = args.arg0;
    if (shader_lease_count == SCOPE_STACK_LIMIT) {
        releaseResourceBox(host, owner);
        return SCOPE_LIMIT;
    }
    const resource = shader_heap.get(owner.*) orelse {
        releaseResourceBox(host, owner);
        return SCOPE_UNAVAILABLE;
    };
    switch (resource.*) {
        .headless => headless_shader_depth +|= 1,
        .native => |shader| if (!builtin.is_test) raylib.beginShaderMode(shader),
    }
    shader_leases[shader_lease_count] = owner;
    shader_lease_count += 1;
    return SCOPE_OK;
}

fn hostedDrawEndShaderRaw() callconv(.c) void {
    if (shader_lease_count == 0) return;
    if (headlessMode()) headless_shader_depth -|= 1 else raylib.endShaderMode();
    shader_lease_count -= 1;
    const owner = shader_leases[shader_lease_count].?;
    shader_leases[shader_lease_count] = null;
    if (!headlessMode() and shader_lease_count > 0) {
        const outer = shader_leases[shader_lease_count - 1].?;
        if (shader_heap.get(outer.*)) |resource| raylib.beginShaderMode(resource.native);
    }
    releaseResourceBox(activeHost(), owner);
}

fn hostedDrawBeginBlendRaw(args: abi.DrawHostBegin_blendArgs) callconv(.c) u8 {
    if (blend_scope_count == SCOPE_STACK_LIMIT) return SCOPE_LIMIT;
    if (args.arg0 > 5) return SCOPE_UNAVAILABLE;
    if (!headlessMode()) raylib.beginBlendMode(args.arg0);
    blend_scopes[blend_scope_count] = args.arg0;
    blend_scope_count += 1;
    return SCOPE_OK;
}

fn hostedDrawEndBlendRaw() callconv(.c) void {
    if (blend_scope_count == 0) return;
    if (!headlessMode()) raylib.endBlendMode();
    blend_scope_count -= 1;
    if (!headlessMode() and blend_scope_count > 0) raylib.beginBlendMode(blend_scopes[blend_scope_count - 1]);
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
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderFloat(resource.native, args.uniform.location, args.value);
}

fn hostedDrawSetShaderIntRaw(args: abi.DrawHostSet_shader_intArgs) callconv(.c) void {
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderInt(resource.native, args.uniform.location, args.value);
}

fn hostedDrawSetShaderVec2Raw(args: abi.DrawHostSet_shader_vec2Args) callconv(.c) void {
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderVec2(resource.native, args.uniform.location, .{ args.value.x, args.value.y });
}

fn hostedDrawSetShaderVec3Raw(args: abi.DrawHostSet_shader_vec3Args) callconv(.c) void {
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderVec3(resource.native, args.uniform.location, .{ args.value.x, args.value.y, args.value.z });
}

fn hostedDrawSetShaderVec4Raw(args: abi.DrawHostSet_shader_vec4Args) callconv(.c) void {
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderVec4(resource.native, args.uniform.location, .{ args.value.x, args.value.y, args.value.z, args.value.w });
}

fn hostedDrawSetShaderTextureRaw(args: abi.DrawHostSet_shader_textureArgs) callconv(.c) void {
    defer args.uniform.decref(activeHost());
    defer args.texture.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    const texture = nativeTextureForToken(args.texture.resource.handle) orelse return;
    raylib.setShaderTexture(resource.native, args.uniform.location, texture);
}

/// Forward Roc scissor bounds to the raylib backend.
fn hostedDrawBeginScissorRaw(args: abi.DrawHostBegin_scissorArgs) callconv(.c) u8 {
    if (scissor_scope_count == SCOPE_STACK_LIMIT) return SCOPE_LIMIT;
    if (!headlessMode()) raylib.beginScissor(args.x, args.y, args.width, args.height);
    scissor_scopes[scissor_scope_count] = args;
    scissor_scope_count += 1;
    return SCOPE_OK;
}

/// End the scissor region opened by the Roc renderer.
fn hostedDrawEndScissorRaw() callconv(.c) void {
    if (scissor_scope_count == 0) return;
    if (!headlessMode()) raylib.endScissor();
    scissor_scope_count -= 1;
    if (!headlessMode() and scissor_scope_count > 0) {
        const outer = scissor_scopes[scissor_scope_count - 1];
        raylib.beginScissor(outer.x, outer.y, outer.width, outer.height);
    }
}

fn hostedDrawBeginCamera(args: abi.DrawHostBegin_cameraArgs) callconv(.c) u8 {
    if (camera_scope_count == SCOPE_STACK_LIMIT) return SCOPE_LIMIT;
    if (!headlessMode()) raylib.beginMode2D(args);
    camera_scopes[camera_scope_count] = args;
    camera_scope_count += 1;
    return SCOPE_OK;
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

fn hostedDrawClear(color: Color) callconv(.c) void {
    if (active_headless) return;
    raylib.clearBackground(color);
}

fn hostedDrawEndCamera() callconv(.c) void {
    if (camera_scope_count == 0) return;
    if (!headlessMode()) raylib.endMode2D();
    camera_scope_count -= 1;
    if (!headlessMode() and camera_scope_count > 0) raylib.beginMode2D(camera_scopes[camera_scope_count - 1]);
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
    if (headlessMode()) {
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
    if (headlessMode()) return headlessMeasureText(text_slice, args.size, args.spacing);

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

fn hostedDrawPrepareTextRaw(host: *RocHost, args: abi.DrawHostPrepare_textArgs) callconv(.c) abi.DrawHostPrepare_textRetRecord {
    defer args.text.decref(host);
    prepared_text_prepare_calls += 1;

    var font: ?raylib.Font = null;
    if (args.font.tag == .DefaultFont) {
        if (!headlessMode()) font = raylib.defaultFont();
    } else {
        const font_resource = font_heap.get(args.font.payload_loaded_font().*) orelse {
            args.font.decref(host);
            return .{ .prepared = invalidResourceHandle(), .height = 0, .width = 0, .err = RESOURCE_ERR_FAILED };
        };
        font = switch (font_resource.*) {
            .headless => null,
            .native => |loaded| loaded,
        };
    }

    const text_slice = args.text.asSlice();
    const text_len = std.mem.indexOfScalar(u8, text_slice, 0) orelse text_slice.len;
    const allocator = allocatorFromHost(host);
    const allocation = allocator.alloc(u8, text_len + 1) catch {
        args.font.decref(host);
        return .{ .prepared = invalidResourceHandle(), .height = 0, .width = 0, .err = RESOURCE_ERR_LIMIT };
    };
    @memcpy(allocation[0..text_len], text_slice[0..text_len]);
    allocation[text_len] = 0;
    const text = allocation[0..text_len :0];
    prepared_text_storage_allocations += 1;

    const measured = if (headlessMode())
        headlessMeasureText(text, args.size, args.spacing)
    else blk: {
        const size = raylib.measureTextZ(text.ptr, font.?, args.size, args.spacing);
        break :blk abi.DrawHostMeasure_textRetRecord{ .height = size.y, .width = size.x };
    };

    const font_owner = if (args.font.tag == .LoadedFont) args.font.payload_loaded_font() else null;
    const prepared = storePreparedText(.{
        .allocator = allocator,
        .text = text,
        .font = font,
        .font_owner = font_owner,
        .size = args.size,
        .spacing = args.spacing,
    }) orelse return .{ .prepared = invalidResourceHandle(), .height = 0, .width = 0, .err = RESOURCE_ERR_LIMIT };

    return .{ .prepared = prepared, .height = measured.height, .width = measured.width, .err = RESOURCE_ERR_NONE };
}

fn exportedDrawPrepareTextRaw(args: abi.DrawHostPrepare_textArgs) callconv(.c) abi.DrawHostPrepare_textRetRecord {
    return hostedDrawPrepareTextRaw(activeHost(), args);
}

fn hostedDrawPreparedTextRaw(host: *RocHost, args: abi.DrawHostDraw_prepared_textArgs) callconv(.c) void {
    defer releaseResourceBox(host, args.prepared);
    const resource = prepared_text_heap.get(args.prepared.*) orelse return;
    prepared_text_draw_calls += 1;
    if (headlessMode()) return;

    raylib.drawTextZ(
        resource.text.ptr,
        resource.font.?,
        .{ .x = args.pos.x, .y = args.pos.y },
        resource.size,
        resource.spacing,
        args.color,
    );
}

fn exportedDrawPreparedTextRaw(args: abi.DrawHostDraw_prepared_textArgs) callconv(.c) void {
    hostedDrawPreparedTextRaw(activeHost(), args);
}

fn hostedDrawTextRaw(host: *RocHost, args: abi.DrawHostTextArgs) callconv(.c) void {
    defer args.text.decref(host);
    defer args.font.decref(host);
    if (headlessMode()) return;

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
    if (headlessMode()) return;
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
    const bytes = std.Io.Dir.cwd().readFileAlloc(mainThreadIo(), path, allocator, .limited(MAX_HOST_TEXT_FILE_BYTES)) catch |err| {
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
    var map = tmx_loader.load(allocatorFromHost(roc_host), mainThreadIo(), path) catch |err| {
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

const TILEMAP_SELECTOR_LAYER = tilemap_batch.selector_layer;
const TILEMAP_SELECTOR_ROLE = tilemap_batch.selector_role;
const TILEMAP_SELECTOR_ALL = tilemap_batch.selector_all;
const TILEMAP_ROLE_HIDDEN = tilemap_batch.role_hidden;
const TILED_FLIP_HORIZONTAL = tilemap_batch.flip_horizontal;

fn releaseTilemapDrawArgs(host: *RocHost, args: abi.TilemapHostDrawArgs) void {
    args.gids.decref(host);
    args.layers.decref(host);
    if (args.tilesets.hasOneRef()) {
        for (args.tilesets.allocationItems()) |tileset| tileset.decref(host);
    }
    args.tilesets.decref(host);
}

fn tilemapTextureToken(tileset: abi.TilemapHostDrawArg0Tilesets) u64 {
    return tileset.texture.resource.handle;
}

fn submitTilemapQuad(_: void, quad: TilemapQuadProbe) bool {
    if (headlessMode()) {
        if (texture_heap.get(quad.texture_token) == null) return false;
        headless_tilemap_last_quad = quad;
        return true;
    }
    const texture = nativeTextureForToken(quad.texture_token) orelse return false;
    raylib.drawTextureQuad(texture, .{
        .source = quad.source,
        .top_left = quad.top_left,
        .bottom_left = quad.bottom_left,
        .bottom_right = quad.bottom_right,
        .top_right = quad.top_right,
        .q_top_left = 1,
        .q_bottom_left = 1,
        .q_bottom_right = 1,
        .q_top_right = 1,
        .tint = Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
    });
    return true;
}

fn hostedTilemapDrawRaw(host: *RocHost, args: abi.TilemapHostDrawArgs) callconv(.c) void {
    defer releaseTilemapDrawArgs(host, args);
    if (headlessMode()) headless_tilemap_draw_calls += 1;
    const submitted = tilemap_batch.draw(.{
        .culled = args.culled,
        .gids = args.gids.items(),
        .layers = args.layers.items(),
        .tilesets = args.tilesets.items(),
        .map_tile_height = args.map_tile_height,
        .map_tile_width = args.map_tile_width,
        .max_col = args.max_col,
        .max_row = args.max_row,
        .min_col = args.min_col,
        .min_row = args.min_row,
        .origin_x = args.origin_x,
        .origin_y = args.origin_y,
        .selector_kind = args.selector_kind,
        .selector_value = args.selector_value,
    }, {}, submitTilemapQuad, tilemapTextureToken);
    if (headlessMode()) headless_tilemap_tiles += submitted;
}

fn exportedTilemapDrawRaw(args: abi.TilemapHostDrawArgs) callconv(.c) void {
    hostedTilemapDrawRaw(activeHost(), args);
}

fn hostedExit(code: i32) callconv(.c) void {
    exit_requested = @as(i64, code);
}

fn hostedSetScreenSize(args: abi.HostHostSet_screen_sizeArgs) callconv(.c) u8 {
    if (active_headless) {
        headless_screen_width = positiveI32(args.width, headless_screen_width);
        headless_screen_height = positiveI32(args.height, headless_screen_height);
    } else {
        raylib.setWindowSize(args.width, args.height);
    }
    return TRY_TAG_OK;
}

fn hostedSetTargetFps(fps: i32) callconv(.c) void {
    if (active_headless) return;
    raylib.setTargetFps(fps);
}

fn hostedSetWindowMinSize(args: abi.HostHostSet_window_min_sizeArgs) callconv(.c) void {
    if (active_headless) return;
    raylib.setWindowMinSize(nonNegativeCInt(args.width), nonNegativeCInt(args.height));
}

fn hostedSetExitKey(key_code: i32) callconv(.c) void {
    if (active_headless) return;
    raylib.setExitKey(nonNegativeCInt(key_code));
}

/// Copy a path into fixed host storage, returning false if it does not fit.
///
/// Capture paths outlive the Roc string they arrive in, so they cannot be
/// borrowed. `capture.validateRelativePath` has already bounded the length.
fn storeCapturePath(destination: []u8, length: *usize, path: []const u8) bool {
    if (path.len > destination.len) return false;
    @memcpy(destination[0..path.len], path);
    length.* = path.len;
    return true;
}

fn captureOutputDir() []const u8 {
    return capture_output_dir[0..capture_output_dir_len];
}

/// Resolve a validated request path under the output directory and create its
/// parent directories, so an app can record into `frames/run/` without first
/// having to make the directory itself.
fn prepareCapturePath(buffer: []u8, path: []const u8) ?[]const u8 {
    const joined = capture.joinOutputPath(buffer, captureOutputDir(), path) orelse return null;
    if (std.fs.path.dirname(joined)) |parent| {
        std.Io.Dir.cwd().createDirPath(mainThreadIo(), parent) catch return null;
    }
    return joined;
}

/// Write one captured image to a validated path, returning a capture error code.
///
/// `bytes_out`, when given, receives the size of the file that was written --
/// the encoded size, not the pixel count, since that is what `Capture.stop!`
/// reports as the recording's size on disk.
fn writeCaptureImage(image: raylib.CaptureImage, path: []const u8, bytes_out: ?*u64) u8 {
    var path_storage: [capture.path_capacity]u8 = undefined;
    const resolved = prepareCapturePath(&path_storage, path) orelse return capture.err_write_failed;

    var c_stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    const allocator = allocatorFromHost(activeHost());
    var c_path = makeTempCString(allocator, &c_stack, resolved) catch return capture.err_out_of_memory;
    defer c_path.deinit();

    if (!image.exportPng(c_path.ptr)) return capture.err_write_failed;

    if (bytes_out) |out| {
        const stat = std.Io.Dir.cwd().statFile(mainThreadIo(), resolved, .{}) catch {
            // The file is written; only its size is unknown.
            return capture.err_none;
        };
        out.* = stat.size;
    }
    return capture.err_none;
}

/// Build the numbered filename for one frame of a PNG-sequence recording.
///
/// `demo.png` yields `demo_00000.png`, keeping frames in lexicographic order
/// so any external encoder picks them up in the right sequence.
fn framePathForIndex(buffer: []u8, path: []const u8, index: u64) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.');
    const stem = if (dot) |at| path[0..at] else path;
    const extension = if (dot) |at| path[at..] else ".png";
    return std.fmt.bufPrint(buffer, "{s}_{d:0>5}{s}", .{ stem, index, extension }) catch null;
}

fn hostedCaptureScreenshot(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) u8 {
    defer path_arg.decref(roc_host);
    const path = path_arg.asSlice();

    const validation = capture.validateRelativePath(path);
    if (validation != capture.err_none) return validation;

    // Headless runs have no framebuffer to read, so the request is validated
    // and then dropped rather than writing a file that would be all zeroes.
    if (headlessMode()) return capture.err_none;

    // A request already queued this frame has not been serviced yet, and there
    // is only one slot. Refuse rather than silently discarding the first path.
    if (capture_screenshot_pending) return capture.err_already_recording;

    if (!storeCapturePath(&capture_screenshot_path, &capture_screenshot_path_len, path)) {
        return capture.err_path_invalid;
    }
    capture_screenshot_pending = true;

    // The write happens at the end of this frame, so the only failure this call
    // can report is the previous screenshot's. Reporting it late beats losing
    // it: the alternative is a write that fails with no signal anywhere.
    const previous = capture_screenshot_result;
    capture_screenshot_result = capture.err_none;
    return previous;
}

fn exportedCaptureScreenshot(path_arg: abi.RocStr) callconv(.c) u8 {
    return hostedCaptureScreenshot(activeHost(), path_arg);
}

fn hostedCaptureStartRecording(roc_host: *RocHost, args: abi.CaptureHostStart_recordingArgs) callconv(.c) u8 {
    defer args.path.decref(roc_host);
    return startCaptureRecording(.{
        .path = args.path.asSlice(),
        .format = args.format,
        .fps = args.fps,
        .max_frames = args.max_frames,
        .scale_numerator = args.scale_numerator,
        .scale_denominator = args.scale_denominator,
        .every_nth = args.every_nth,
        .timing = args.timing,
        .cursor = args.cursor,
        .quality = args.quality,
    });
}

fn exportedCaptureStartRecording(args: abi.CaptureHostStart_recordingArgs) callconv(.c) u8 {
    return hostedCaptureStartRecording(activeHost(), args);
}

/// Validate a recording request and arm the session.
///
/// Shared by the runtime effect and the startup config so a recording declared
/// in `App.Config` is checked exactly as strictly as one started from `render!`.
fn startCaptureRecording(request: capture.Request) u8 {
    // A recording that failed mid-run leaves its session latched and its sink
    // open, and retrying after observing `Failed` is the natural thing for an
    // app to do. Finalize the wreckage first: without this the old encoder's
    // file handle leaks, its partial file never gets a trailer, and starting a
    // different format would leave two sinks open with only the first ever
    // closed. An *active* recording is still refused by `Session.start`.
    if (capture_session.status == capture.status_failed) {
        _ = capture_session.stop();
        _ = closeCaptureSink(true);
    }

    const width: u32 = @intCast(@max(currentRenderWidth(), 1));
    const height: u32 = @intCast(@max(currentRenderHeight(), 1));

    const result = capture_session.start(request, width, height);
    if (result != capture.err_none) return result;

    // A new recording gets a fresh attempt at the GPU path: the previous
    // failure may have been about sizes this one does not ask for.
    capture_downscale_unavailable = false;

    if (!storeCapturePath(&capture_recording_path, &capture_recording_path_len, request.path)) {
        _ = capture_session.stop();
        return capture.err_path_invalid;
    }
    capture_recording_bytes = 0;

    // A format that writes one container for the whole recording opens it now,
    // so a bad path or an unwritable directory is reported by `start!` rather
    // than surfacing frames later as a latched failure.
    if (!headlessMode()) {
        const opened = switch (capture_session.format) {
            capture.format_gif => openCaptureGif(),
            capture.format_webm => openCaptureWebm(),
            else => capture.err_none,
        };
        if (opened != capture.err_none) {
            _ = capture_session.stop();
            return opened;
        }
    }
    return capture.err_none;
}

/// Open the GIF container for the active recording.
fn openCaptureGif() u8 {
    var path_storage: [capture.path_capacity]u8 = undefined;
    const resolved = prepareCapturePath(
        &path_storage,
        capture_recording_path[0..capture_recording_path_len],
    ) orelse return capture.err_write_failed;

    gif_encoder.open(
        mainThreadIo(),
        &capture_gif,
        resolved,
        capture_session.width,
        capture_session.height,
        capture_session.fps,
        capture_session.quality,
    ) catch |err| return captureErrorCode(err);

    capture_gif_open = true;
    return capture.err_none;
}

/// Open the WebM container and VP8 encoder for the active recording.
fn openCaptureWebm() u8 {
    var path_storage: [capture.path_capacity]u8 = undefined;
    const resolved = prepareCapturePath(
        &path_storage,
        capture_recording_path[0..capture_recording_path_len],
    ) orelse return capture.err_write_failed;

    capture_vp8.open(
        mainThreadIo(),
        &capture_webm,
        resolved,
        capture_session.width,
        capture_session.height,
        capture_session.fps,
    ) catch |err| return vp8ErrorCode(err);

    capture_webm_open = true;
    return capture.err_none;
}

/// Map a VP8 encoder error onto the code Roc observes.
fn vp8ErrorCode(err: capture_vp8.Error) u8 {
    return switch (err) {
        capture_vp8.Error.WriteFailed => capture.err_write_failed,
        capture_vp8.Error.OutOfMemory => capture.err_out_of_memory,
        capture_vp8.Error.EncodeFailed => capture.err_encode_failed,
        // The previous encoder was never closed, so from the app's side a
        // recording is still in progress.
        capture_vp8.Error.AlreadyOpen => capture.err_already_recording,
    };
}

/// Map an encoder error onto the code Roc observes.
fn captureErrorCode(err: gif_encoder.Error) u8 {
    return switch (err) {
        gif_encoder.Error.WriteFailed => capture.err_write_failed,
        gif_encoder.Error.OutOfMemory => capture.err_out_of_memory,
        gif_encoder.Error.EncodeFailed => capture.err_encode_failed,
    };
}

/// Close the active recording's container, if it has one.
///
/// `finished` finalizes the file; otherwise it is abandoned mid-stream, which
/// still leaves the frames written so far readable by most decoders.
/// Close every open sink, reporting the first failure.
///
/// Both are checked rather than returning after the first: only one should ever
/// be open, but if that invariant were ever broken the other would otherwise be
/// left holding an unfinalized file and a live descriptor.
///
/// This is also where the GPU downscale targets go. Every way a recording can
/// end -- `Capture.stop!`, the frame cap, a failed session being restarted, and
/// shutdown -- funnels through here, and shutdown reaches it while the window
/// is still open, which releasing GPU memory requires.
fn closeCaptureSink(finished: bool) u8 {
    var result = capture.err_none;

    releaseCaptureDownscaler();

    if (capture_gif_open) {
        capture_gif_open = false;
        if (finished) {
            capture_gif.finish() catch |err| {
                result = captureErrorCode(err);
            };
            capture_recording_bytes = capture_gif.bytesWritten();
        } else {
            capture_gif.abort();
        }
    }

    if (capture_webm_open) {
        capture_webm_open = false;
        if (finished) {
            capture_webm.finish() catch |err| {
                if (result == capture.err_none) result = vp8ErrorCode(err);
            };
            capture_recording_bytes = capture_webm.bytesWritten();
        } else {
            capture_webm.abort();
        }
    }

    return result;
}

fn currentRenderWidth() i32 {
    if (headlessMode()) return headless_screen_width;
    return @intCast(raylib.getRenderWidth());
}

fn currentRenderHeight() i32 {
    if (headlessMode()) return headless_screen_height;
    return @intCast(raylib.getRenderHeight());
}

fn hostedCaptureSetVirtualMouse(args: abi.CaptureHostSet_virtual_mouseArgs) callconv(.c) void {
    if (!args.active) {
        virtual_mouse_active = false;
        virtual_mouse_has_last = false;
        virtual_mouse_buttons = @splat(false);
        virtual_mouse_wheel = 0;
        return;
    }

    virtual_mouse_active = true;
    virtual_mouse_x = args.x;
    virtual_mouse_y = args.y;
    virtual_mouse_wheel = args.wheel;
    // Indices follow raylib's mouse button codes, which `Mouse` also uses.
    virtual_mouse_buttons[0] = args.left;
    virtual_mouse_buttons[1] = args.right;
    virtual_mouse_buttons[2] = args.middle;
}

/// Movement since the previous virtual position, zero on the first frame.
fn virtualMouseDelta() raylib.Vec2 {
    if (!virtual_mouse_has_last) return .{ .x = 0, .y = 0 };
    return .{
        .x = virtual_mouse_x - virtual_mouse_last_x,
        .y = virtual_mouse_y - virtual_mouse_last_y,
    };
}

/// Remember this frame's virtual position for the next frame's delta.
fn recordVirtualMousePosition() void {
    virtual_mouse_last_x = virtual_mouse_x;
    virtual_mouse_last_y = virtual_mouse_y;
    virtual_mouse_has_last = true;
}

fn hostedCaptureStopRecording() callconv(.c) abi.CaptureHostStop_recordingRetRecord {
    const frames = capture_session.captured_frames;
    const stop_result = capture_session.stop();
    if (stop_result == capture.err_not_recording) {
        return .{ .err = stop_result, .frames = frames, .bytes = capture_recording_bytes };
    }

    // Finalize even when the session already failed: the frames captured
    // before the failure are still worth a readable file.
    const close_result = closeCaptureSink(true);
    const err = if (stop_result != capture.err_none) stop_result else close_result;
    return .{ .err = err, .frames = frames, .bytes = capture_recording_bytes };
}

fn hostedCaptureRecordingStatus() callconv(.c) abi.CaptureHostRecording_statusRetRecord {
    return .{
        .status = capture_session.status,
        .err = capture_session.failure,
        .frames = capture_session.captured_frames,
        .dropped = capture_session.dropped_frames,
    };
}

fn hostedGetClipboardText(roc_host: *RocHost) callconv(.c) ClipboardTextResult {
    var result: ClipboardTextResult = undefined;

    if (headlessMode()) {
        if (!headless_clipboard_set) {
            result.tag = .Err;
            return result;
        }
        result.payload = .{ .ok = abi.RocStr.fromSlice(headless_clipboard[0..headless_clipboard_len], roc_host) };
        result.tag = .Ok;
        return result;
    }

    // The pointer belongs to the windowing backend: it is null when the
    // clipboard is empty or holds non-text content, must never be freed, and is
    // invalidated by the next clipboard call -- so copy it into a Roc Str now.
    const text = raylib.getClipboardText() orelse {
        result.tag = .Err;
        return result;
    };
    result.payload = .{ .ok = abi.RocStr.fromSlice(std.mem.span(text), roc_host) };
    result.tag = .Ok;
    return result;
}

fn exportedGetClipboardText() callconv(.c) ClipboardTextResult {
    return hostedGetClipboardText(activeHost());
}

fn hostedSetClipboardText(roc_host: *RocHost, text_arg: abi.RocStr) callconv(.c) void {
    // Roc transfers ownership of refcounted args to the hosted fn; release it
    // on every path, including the early returns below.
    defer text_arg.decref(roc_host);

    const text_slice = text_arg.asSlice();

    if (headlessMode()) {
        if (text_slice.len > headless_clipboard.len) return;
        @memcpy(headless_clipboard[0..text_slice.len], text_slice);
        headless_clipboard_len = text_slice.len;
        headless_clipboard_set = true;
        return;
    }

    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var text = makeTempCString(allocatorFromHost(roc_host), &stack, text_slice) catch return;
    defer text.deinit();
    raylib.setClipboardText(text.ptr);
}

fn exportedSetClipboardText(text_arg: abi.RocStr) callconv(.c) void {
    hostedSetClipboardText(activeHost(), text_arg);
}

const CursorMode = enum {
    visible,
    hidden,
    locked,
};

fn cursorModeFromCode(code: u8) CursorMode {
    return switch (code) {
        1 => .hidden,
        2 => .locked,
        else => .visible,
    };
}

fn hostedMouseSetCursorModeRaw(mode_code: u8) callconv(.c) void {
    if (active_headless) return;
    switch (cursorModeFromCode(mode_code)) {
        .visible => raylib.enableCursor(),
        .hidden => {
            raylib.enableCursor();
            raylib.hideCursor();
        },
        .locked => raylib.disableCursor(),
    }
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

test "cursor mode codes map invalid values to visible" {
    try std.testing.expectEqual(CursorMode.visible, cursorModeFromCode(0));
    try std.testing.expectEqual(CursorMode.hidden, cursorModeFromCode(1));
    try std.testing.expectEqual(CursorMode.locked, cursorModeFromCode(2));
    try std.testing.expectEqual(CursorMode.visible, cursorModeFromCode(255));
}

test "window minimums and exit keys clamp negatives to the no-op zero" {
    // 0 is meaningful in both: GLFW_DONT_CARE for a minimum dimension, and
    // KEY_NULL for the exit key. Negatives must land on it rather than wrap.
    try std.testing.expectEqual(@as(c_int, 0), nonNegativeCInt(0));
    try std.testing.expectEqual(@as(c_int, 0), nonNegativeCInt(-1));
    try std.testing.expectEqual(@as(c_int, 0), nonNegativeCInt(std.math.minInt(i32)));
    try std.testing.expectEqual(@as(c_int, 256), nonNegativeCInt(256));
    try std.testing.expectEqual(@as(c_int, 640), nonNegativeCInt(640));
}

test "headless clipboard round-trips text and refuses oversized writes" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    defer {
        headless_clipboard_len = 0;
        headless_clipboard_set = false;
    }
    headless_clipboard_len = 0;
    headless_clipboard_set = false;

    // Nothing written yet, so a read reports the clipboard as unavailable
    // rather than handing back an empty string.
    try std.testing.expectEqual(ClipboardTextResultTag.Err, hostedGetClipboardText(&roc_host).tag);

    hostedSetClipboardText(&roc_host, abi.RocStr.fromSlice("copied", &roc_host));
    const stored = hostedGetClipboardText(&roc_host);
    defer stored.decref(&roc_host);
    try std.testing.expectEqual(ClipboardTextResultTag.Ok, stored.tag);
    try std.testing.expectEqualStrings("copied", stored.payload.ok.asSlice());

    // A write that cannot fit leaves the previous contents intact, and still
    // releases the Roc string it was handed.
    const oversized = abi.RocStr.fromSlice(&([_]u8{'x'} ** (HEADLESS_CLIPBOARD_CAPACITY + 1)), &roc_host);
    hostedSetClipboardText(&roc_host, oversized);
    const unchanged = hostedGetClipboardText(&roc_host);
    defer unchanged.decref(&roc_host);
    try std.testing.expectEqualStrings("copied", unchanged.payload.ok.asSlice());
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
    if (headlessMode()) {
        const sound = storeSound(.headless) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .sound = sound, .err = RESOURCE_ERR_NONE };
    }
    const sound = raylib.genTone(args.freq, args.ms) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeSound(.{ .native = sound }) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .sound = stored, .err = RESOURCE_ERR_NONE };
}

fn hostedAudioGenSound(args: abi.AudioHostGen_soundArgs) callconv(.c) abi.AudioHostGen_soundRetRecord {
    if (headlessMode()) {
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
    if (headlessMode()) {
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
    if (builtin.is_test) return;
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
    if (builtin.is_test) return 0;
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
    std.debug.assert(blend_scope_count == 0);
    std.debug.assert(camera_scope_count == 0);
    std.debug.assert(scissor_scope_count == 0);
    std.debug.assert(texture_heap.active() == 0);
    std.debug.assert(render_texture_heap.active() == 0);
    std.debug.assert(shader_heap.active() == 0);
    std.debug.assert(prepared_text_heap.active() == 0);
    std.debug.assert(font_heap.active() == 0);
    std.debug.assert(music_heap.active() == 0);
    std.debug.assert(sound_heap.active() == 0);
    shader_heap.deinitAll();
    prepared_text_heap.deinitAll();
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
        @export(&hostedDrawBeginRenderTextureRaw, .{ .name = "roc_draw_begin_render_texture_raw" });
        @export(&hostedDrawBeginScissorRaw, .{ .name = "roc_draw_begin_scissor_raw" });
        @export(&hostedDrawBeginShaderRaw, .{ .name = "roc_draw_begin_shader_raw" });
        @export(&hostedDrawCircleGradient, .{ .name = "roc_draw_circle_gradient" });
        @export(&hostedDrawCircleLinesRaw, .{ .name = "roc_draw_circle_lines_raw" });
        @export(&hostedDrawCircleRaw, .{ .name = "roc_draw_circle_raw" });
        @export(&hostedDrawClear, .{ .name = "roc_draw_clear" });
        @export(&exportedDrawPreparedTextRaw, .{ .name = "roc_draw_draw_prepared_text_raw" });
        @export(&hostedDrawTextureRaw, .{ .name = "roc_draw_draw_texture_raw" });
        @export(&hostedDrawTextureQuadRaw, .{ .name = "roc_draw_draw_texture_quad_raw" });
        @export(&hostedDrawEndCamera, .{ .name = "roc_draw_end_camera" });
        @export(&hostedDrawEndBlendRaw, .{ .name = "roc_draw_end_blend_raw" });
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
        @export(&exportedDrawPrepareTextRaw, .{ .name = "roc_draw_prepare_text_raw" });
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
        @export(&exportedGetClipboardText, .{ .name = "roc_host_get_clipboard_text" });
        @export(&hostedRandomI32, .{ .name = "roc_host_random_i32" });
        @export(if (builtin.os.tag == .windows) &exportedReadEnvWindows else &exportedReadEnvPosix, .{ .name = "roc_host_read_env" });
        @export(&exportedReadFileRaw, .{ .name = "roc_host_read_file_raw" });
        @export(&exportedSetClipboardText, .{ .name = "roc_host_set_clipboard_text" });
        @export(&hostedSetExitKey, .{ .name = "roc_host_set_exit_key" });
        @export(&exportedCaptureScreenshot, .{ .name = "roc_capture_screenshot" });
        @export(&exportedCaptureStartRecording, .{ .name = "roc_capture_start_recording" });
        @export(&hostedCaptureSetVirtualMouse, .{ .name = "roc_capture_set_virtual_mouse" });
        @export(&hostedCaptureStopRecording, .{ .name = "roc_capture_stop_recording" });
        @export(&hostedCaptureRecordingStatus, .{ .name = "roc_capture_recording_status" });
        @export(&hostedSetScreenSize, .{ .name = "roc_host_set_screen_size" });
        @export(&hostedSetTargetFps, .{ .name = "roc_host_set_target_fps" });
        @export(&hostedSetWindowMinSize, .{ .name = "roc_host_set_window_min_size" });
        @export(&hostedMouseSetCursorModeRaw, .{ .name = "roc_mouse_set_cursor_mode_raw" });
        @export(&hostedMouseSetCursorRaw, .{ .name = "roc_mouse_set_cursor_raw" });
        @export(&exportedTilemapDrawRaw, .{ .name = "roc_tilemap_draw_raw" });
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

        // A scripted pointer goes through the same edge detection as hardware,
        // so pressed/released this frame behave identically for the app.
        if (virtual_mouse_active) {
            raylib.updateMouseButtonStateFrom(&virtual_mouse_buttons);
        } else {
            raylib.updateMouseButtonState();
        }
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
/// `update_for_host` and `render_for_host` both consume their Box argument even
/// when they return `Err`, so clear the host slot before the call. Only an `Ok`
/// result installs a new owned model reference. `update!` may run several times
/// per frame, so this applies once per call rather than once per frame.
fn takeModel(boxed_model: *RocBox) RocBox {
    const transferred = boxed_model.*;
    boxed_model.* = null;
    return transferred;
}

/// Retained for the render call site, which reads more clearly with the old name.
const takeModelForRender = takeModel;


/// Advance the model by one cycle.
///
/// One call per rendered frame, so the model box moves exactly once no matter
/// how much happened. Consumes the step, which owns the input snapshot and the
/// completion list.
fn updateOnce(boxed_model: *RocBox, step: StepFromHost) UpdateResult {
    return update_for_host(takeModel(boxed_model), step);
}

/// Execute the commands returned by one `update!` call and release the list.
///
/// A read goes to the worker and is answered on a later step. If the worker is
/// absent or its slots are full the command is refused *immediately* with
/// `Unavailable` or `Busy` rather than run here: the point of the split is that
/// slow work never touches the frame thread, and an inline fallback puts back
/// exactly the stall the design exists to avoid.
///
/// Headless is the one deliberate exception. There is no frame to protect, and
/// CI compares every example's output across runs, so a completion landing on a
/// different step from run to run would make that flaky. The read runs
/// immediately and is still delivered as a completion, so the app takes an
/// identical code path either way.
///
/// Every accepted command yields exactly one completion, and a refusal is a
/// completion too, so an app never waits forever for an id it will never see.
fn dispatchCommands(staging: *CompletionStaging, roc_host: *RocHost, commands: abi.RocList(CommandToHost)) void {
    defer {
        if (commands.hasOneRef()) {
            for (commands.allocationItems()) |item| item.decref(roc_host);
        }
        commands.decref(roc_host);
    }

    for (commands.items()) |command| {
        switch (command.kind) {
            CMD_READ_FILE => {
                const path = command.path.asSlice();
                if (headlessMode()) {
                    readFileNow(staging, roc_host, command.id, path);
                } else switch (effect_worker.submitReadFile(command.id, path)) {
                    .accepted => {},
                    .busy => staging.fileRead(roc_host, command.id, READ_ERR_BUSY, ""),
                    .unavailable => staging.fileRead(roc_host, command.id, READ_ERR_UNAVAILABLE, ""),
                }
            },
            CMD_DELAY => armTimer(command.id, command.millis),
            else => if (TRACE_HOST) std.log.debug("[HOST] Ignoring command kind {d}", .{command.kind}),
        }
    }
}

/// Read on the calling thread and stage the completion. Headless only.
fn readFileNow(staging: *CompletionStaging, roc_host: *RocHost, id: u64, path: []const u8) void {
    const allocator = allocatorFromHost(roc_host);
    const bytes = std.Io.Dir.cwd().readFileAlloc(mainThreadIo(), path, allocator, .limited(MAX_HOST_TEXT_FILE_BYTES)) catch |err| {
        staging.fileRead(roc_host, id, switch (err) {
            error.FileNotFound => READ_ERR_NOT_FOUND,
            else => READ_ERR_FAILED,
        }, "");
        return;
    };
    defer allocator.free(bytes);
    staging.fileRead(roc_host, id, 0, bytes);
}

/// Record a delay so its result can be delivered once the deadline passes.
fn armTimer(id: u64, millis: u64) void {
    if (pending_timer_count == pending_timers.len) {
        std.log.warn("roc-ray timer table full; dropping delay {d}", .{id});
        return;
    }
    // `millis` comes from the app, so saturate rather than wrap: a wrapped
    // deadline fires immediately, which looks like a delay that did not work.
    const delay_nanos = std.math.mul(u64, millis, std.time.ns_per_ms) catch std.math.maxInt(u64);
    pending_timers[pending_timer_count] = .{ .id = id, .due_nanos = last_frame_nanos +| delay_nanos };
    pending_timer_count += 1;
}

/// Stage a completion for every timer whose deadline has passed.
fn expireTimers(staging: *CompletionStaging, now_nanos: u64) void {
    var index: usize = 0;
    while (index < pending_timer_count and !staging.full()) {
        if (pending_timers[index].due_nanos <= now_nanos) {
            staging.delayElapsed(pending_timers[index].id);
            pending_timer_count -= 1;
            pending_timers[index] = pending_timers[pending_timer_count];
        } else {
            index += 1;
        }
    }
}

/// Stage the worker's finished reads.
///
/// The only place a worker result becomes a Roc value, and it runs on the main
/// thread -- which is what keeps `roc_alloc` single-threaded. Stops at the
/// per-step budget and leaves the rest for the next cycle.
fn stageWorkerResults(staging: *CompletionStaging, roc_host: *RocHost) void {
    while (!staging.full()) {
        const result = effect_worker.takeResult() orelse return;
        if (result.bytes) |bytes| {
            defer effect_worker.allocator.free(bytes);
            staging.fileRead(roc_host, result.id, 0, bytes);
        } else {
            staging.fileRead(roc_host, result.id, result.err, "");
        }
    }
}

/// Apply the startup capture configuration once the window exists.
///
/// A recording declared in `App.Config` goes through the same validation as
/// `Capture.start!`, so a bad path or an over-budget request is reported the
/// same way rather than being trusted because it came from config.
fn configureCapture(app_config: AppConfig) void {
    capture_session.reset();
    virtual_mouse_active = false;
    virtual_mouse_has_last = false;
    virtual_mouse_buttons = @splat(false);
    virtual_mouse_wheel = 0;

    capture_screenshot_pending = false;
    capture_recording_bytes = 0;
    capture_clock_offset_ns = 0;
    capture_clock_last_real_ns = 0;

    const dir = app_config.output_dir.asSlice();
    if (!storeCapturePath(&capture_output_dir, &capture_output_dir_len, dir)) {
        std.log.warn("output directory path too long; capturing into the working directory", .{});
        capture_output_dir_len = 0;
    }

    if (!app_config.record_enabled) return;

    const result = startCaptureRecording(.{
        .path = app_config.record_path.asSlice(),
        .format = app_config.record_format,
        .fps = app_config.record_fps,
        .max_frames = app_config.record_max_frames,
        .scale_numerator = app_config.record_scale_numerator,
        .scale_denominator = app_config.record_scale_denominator,
        .every_nth = app_config.record_every_nth,
        .timing = app_config.record_timing,
        .cursor = app_config.record_cursor,
        .quality = app_config.record_quality,
    });
    if (result != capture.err_none) {
        std.log.err("could not start the recording declared in App.Config (capture error {d})", .{result});
    }
}

/// Finalize an unfinished recording at shutdown.
///
/// Reaching the frame cap, calling `Capture.stop!`, and simply exiting all have
/// to produce a complete file, so every exit path funnels through here.
fn finalizeCapture() void {
    if (capture_session.status == capture.status_idle) {
        // A recording stopped through `Capture.stop!` has already closed its
        // container; this only guards against a sink left open some other way.
        _ = closeCaptureSink(true);
        return;
    }
    const frames = capture_session.captured_frames;
    const result = capture_session.stop();
    const close_result = closeCaptureSink(true);
    if (result != capture.err_none) {
        std.log.err("recording stopped early after {d} frame(s) (capture error {d})", .{ frames, result });
    } else if (close_result != capture.err_none) {
        std.log.err("could not finalize the recording after {d} frame(s) (capture error {d})", .{ frames, close_result });
    }
}

/// Report a monotonic clock that accounts for fixed-step recording.
///
/// While fixed-stepping we advance by exactly one step per frame and accumulate
/// how far that has taken us from raylib's clock, so `timestamp_nanos` stays
/// consistent with the `frame_time` values Roc saw and never jumps backwards
/// when a recording starts or stops.
fn captureAdjustedClock(real_ns: u64, fixed_step: ?f32) u64 {
    if (fixed_step) |dt| {
        const step_ns: i128 = @intFromFloat(@as(f64, dt) * 1_000_000_000.0);
        const real_delta: i128 = @as(i128, real_ns) - @as(i128, capture_clock_last_real_ns);
        capture_clock_offset_ns += step_ns - real_delta;
    }
    capture_clock_last_real_ns = real_ns;
    const adjusted = @as(i128, real_ns) + capture_clock_offset_ns;
    if (adjusted < 0) return 0;
    return @intCast(adjusted);
}

/// Read back and write anything this frame asked to capture.
///
/// Called from inside the drawing scope, immediately before `endDrawing`:
/// `EndDrawing` swaps the buffers, and reading the framebuffer after the swap
/// returns driver-dependent contents rather than the frame just drawn.
///
/// A downscaled recording is read back through the GPU chain, at the size it
/// keeps. Everything else -- a screenshot, an unscaled recording, or a frame
/// that wants both, since a screenshot is always full resolution -- takes a
/// single full-resolution readback and serves both from it.
fn serviceCaptureRequests() void {
    const wants_screenshot = capture_screenshot_pending;
    const wants_frame = capture_session.isActive() and capture_session.shouldCaptureFrame();
    if (!wants_screenshot and !wants_frame) return;

    capture_screenshot_pending = false;

    // The glyph goes into the frame that is about to be presented as well as
    // into the file. That is invisible for the hidden-window case this exists
    // for; a visible window shows it alongside the real cursor.
    if (wants_frame and capture_session.cursor == capture.cursor_draw) {
        drawCaptureCursorOverlay();
    }

    // A downscaled recording only ever keeps a fraction of the framebuffer, so
    // shrink it on the GPU and read back the finished size. A screenshot wants
    // full resolution, so a frame that has both falls through to the
    // full-resolution readback and the CPU resize below rather than reading
    // twice.
    if (wants_frame and !wants_screenshot) {
        if (captureScaledFrame()) |scaled| {
            var frame = scaled;
            defer frame.deinit();
            writeRecordingFrame(frame);
            finishRecordingAtFrameCap();
            return;
        }
    }

    var image = raylib.captureFramebuffer() orelse {
        if (wants_frame) capture_session.fail(capture.err_out_of_memory);
        if (wants_screenshot) capture_screenshot_result = capture.err_out_of_memory;
        return;
    };
    defer image.deinit();

    if (wants_screenshot) {
        capture_screenshot_result = writeCaptureImage(
            image,
            capture_screenshot_path[0..capture_screenshot_path_len],
            null,
        );
    }

    if (!wants_frame) return;

    if (capture_session.width != image.width() or capture_session.height != image.height()) {
        image.resize(capture_session.width, capture_session.height);
    }

    writeRecordingFrame(image);
    finishRecordingAtFrameCap();
}

/// Hand one captured frame, already at the recording's size, to its sink.
fn writeRecordingFrame(image: raylib.CaptureImage) void {
    switch (capture_session.format) {
        capture.format_png => writeRecordingFramePng(image),
        capture.format_gif => writeRecordingFrameGif(image),
        capture.format_webm => writeRecordingFrameWebm(image),
        // `start!` already rejects unknown formats, so reaching here would mean
        // a known one had no sink.
        else => capture_session.fail(capture.err_unsupported_format),
    }
}

/// Finalize a recording that has just written its last permitted frame.
///
/// Reaching the frame cap finalizes the file, which is what `Capture.start!`
/// and `App.with_recording` both promise. Without this a capped recording stays
/// `Active` forever, counts every later frame as dropped, and only reaches disk
/// when the process exits.
fn finishRecordingAtFrameCap() void {
    if (!capture_session.isActive() or !capture_session.reachedFrameCap()) return;
    _ = capture_session.stop();
    const closed = closeCaptureSink(true);
    if (closed != capture.err_none) {
        std.log.err("could not finalize the recording at its frame cap (capture error {d})", .{closed});
    }
}

/// Read this frame through the GPU downscale chain, at the recording's size.
///
/// Returns null whenever the full-resolution readback has to run instead: an
/// unscaled recording, a GPU that would not give us the render targets, a
/// framebuffer smaller than the recording asked for, or a readback that failed.
///
/// The chain is not exposed to the caller. Encoding a frame can reach the frame
/// cap, which finalizes the recording and releases the chain, so a borrowed
/// pointer to it would not survive the write it was fetched for.
fn captureScaledFrame() ?raylib.CaptureImage {
    const downscaler = activeCaptureDownscaler() orelse return null;
    if (downscaler.readFrame()) |scaled| return scaled;

    // The chain built but could not be read. Drop it and take the
    // full-resolution path for this frame and every later one, rather than
    // losing frames to a GPU problem we cannot diagnose here.
    releaseCaptureDownscaler();
    capture_downscale_unavailable = true;
    return null;
}

/// The GPU downscaler for the active recording, built or rebuilt on demand.
///
/// Returns null whenever the full-resolution readback is the right answer: an
/// unscaled recording, a GPU that would not give us the render targets, or a
/// framebuffer smaller than the recording asked for.
fn activeCaptureDownscaler() ?*raylib.CaptureDownscaler {
    if (capture_downscale_unavailable) return null;

    const plan = capture.planDownscale(
        @intCast(@max(currentRenderWidth(), 1)),
        @intCast(@max(currentRenderHeight(), 1)),
        capture_session.width,
        capture_session.height,
    ) orelse return null;

    if (capture_downscaler) |*existing| {
        if (existing.matches(plan)) return existing;
        // The window resized, or this is a second recording at a different
        // scale. Reusing the old targets would hand the encoder frames of the
        // wrong size, so rebuild rather than adapt.
        releaseCaptureDownscaler();
    }

    capture_downscaler = raylib.CaptureDownscaler.init(plan) orelse {
        capture_downscale_unavailable = true;
        return null;
    };
    return &capture_downscaler.?;
}

/// Release the downscale render targets, if any are held.
///
/// Requires a live GL context, so every caller has to run while the window is
/// still open.
fn releaseCaptureDownscaler() void {
    if (capture_downscaler) |*existing| existing.deinit();
    capture_downscaler = null;
}

/// Encode one frame into the open WebM file.
fn writeRecordingFrameWebm(image: raylib.CaptureImage) void {
    if (!capture_webm_open) {
        capture_session.fail(capture.err_encode_failed);
        return;
    }
    capture_webm.addFrame(image.pixels()) catch |err| {
        capture_session.fail(vp8ErrorCode(err));
        return;
    };
    capture_recording_bytes = capture_webm.bytesWritten();
}

/// Composite the pointer glyph for a recording that asked for one.
///
/// Uses the virtual pointer when one is active and the hardware pointer
/// otherwise, so a recording of real interaction also shows a cursor.
fn drawCaptureCursorOverlay() void {
    const position = if (virtual_mouse_active)
        raylib.Vec2{ .x = virtual_mouse_x, .y = virtual_mouse_y }
    else
        raylib.getMousePosition();
    const pressed = if (virtual_mouse_active)
        virtual_mouse_buttons[0]
    else
        raylib.getMouseButtonState()[0] & ffi.INPUT_HELD != 0;
    raylib.drawCaptureCursor(position.x, position.y, pressed, 1);
}

/// Write one frame of a PNG-sequence recording.
fn writeRecordingFramePng(image: raylib.CaptureImage) void {
    var frame_path: [capture.path_capacity]u8 = undefined;
    const path = framePathForIndex(
        &frame_path,
        capture_recording_path[0..capture_recording_path_len],
        capture_session.captured_frames - 1,
    ) orelse {
        capture_session.fail(capture.err_write_failed);
        return;
    };

    var written: u64 = 0;
    const result = writeCaptureImage(image, path, &written);
    if (result != capture.err_none) {
        capture_session.fail(result);
        return;
    }
    capture_recording_bytes +|= written;
}

/// Append one frame to the open GIF.
fn writeRecordingFrameGif(image: raylib.CaptureImage) void {
    if (!capture_gif_open) {
        capture_session.fail(capture.err_encode_failed);
        return;
    }
    capture_gif.addFrame(image.pixels()) catch |err| {
        capture_session.fail(captureErrorCode(err));
        return;
    };
    capture_recording_bytes = capture_gif.bytesWritten();
}

/// Run one Roc render call inside the host-owned raylib frame scope.
/// `defer` closes the frame for both `Ok` and `Err` results.
fn renderFrame(boxed_model: RocBox) RocResult {
    if (active_headless) return render_for_host(boxed_model);

    const NativeRender = struct {
        model: RocBox,

        fn begin(_: *@This()) void {
            raylib.beginDrawing();
        }

        fn render(self: *@This()) RocResult {
            return render_for_host(self.model);
        }

        fn end(_: *@This()) void {
            serviceCaptureRequests();
            raylib.endDrawing();
        }
    };

    var call = NativeRender{ .model = boxed_model };
    return withDrawingScope(&call, NativeRender.begin, NativeRender.render, NativeRender.end);
}

fn withDrawingScope(
    context: anytype,
    comptime begin_fn: anytype,
    comptime render_fn: anytype,
    comptime end_fn: anytype,
) @typeInfo(@TypeOf(render_fn)).@"fn".return_type.? {
    begin_fn(context);
    defer end_fn(context);
    return render_fn(context);
}

test "drawing scope ends after its render result is produced" {
    const Probe = struct {
        events: [3]u8 = undefined,
        count: usize = 0,

        fn record(self: *@This(), event: u8) void {
            self.events[self.count] = event;
            self.count += 1;
        }

        fn begin(self: *@This()) void {
            self.record(1);
        }

        fn render(self: *@This()) u8 {
            self.record(2);
            return 42;
        }

        fn end(self: *@This()) void {
            self.record(3);
        }
    };

    var probe = Probe{};
    const result = withDrawingScope(&probe, Probe.begin, Probe.render, Probe.end);

    try std.testing.expectEqual(@as(u8, 42), result);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, probe.events[0..probe.count]);
}

test "a virtual pointer derives movement deltas across frames" {
    defer {
        virtual_mouse_active = false;
        virtual_mouse_has_last = false;
    }

    hostedCaptureSetVirtualMouse(.{
        .active = true,
        .x = 100,
        .y = 50,
        .left = false,
        .middle = false,
        .right = false,
        .wheel = 0,
    });
    // The first virtual frame has nothing to measure against, so it must not
    // report a jump from wherever the pointer happened to be before.
    try std.testing.expectEqual(@as(f32, 0), virtualMouseDelta().x);
    try std.testing.expectEqual(@as(f32, 0), virtualMouseDelta().y);
    recordVirtualMousePosition();

    hostedCaptureSetVirtualMouse(.{
        .active = true,
        .x = 130,
        .y = 45,
        .left = false,
        .middle = false,
        .right = false,
        .wheel = 0,
    });
    try std.testing.expectEqual(@as(f32, 30), virtualMouseDelta().x);
    try std.testing.expectEqual(@as(f32, -5), virtualMouseDelta().y);
}

test "releasing the virtual pointer clears its buttons and history" {
    hostedCaptureSetVirtualMouse(.{
        .active = true,
        .x = 10,
        .y = 10,
        .left = true,
        .middle = false,
        .right = true,
        .wheel = 2,
    });
    try std.testing.expect(virtual_mouse_active);
    try std.testing.expect(virtual_mouse_buttons[0]);
    // Index 1 is raylib's right button, 2 is middle.
    try std.testing.expect(virtual_mouse_buttons[1]);
    try std.testing.expect(!virtual_mouse_buttons[2]);
    recordVirtualMousePosition();

    hostedCaptureSetVirtualMouse(.{
        .active = false,
        .x = 0,
        .y = 0,
        .left = false,
        .middle = false,
        .right = false,
        .wheel = 0,
    });
    try std.testing.expect(!virtual_mouse_active);
    try std.testing.expect(!virtual_mouse_has_last);
    try std.testing.expect(!virtual_mouse_buttons[0]);
    try std.testing.expectEqual(@as(f32, 0), virtual_mouse_wheel);
}

test "taking a model for render clears the host-owned reference" {
    const model: *anyopaque = @ptrFromInt(@alignOf(usize));
    var boxed_model: RocBox = model;

    try std.testing.expectEqual(model, takeModelForRender(&boxed_model));
    try std.testing.expectEqual(null, boxed_model);
}

test "each update call takes the model afresh so one reference stays live" {
    // `update!` runs once per message, and every call consumes its Box. Taking
    // once per frame would hand the same reference to the second call.
    var boxed_model: RocBox = @ptrFromInt(@alignOf(usize));

    var call: usize = 0;
    while (call < 4) : (call += 1) {
        const taken = takeModel(&boxed_model);
        try std.testing.expect(taken != null);
        try std.testing.expectEqual(null, boxed_model);
        boxed_model = taken;
    }

    try std.testing.expect(boxed_model != null);
}








test "staged completions become one Roc list, and an idle step allocates none" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    // The ordinary frame completes nothing, so it must allocate nothing.
    var idle = CompletionStaging{};
    const empty = idle.toRocList(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), empty.items().len);
    empty.decref(&roc_host);

    var staging = CompletionStaging{};
    staging.fileRead(&roc_host, 7, 0, "a payload long enough to need the heap");
    staging.delayElapsed(9);

    const list = staging.toRocList(&roc_host);
    try std.testing.expectEqual(@as(usize, 2), list.items().len);
    try std.testing.expectEqual(COMPLETION_FILE_READ, list.items()[0].kind);
    try std.testing.expectEqual(@as(u64, 9), list.items()[1].id);

    // Roc consumes the list in the real loop; this stands in for that. A leak
    // reported by std.testing.allocator means a payload escaped.
    for (list.allocationItems()) |item| item.contents.decref(&roc_host);
    list.decref(&roc_host);
}

test "releasing staged completions frees payloads that never reach Roc" {
    // The path where update! fails before the step is delivered.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    var staging = CompletionStaging{};
    staging.fileRead(&roc_host, 1, 0, "contents the staging area still owns");
    staging.fileRead(&roc_host, 2, 0, "and a second one for good measure");
    staging.release(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), staging.len);
}

test "a step carries at most its completion budget, leaving the rest queued" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    // A burst of finished work must not become unbounded work in one frame.
    var staging = CompletionStaging{};
    var pushed: usize = 0;
    while (pushed < MAX_COMPLETIONS_PER_STEP + 8) : (pushed += 1) {
        staging.delayElapsed(pushed);
    }
    try std.testing.expectEqual(MAX_COMPLETIONS_PER_STEP, staging.len);
    staging.release(&roc_host);
}

test "timers expire once and stop at the step budget" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    pending_timer_count = 0;
    last_frame_nanos = 0;
    armTimer(1, 10);
    armTimer(2, 30);

    var staging = CompletionStaging{};
    expireTimers(&staging, 15 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), staging.len);
    try std.testing.expectEqual(@as(u64, 1), staging.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), pending_timer_count);

    expireTimers(&staging, 40 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), pending_timer_count);
    staging.release(&roc_host);
}

test "an absurd delay saturates its deadline instead of wrapping to the past" {
    pending_timer_count = 0;
    last_frame_nanos = 1_000;
    armTimer(1, std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), pending_timers[0].due_nanos);
    pending_timer_count = 0;
}

test "a saturated worker refuses with Busy rather than running work inline" {
    // Running it here would stall the frame, which is what the split exists to
    // prevent. A refusal is still a completion, so the app is never left
    // waiting for an id that will never come back.
    var worker = EffectWorker{};
    worker.allocator = std.testing.allocator;
    try std.testing.expectEqual(EffectWorker.Submission.unavailable, worker.submitReadFile(1, "x"));

    worker.accepting = true;
    var accepted: usize = 0;
    while (accepted < EffectWorker.capacity) : (accepted += 1) {
        try std.testing.expectEqual(EffectWorker.Submission.accepted, worker.submitReadFile(accepted, "x"));
    }
    try std.testing.expectEqual(EffectWorker.Submission.busy, worker.submitReadFile(9999, "x"));
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

    // Only the windowed host runs a worker: headless executes every effect
    // inline so its output stays bit-identical run to run for CI.
    effect_worker.start(allocator);
    defer effect_worker.stop();


    var input = InputState.init(roc_host);
    defer input.deinit();

    raylib.setConfigFlags(raylib.windowConfigFlags(
        app_config.resizable,
        app_config.fullscreen,
        app_config.vsync,
        app_config.visible,
    ));
    raylib.initWindow(
        positiveCInt(app_config.width, 800),
        positiveCInt(app_config.height, 600),
        window_title.ptr,
    );
    defer raylib.closeWindow();
    // Both of these need a live window: InitWindow zeroes raylib's CORE state
    // and writes exitKey = KEY_ESCAPE, so an earlier SetExitKey is discarded,
    // and SetWindowMinSize needs the window handle.
    raylib.setWindowMinSize(
        nonNegativeCInt(app_config.min_width),
        nonNegativeCInt(app_config.min_height),
    );
    raylib.setExitKey(nonNegativeCInt(app_config.exit_key_code));
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

    // Capture setup must follow InitWindow, because arming a recording sizes
    // its frames from the real framebuffer. Registered after closeWindow's
    // defer so LIFO ordering finalizes the file while the window still lives.
    configureCapture(app_config);
    defer finalizeCapture();

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
        // raylib's own delta, forced to 0 on the first frame -- unless a
        // fixed-step recording is running, which substitutes an exact delta so
        // the captured animation is smooth and reproducible.
        const real_ns: u64 = @intFromFloat(raylib.getTime() * 1_000_000_000.0);
        const fixed_step = capture_session.fixedStepSeconds();
        const frame_time: f32 = if (frame_count == 0) 0 else (fixed_step orelse raylib.getFrameTime());
        const now_ns: u64 = captureAdjustedClock(real_ns, fixed_step);
        updateMusicStreams();

        input.updateFromRaylib();
        const mouse_pos = if (virtual_mouse_active)
            raylib.Vec2{ .x = virtual_mouse_x, .y = virtual_mouse_y }
        else
            raylib.getMousePosition();
        const mouse_delta = if (virtual_mouse_active) virtualMouseDelta() else raylib.getMouseDelta();
        const mouse_wheel = if (virtual_mouse_active)
            raylib.Vec2{ .x = 0, .y = virtual_mouse_wheel }
        else
            raylib.getMouseWheelMoveV();
        if (virtual_mouse_active) {
            recordVirtualMousePosition();
            // A real wheel reports movement for one frame and then returns to
            // zero, so consume the scripted value rather than reporting it
            // again on every subsequent frame.
            virtual_mouse_wheel = 0;
        }
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

        last_frame_nanos = now_ns;
        var staging = CompletionStaging{};
        stageWorkerResults(&staging, roc_host);
        expireTimers(&staging, now_ns);

        // One call, before the drawing scope opens, so `update!` structurally
        // cannot draw -- it is never handed a Frame.
        const update_result = updateOnce(&boxed_model, .{
            .snapshot = platform_state,
            .frame_count = frame_count,
            .timestamp_nanos = now_ns,
            .elapsed_seconds = frame_time,
            .completed = staging.toRocList(roc_host),
        });
        if (update_result.tag == .Err) {
            exit_code = @intCast(update_result.payload_err());
            if (TRACE_HOST) std.log.debug("[HOST] update returned Err({d})", .{exit_code});
            break;
        }
        const next = update_result.payload_ok();
        boxed_model = next.model;
        dispatchCommands(&staging, roc_host, next.commands);
        staging.release(roc_host);

        const render_result = renderFrame(takeModelForRender(&boxed_model));
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
        const timestamp_nanos = frame_count * HEADLESS_FRAME_NANOS;
        const platform_state = input.hostState(
            frame_count,
            timestamp_nanos,
            frame_time,
            0,
            0,
            .{ .x = 0, .y = 0 },
            .{ .x = 0, .y = 0 },
            &.{},
        );

        last_frame_nanos = timestamp_nanos;
        var staging = CompletionStaging{};
        stageWorkerResults(&staging, roc_host);
        expireTimers(&staging, timestamp_nanos);

        // One call, before the drawing scope opens, so `update!` structurally
        // cannot draw -- it is never handed a Frame.
        const update_result = updateOnce(&boxed_model, .{
            .snapshot = platform_state,
            .frame_count = frame_count,
            .timestamp_nanos = timestamp_nanos,
            .elapsed_seconds = frame_time,
            .completed = staging.toRocList(roc_host),
        });
        if (update_result.tag == .Err) {
            exit_code = @intCast(update_result.payload_err());
            if (TRACE_HOST) std.log.debug("[HOST] update returned Err({d})", .{exit_code});
            break;
        }
        const next = update_result.payload_ok();
        boxed_model = next.model;
        dispatchCommands(&staging, roc_host, next.commands);
        staging.release(roc_host);

        const render_result = renderFrame(takeModelForRender(&boxed_model));
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
    // The config now carries three Roc strings; `decref` releases all of them.
    defer app_config.decref(&roc_host);

    if (options.headless) {
        return runHeadlessApp(&roc_host, app_config, options.headless_frames);
    }

    return runNormalApp(&roc_host, allocator, app_config);
}
