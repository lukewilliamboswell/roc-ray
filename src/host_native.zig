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
const zio = @import("zio");
const tasks_mod = @import("tasks.zig");
const host_resource = @import("host_resource.zig");
const png = @import("png.zig");
const tilemap_batch = @import("tilemap_batch.zig");
const tmx_loader = @import("tmx_loader.zig");
const http_effect = @import("http_effect.zig");
const udp_effect = @import("udp_effect.zig");
const sqlite_effect = @import("sqlite_effect.zig");
const stdio_effect = @import("stdio_effect.zig");
const cmd_effect = @import("cmd_effect.zig");
const observatory = @import("observatory.zig");
const build_metadata = @import("build_metadata");

// There is not yet an authoritative RocRay release version embedded by the
// build. Report that absence instead of borrowing unrelated package metadata.
const rocray_build_version = "unavailable";
const roc_compiler_pin = build_metadata.roc_compiler_pin;

// `hostedHttpSend` is the only thing that names `http_effect`, and the hosted
// exports are compiled out under `zig test` (see the `!builtin.is_test` gate
// below), so nothing would reference the module and its own tests would never
// be collected. Reference it here instead.
test {
    _ = http_effect;
    _ = sqlite_effect;
    _ = cmd_effect;
}

// Import backend
const raylib = @import("backend_raylib.zig");

/// Keep zio's own debug chatter -- blocking-pool thread spawns, loop internals
/// -- out of an app's output. The host's own `ROC_RAY_TRACE_TASKS` lines are
/// unscoped `info` and are unaffected.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .zio, .level = .warn }},
};

// Type aliases
const RocBox = ffi.RocBox;
const RocResult = ffi.Try(ffi.RocBox, i64);
const InputSnapshot = ffi.InputSnapshot;
const WindowSnapshot = ffi.WindowSnapshot;
const RocHost = ffi.RocHost;
// read_env! returns Try(Str, [NotFound, ..]); the generated `abi.Try` (payload
// union of RocStr/err-ptr) is the correct 32-byte layout for it.
const Color = abi.ColorRgba;
const AppReadEnvResult = abi.HostABIApp_read_envResult;
const AppReadFileResult = abi.HostABIApp_read_fileRetRecord;
const TilemapLoadTmxRawResult = abi.HostABITilemap_load_tmxRetRecord;
const AppConfig = abi.App_config_for_host;
// One cycle of observations handed to update. Unions do not cross this
// boundary, so the recording state arrives as a flat record that Roc decodes.
const InputFromHost = abi.Update_for_hostArg1;
const UpdateResult = abi.Update_for_hostResult;
/// One finished task's message, wrapped in the erased thunk Roc calls to
/// unwrap it. The host only moves it; it never calls it.
const TaskResultEnvelope = abi.Update_for_hostArg1TaskResults;
const CaptureFromHost = abi.Update_for_hostArg1Capture;
/// One file dropped onto the window, crossing as the public `App.Dropped`.
const DroppedFile = abi.Update_for_hostArg1Dropped;
const DroppedPosition = abi.Update_for_hostArg1DroppedPosition;
/// One input event in the flat shape the types package decodes.
const InputEventRecord = abi.Update_for_hostArg1DevicesEvents;
const TilemapRawMap = abi.HostABITilemap_load_tmxMap;
const TilemapRawLayer = abi.HostABITilemap_load_tmxMapLayers;
const TilemapRawObject = abi.HostABITilemap_load_tmxMapObjects;
const TilemapRawPoint = abi.HostABITilemap_load_tmxMapPoints;
const TilemapRawProperty = abi.HostABITilemap_load_tmxMapProperties;
const TilemapRawTileProperties = abi.HostABITilemap_load_tmxMapTileProperties;
const TilemapRawTileset = abi.HostABITilemap_load_tmxMapTilesets;

const HOST_ERR_NOT_FOUND: u8 = 1;
const HOST_ERR_READ_FAILED: u8 = 2;
const TILEMAP_ERR_NOT_FOUND: u8 = 1;
const TILEMAP_ERR_READ_FAILED: u8 = 2;
const TILEMAP_ERR_PARSE_FAILED: u8 = 3;
const TILEMAP_ERR_UNSUPPORTED: u8 = 4;
const RESOURCE_ERR_NONE: u8 = 0;
const RESOURCE_ERR_FAILED: u8 = 1;
const RESOURCE_ERR_LIMIT: u8 = 2;
/// Store-open results. These are deliberately more specific than the existing
/// resource loader errors because startup needs actionable diagnostics.
const STORE_ERR_NONE: u8 = 0;
const STORE_ERR_ROOT_NOT_FOUND: u8 = 1;
const STORE_ERR_ROOT_NOT_DIRECTORY: u8 = 2;
const STORE_ERR_ROOT_UNREADABLE: u8 = 3;
const STORE_ERR_INVALID_ROOT_PATH: u8 = 4;
const STORE_ERR_INVALID_EXPECTED_CONTENT_HASH: u8 = 5;
const STORE_ERR_MANIFEST_MISSING: u8 = 6;
const STORE_ERR_MANIFEST_UNREADABLE: u8 = 7;
const STORE_ERR_MANIFEST_MALFORMED: u8 = 8;
const STORE_ERR_ASSET_SET_MISMATCH: u8 = 9;
const STORE_ERR_SCHEMA_MISMATCH: u8 = 10;
const STORE_ERR_CONTENT_VERSION_MISMATCH: u8 = 11;
const STORE_ERR_CONTENT_HASH_MISMATCH: u8 = 12;
const STORE_ERR_LIMIT: u8 = 13;
/// Store-loader results.  These remain separate from store-open errors so an
/// application can say whether its installation or one optional asset failed.
const STORE_LOAD_ERR_PATH: u8 = 1;
const STORE_LOAD_ERR_NOT_FOUND: u8 = 2;
const STORE_LOAD_ERR_READ: u8 = 3;
const STORE_LOAD_ERR_DECODE: u8 = 4;
const STORE_LOAD_ERR_LIMIT: u8 = 5;
const MAX_ASSET_FILE_BYTES: usize = 128 * 1024 * 1024;
const MAX_ASSET_MANIFEST_BYTES: usize = 1024 * 1024;
/// The largest file `Audio.load_sound!` and `Audio.load_music!` will read. It
/// bounds host memory per resource, not per frame: a sound is decoded whole
/// onto the device, and a music stream holds its encoded bytes for as long as
/// it exists. A larger file fails to load rather than being read.
const MAX_AUDIO_FILE_BYTES: usize = 64 * 1024 * 1024;
/// raylib 6's initial textLineSpacing. roc-ray exposes no setter, so a metric
/// snapshot can retain this scalar instead of a host/global dependency.
const RAYLIB_DEFAULT_TEXT_LINE_SPACING: f32 = 2;
const SCOPE_OK: u8 = 0;
const SCOPE_UNAVAILABLE: u8 = 1;
const SCOPE_LIMIT: u8 = 2;
const TEXTURE_UPDATE_OK: u8 = 0;
const TEXTURE_UPDATE_PIXEL_COUNT: u8 = 1;
const TEXTURE_UPDATE_NOT_MUTABLE: u8 = 2;
const TEXTURE_UPDATE_OUT_OF_BOUNDS: u8 = 3;
// Value 4 was the obsolete upload-capacity refusal. A structurally valid
// upload is never refused for host capacity now; keeping the remaining codes
// stable avoids needless transport churn for the checkable errors.
const TRY_TAG_OK: u8 = 1;
const MAX_FILE_READ_BYTES: usize = 16 * 1024 * 1024;
const HEADLESS_CLIPBOARD_CAPACITY: usize = 4096;

extern fn app_config_for_host() callconv(.c) AppConfig;
extern fn init_for_host() callconv(.c) RocResult;
extern fn update_for_host(arg0: RocBox, arg1: InputFromHost) callconv(.c) UpdateResult;
extern fn render_for_host(arg0: RocBox) callconv(.c) RocResult;
extern fn drop_model_for_host(arg0: RocBox) callconv(.c) void;
extern fn run_task_for_host(arg0: abi.RocErasedCallable) callconv(.c) abi.RocErasedCallable;

/// Read-error codes. Mirrored in `Files.roc`, `Window.roc` and `Capture.roc`.
///
/// `BUSY` and `UNAVAILABLE` are refusals rather than failures: the host declined
/// to start the work rather than running it on the frame thread.
const READ_ERR_NOT_FOUND: u8 = 1;
const READ_ERR_FAILED: u8 = 2;
const READ_ERR_BUSY: u8 = 3;
const READ_ERR_UNAVAILABLE: u8 = 4;
const READ_ERR_TOO_LARGE: u8 = 5;
/// The file's bytes are not valid UTF-8, so they cannot become a `Str`.
///
/// Only a small read can report this: it is the only read that produces a
/// string. A file read is delivered as bytes and needs no UTF-8 validation.
const READ_ERR_NOT_UTF8: u8 = 6;
/// The path exists but is not a directory, so it cannot be listed.
///
/// Only a listing can report this. It is kept distinct from `NOT_FOUND`
/// because an app walking a tree wants to tell "this entry has gone" apart
/// from "this entry is a file, read it instead".
const READ_ERR_NOT_A_DIRECTORY: u8 = 7;

/// The process may not write here. Mirrored in `Files.roc`.
///
/// Numbered past the read table rather than into it: a write shares
/// `NOT_FOUND`, `FAILED` and `UNAVAILABLE` with a read, and the two failures
/// only a write can have get codes of their own, so one code never means two
/// things across the boundary.
const WRITE_ERR_PERMISSION_DENIED: u8 = 8;
/// The filesystem is full or the process is over quota. Mirrored in `Files.roc`.
const WRITE_ERR_NO_SPACE: u8 = 9;
/// How many entries one listing may report, and how many bytes it may encode
/// them into.
///
/// A directory is not bounded by anything the host controls, so both ends are
/// capped and a listing past either is refused as `TooLarge` rather than
/// allocated. The encoded form is one kind byte, the name, and a NUL per
/// entry, so the byte cap is the one that binds on realistic trees and the
/// entry cap is what stops a directory of empty names.
const MAX_DIR_ENTRIES: usize = 8192;
const MAX_DIR_LISTING_BYTES: usize = 1024 * 1024;

/// Entry kinds in an encoded listing. Mirrored in `Files.roc`.
const DIR_ENTRY_FILE: u8 = 1;
const DIR_ENTRY_DIR: u8 = 2;
const DIR_ENTRY_OTHER: u8 = 3;

/// The most the host will copy into a Roc string in one operation.
///
/// Converting the bytes into a `Str` allocates and copies, which is why only
/// the reads that produce a string carry this limit: `Files.read_text!`
/// reports `TooLarge` above it, while `Files.read_bytes!` transfers its
/// allocation as an owning Roc byte list without copying and is bounded by the
/// much larger `MAX_FILE_READ_BYTES` instead.
const MAX_INLINE_READ_BYTES: usize = 64 * 1024;

/// How many host-owned file-byte allocations may be live at once.
///
/// Small on purpose. This bounds what an app can pin by retaining ordinary
/// `List(U8)` values or their seamless sublists. With the 16 MiB per-file
/// ceiling this is a few hundred megabytes, refused rather than unbounded.
const MAX_LIVE_FILE_BYTE_LISTS: usize = 32;

/// Name a failed read in the app's vocabulary.
///
/// A file past the host's per-file ceiling is `TooLarge` rather than
/// `ReadFailed`: nothing went wrong, the host declined a read of that size, and
/// those are different things for an app deciding what to do next.
fn readErrorCode(err: anyerror) u8 {
    return switch (err) {
        error.FileNotFound => READ_ERR_NOT_FOUND,
        error.StreamTooLong => READ_ERR_TOO_LARGE,
        else => READ_ERR_FAILED,
    };
}

/// Name a failed listing in the app's vocabulary.
///
/// `NotDir` is separated out for the reason above; everything else a directory
/// open can fail with is a plain failure from the app's point of view.
fn listErrorCode(err: anyerror) u8 {
    return switch (err) {
        error.FileNotFound => READ_ERR_NOT_FOUND,
        error.NotDir => READ_ERR_NOT_A_DIRECTORY,
        else => READ_ERR_FAILED,
    };
}

/// Name a failed write in the app's vocabulary.
///
/// Only the failures an app can act on differently are separated: retry
/// somewhere else (`PERMISSION_DENIED`), free space (`NO_SPACE`), fix the path
/// (`NOT_FOUND`). Everything else is a plain failure, because an app cannot do
/// anything different about it.
fn writeErrorCode(err: anyerror) u8 {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName, error.NameTooLong => READ_ERR_NOT_FOUND,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => WRITE_ERR_PERMISSION_DENIED,
        error.NoSpaceLeft, error.DiskQuota, error.FileTooBig => WRITE_ERR_NO_SPACE,
        else => READ_ERR_FAILED,
    };
}

/// Encode one directory's entries into the byte list the app is handed.
///
/// The format is one entry after another, each a kind byte, the name, and a
/// NUL -- a name cannot contain a NUL on any platform this runs on, so the
/// terminator is unambiguous and the whole listing is one allocation that
/// moves into Roc without being copied. The private App transport adapter decodes it.
///
/// Returns the error code, or zero and the buffer through `out`.
fn encodeListing(io: std.Io, allocator: std.mem.Allocator, path: []const u8, out: *?[]u8) u8 {
    return encodeListingIn(std.Io.Dir.cwd(), io, allocator, path, out);
}

/// `encodeListing` against an explicit base directory, so a test can point it
/// at a temporary tree without depending on the process working directory.
fn encodeListingIn(base: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, path: []const u8, out: *?[]u8) u8 {
    var dir = base.openDir(io, path, .{ .iterate = true }) catch |err| return listErrorCode(err);
    defer dir.close(io);

    var encoded: std.ArrayListUnmanaged(u8) = .empty;
    errdefer encoded.deinit(allocator);

    var entries: usize = 0;
    var walker = dir.iterate();
    while (walker.next(io) catch |err| return listErrorCode(err)) |entry| {
        entries += 1;
        if (entries > MAX_DIR_ENTRIES) {
            encoded.deinit(allocator);
            return READ_ERR_TOO_LARGE;
        }
        if (encoded.items.len + entry.name.len + 2 > MAX_DIR_LISTING_BYTES) {
            encoded.deinit(allocator);
            return READ_ERR_TOO_LARGE;
        }
        const kind: u8 = switch (entry.kind) {
            .file => DIR_ENTRY_FILE,
            .directory => DIR_ENTRY_DIR,
            else => DIR_ENTRY_OTHER,
        };
        encoded.append(allocator, kind) catch return READ_ERR_FAILED;
        encoded.appendSlice(allocator, entry.name) catch return READ_ERR_FAILED;
        encoded.append(allocator, 0) catch return READ_ERR_FAILED;
    }

    out.* = encoded.toOwnedSlice(allocator) catch return READ_ERR_FAILED;
    return 0;
}

fn writeWholeFile(io: std.Io, path: []const u8, bytes: []const u8) u8 {
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch return capture.err_write_failed;
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch return capture.err_write_failed;
    return capture.err_none;
}

/// The simulation clock this frame reported to Roc.
var last_frame_nanos: u64 = 0;

/// Real monotonic time at the start of this frame.
///
/// Separate from `last_frame_nanos` because a fixed-step recording makes the
/// simulation clock advance by an exact delta rather than by however long the
/// frame took. Waits are armed and expired against *this* one:
/// `Task.sleep!(1000)` means a second, and an app recording at a fixed step
/// has not asked for its timeouts to be re-scaled.
var last_wall_nanos: u64 = 0;

/// Start a fresh app lifetime.
///
/// Every previous lifetime must have released its byte-list reservations
/// before this point; resetting the count would let a stale reservation
/// collide with a new app.
fn beginAppLifetime() void {
    std.debug.assert(file_bytes_delivery_reservations.count == 0);
    trace_tracks = [_]TraceTrack{.{}} ** TRACE_TRACK_CAPACITY;
    task_trace_owners = [_]TaskTraceOwner{.{}} ** tasks_mod.max_live_tasks;
    resource_correlations = [_]ResourceCorrelation{.{}} ** resource_correlation_capacity;
    observatory_next_resource_id = 1;
    active_trace_owner = 0;
    exit_requested = null;
}

/// One cycle's finished task messages, on their way to the next `update!`.
///
/// The list outlives a single cycle: tasks finish while `update!` is running,
/// and their messages are delivered on the following input rather than being
/// spliced into the one already built.
///
/// The backing allocation grows geometrically and is retained until shutdown,
/// so an idle frame has no allocation, ordinary frames reuse the same storage,
/// and a burst only pays while it establishes a larger high-water mark.
const TaskResultStaging = struct {
    items: std.ArrayListUnmanaged(TaskResultEnvelope) = .empty,
    high_water: usize = 0,
    oldest_at_ns: u64 = 0,

    fn count(self: *const TaskResultStaging) usize {
        return self.items.items.len;
    }

    /// Move one finished task's erased message thunk into the input being
    /// assembled. `deliver` is always an owned reference, taken from the task
    /// registry. No Roc call happens in Zig.
    fn append(self: *TaskResultStaging, roc_host: *RocHost, deliver: abi.RocErasedCallable) void {
        std.debug.assert(deliver != null);
        self.items.ensureUnusedCapacity(allocatorFromHost(roc_host), 1) catch
            @panic("roc-ray: out of memory while staging a task result");
        self.items.appendAssumeCapacity(.{ .deliver = deliver });
        self.high_water = @max(self.high_water, self.count());
        const observed_at = recordTaskStagingQueue(.reserve, 1, self.count(), self.high_water, self.oldest_at_ns);
        if (self.count() == 1) self.oldest_at_ns = observed_at;
    }

    /// Hand this input's task messages to Roc and empty the staging area.
    ///
    /// The returned list owns its thunks. Staging is cleared without releasing
    /// them, to avoid a double free; a task that finishes afterwards is staged
    /// again and delivered on the next input.
    fn take(self: *TaskResultStaging, roc_host: *RocHost) abi.RocList(TaskResultEnvelope) {
        const released = self.count();
        const list = if (self.count() == 0)
            abi.RocList(TaskResultEnvelope).empty()
        else
            abi.RocList(TaskResultEnvelope).fromSlice(self.items.items, roc_host);
        self.items.clearRetainingCapacity();
        if (released != 0) _ = recordTaskStagingQueue(.release, released, 0, self.high_water, self.oldest_at_ns);
        self.oldest_at_ns = 0;
        return list;
    }

    /// Release messages staged but never delivered, such as a task that
    /// finished during the frame the app exited on.
    fn release(self: *TaskResultStaging, roc_host: *RocHost) void {
        const released = self.count();
        for (self.items.items) |item| item.decref(roc_host);
        self.items.deinit(allocatorFromHost(roc_host));
        self.items = .empty;
        if (released != 0) _ = recordTaskStagingQueue(.release, released, 0, self.high_water, self.oldest_at_ns);
        self.oldest_at_ns = 0;
    }
};

const TaskStagingQueueOperation = enum(u8) { reserve = 0, release = 1 };

fn taskStagingQueueEvent(operation: TaskStagingQueueOperation, amount: usize, current: usize, high_water: usize, oldest_at_ns: u64, now: u64) observatory.QueueEvent {
    return .{
        .cycle = observatory_cycle,
        .timestamp_ns = now,
        .kind = @intFromEnum(operation),
        .subject_id = high_water,
        // Zero deliberately means application-proportional: there is no
        // platform admission cap and therefore no saturation/refusal row.
        .parent_id = 0,
        .duration_ns = if (oldest_at_ns != 0) now -| oldest_at_ns else 0,
        .value_a = current,
        .value_b = amount,
        .name = "task staged messages",
    };
}

fn recordTaskStagingQueue(operation: TaskStagingQueueOperation, amount: usize, current: usize, high_water: usize, oldest_at_ns: u64) u64 {
    if (!observatory_task_detail) return 0;
    const now = traceNowNs();
    const session = active_observatory orelse return now;
    observatory_cycle_counts.queue +|= 1;
    _ = session.recordQueue(taskStagingQueueEvent(operation, amount, current, high_water, oldest_at_ns, now));
    return now;
}

const TRACE_HOST = false;
const DEFAULT_HEADLESS_FRAMES: u64 = 3;
const HEADLESS_FRAME_NANOS: u64 = 16_666_667;
const HEADLESS_FRAME_TIME: f32 = 1.0 / 60.0;
const HEADLESS_RESOURCE_SIZE: f32 = 64;
/// Global flag to track if dbg or expect_failed was called.
/// If set, program exits with non-zero code to prevent accidental publication.
var debug_or_expect_called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Roc's symbol ABI calls runtime and hosted symbols directly, without passing
/// host context. Keep the active per-process helper context here for callbacks.
var active_roc_host: ?*RocHost = null;
var active_headless = false;
var active_mouse_cursor_code: u8 = 255;
var active_observatory: ?*observatory.Session = null;
var observatory_origin_ns: i96 = 0;
var observatory_cycle: u64 = 0;
var observatory_failure_reported: bool = false;
var observatory_task_detail: bool = false;
var observatory_full_detail: bool = false;
var observatory_draw_calls: u64 = 0;
const ObservatoryCycleCounts = struct { task: u64 = 0, effect: u64 = 0, resource: u64 = 0, queue: u64 = 0 };
var observatory_cycle_counts = ObservatoryCycleCounts{};
var observatory_next_input_id: u64 = 1;
var observatory_next_effect_id: u64 = 1;
var observatory_current_input_id: u64 = 0;
const task_finish_correlation_capacity: usize = 256;
const TaskFinishCorrelation = struct { id: u64 = 0, at_ns: u64 = 0 };
var task_finish_correlations = [_]TaskFinishCorrelation{.{}} ** task_finish_correlation_capacity;

fn rememberTaskFinish(id: u64, at_ns: u64) bool {
    for (&task_finish_correlations) |*slot| {
        if (slot.id == 0) {
            slot.* = .{ .id = id, .at_ns = at_ns };
            return true;
        }
    }
    return false;
}

fn takeTaskFinish(id: u64) ?u64 {
    for (&task_finish_correlations) |*slot| {
        if (slot.id == id) {
            const at_ns = slot.at_ns;
            slot.* = .{};
            return at_ns;
        }
    }
    return null;
}
var observatory_next_allocation_id: u64 = 1;
var observatory_next_resource_id: u64 = 1;

const resource_correlation_capacity: usize = 4096;
const ResourceCorrelation = struct { token: u64 = 0, id: u64 = 0 };
var resource_correlations = [_]ResourceCorrelation{.{}} ** resource_correlation_capacity;

fn resourceCorrelation(token: u64, create: bool) u64 {
    if (token == 0) return 0;
    for (&resource_correlations) |*entry| if (entry.token == token) return entry.id;
    if (!create) return 0;
    for (&resource_correlations) |*entry| if (entry.token == 0) {
        const id = observatory_next_resource_id;
        observatory_next_resource_id +|= 1;
        entry.* = .{ .token = token, .id = id };
        return id;
    };
    return 0;
}

fn forgetResourceCorrelation(token: u64) void {
    for (&resource_correlations) |*entry| if (entry.token == token) {
        entry.* = .{};
        return;
    };
}

test "resource correlations replace lifecycle tokens with bounded private IDs" {
    resource_correlations = [_]ResourceCorrelation{.{}} ** resource_correlation_capacity;
    observatory_next_resource_id = 1;
    defer {
        resource_correlations = [_]ResourceCorrelation{.{}} ** resource_correlation_capacity;
        observatory_next_resource_id = 1;
    }
    const first = resourceCorrelation(0xABCD_1234, true);
    try std.testing.expectEqual(@as(u64, 1), first);
    try std.testing.expectEqual(first, resourceCorrelation(0xABCD_1234, false));
    try std.testing.expectEqual(@as(u64, 2), resourceCorrelation(0xFFFF_0001, true));
    forgetResourceCorrelation(0xABCD_1234);
    try std.testing.expectEqual(@as(u64, 0), resourceCorrelation(0xABCD_1234, false));
}

const allocation_identity_capacity: usize = 4096;
const AllocationIdentity = struct { pointer: usize = 0, id: u64 = 0, bytes: usize = 0, state: enum(u8) { empty, live, tombstone } = .empty };
const AllocationIdentities = struct {
    slots: [allocation_identity_capacity]AllocationIdentity = [_]AllocationIdentity{.{}} ** allocation_identity_capacity,
    live: usize = 0,

    fn reset(self: *@This()) void {
        self.* = .{};
    }

    fn index(pointer: usize) usize {
        return (pointer *% 0x9E3779B97F4A7C15) % allocation_identity_capacity;
    }

    fn put(self: *@This(), pointer: usize, id: u64, bytes: usize) bool {
        if (pointer == 0 or self.live == allocation_identity_capacity) return false;
        var first_tombstone: ?usize = null;
        var probe: usize = 0;
        while (probe < allocation_identity_capacity) : (probe += 1) {
            const at = (index(pointer) + probe) % allocation_identity_capacity;
            switch (self.slots[at].state) {
                .empty => {
                    const target = first_tombstone orelse at;
                    self.slots[target] = .{ .pointer = pointer, .id = id, .bytes = bytes, .state = .live };
                    self.live += 1;
                    return true;
                },
                .tombstone => if (first_tombstone == null) {
                    first_tombstone = at;
                },
                .live => if (self.slots[at].pointer == pointer) {
                    self.slots[at].id = id;
                    self.slots[at].bytes = bytes;
                    return true;
                },
            }
        }
        if (first_tombstone) |at| {
            self.slots[at] = .{ .pointer = pointer, .id = id, .bytes = bytes, .state = .live };
            self.live += 1;
            return true;
        }
        return false;
    }

    fn take(self: *@This(), pointer: usize) ?AllocationIdentity {
        var probe: usize = 0;
        while (probe < allocation_identity_capacity) : (probe += 1) {
            const at = (index(pointer) + probe) % allocation_identity_capacity;
            switch (self.slots[at].state) {
                .empty => return null,
                .tombstone => {},
                .live => if (self.slots[at].pointer == pointer) {
                    const found = self.slots[at];
                    self.slots[at].state = .tombstone;
                    self.live -= 1;
                    return found;
                },
            }
        }
        return null;
    }

    fn get(self: *const @This(), pointer: usize) ?AllocationIdentity {
        var probe: usize = 0;
        while (probe < allocation_identity_capacity) : (probe += 1) {
            const at = (index(pointer) + probe) % allocation_identity_capacity;
            switch (self.slots[at].state) {
                .empty => return null,
                .tombstone => {},
                .live => if (self.slots[at].pointer == pointer) return self.slots[at],
            }
        }
        return null;
    }
};
var allocation_identities: AllocationIdentities = .{};
var allocation_realloc_id: u64 = 0;
var allocation_realloc_old_pointer: usize = 0;
var allocation_realloc_old_bytes: usize = 0;
var allocation_realloc_in_place: bool = false;

test "bounded allocation identities preserve live IDs across moves and frees" {
    var identities = AllocationIdentities{};
    try std.testing.expect(identities.put(0x1000, 7, 64));
    try std.testing.expectEqual(@as(usize, 1), identities.live);
    try std.testing.expectEqual(@as(u64, 7), identities.get(0x1000).?.id);

    // Realloc allocates the destination before freeing the source. Both slots
    // temporarily name the same private identity; removing the source leaves
    // one live allocation at the destination.
    try std.testing.expect(identities.put(0x2000, 7, 96));
    _ = identities.take(0x1000).?;
    try std.testing.expectEqual(@as(usize, 1), identities.live);
    const moved = identities.get(0x2000).?;
    try std.testing.expectEqual(@as(u64, 7), moved.id);
    try std.testing.expectEqual(@as(usize, 96), moved.bytes);
    try std.testing.expectEqual(@as(u64, 7), identities.take(0x2000).?.id);
    try std.testing.expectEqual(@as(usize, 0), identities.live);
}

test "allocation identity registry refuses saturation without overwriting live entries" {
    var identities = AllocationIdentities{};
    for (0..allocation_identity_capacity) |index| {
        try std.testing.expect(identities.put(0x1000 + index * 16, index + 1, index));
    }
    try std.testing.expectEqual(allocation_identity_capacity, identities.live);
    try std.testing.expect(!identities.put(0xFFFF_FFF0, 99_999, 1));
    try std.testing.expectEqual(@as(u64, 1), identities.get(0x1000).?.id);
}

/// Unit tests exercise host ownership in headless mode; native rendering has
/// its own opt-in graphical smoke target and must not leak GUI link dependencies.
inline fn headlessMode() bool {
    return builtin.is_test or active_headless;
}

/// Which of the app's callbacks the host is currently inside.
///
/// Capabilities can be retained beyond the callback that produced them, so the
/// host validates each operation against the active callback phase.
const Phase = enum {
    /// Between callbacks: config, host bookkeeping, capture, shutdown.
    idle,
    /// Inside `init_for_host`, and inside the startup config callback.
    startup,
    /// Inside `update_for_host`, while the app's `update!` runs.
    update,
    /// Inside `render_for_host`.
    render,
    /// On a task coroutine, inside `run_task_for_host`.
    task,

    /// How the phase is named in a rejection, in the app's own vocabulary.
    fn label(self: Phase) []const u8 {
        return switch (self) {
            .idle => "outside any app callback",
            .startup => "init!",
            .update => "update!",
            .render => "render!",
            .task => "a task",
        };
    }
};

/// Callback phases in which an operation is valid.
const PhaseSet = std.EnumSet(Phase);

/// Startup-only operations: the `App.Startup` capabilities (blocking reads,
/// the clipboard read, the random seed), which exist so that `init!` can do
/// one-off setup work with the window already open.
const during_startup = PhaseSet.initOne(.startup);

/// Drawing, and anything that changes how the draws after it are interpreted.
/// Only defined inside the frame scope the host opens around `render!`.
const during_render = PhaseSet.initOne(.render);

/// Changing host state: cursor, window, audio, recordings. Reachable from
/// `init!`, `update!`, and tasks, and not from `render!`, which only draws.
const during_update = PhaseSet.initMany(&.{ .startup, .update, .task });

/// Allocating or generating a resource from bytes the app already holds.
/// Allowed wherever the app changes host state -- `init!`, `update!`, and
/// tasks -- but not during `render!`, where an upload or a decode lands in the
/// middle of a frame. The same set as `during_update`; the separate name
/// records intent.
///
/// A loader that opens a directory or reads a file is `during_wait` instead,
/// however small the file: reaching the filesystem from `update!` is what
/// invariant 4 forbids. Where a resource can be built without one, the
/// `*_from_bytes!` spelling stays in this set, so a load a task started can
/// still be finished in `update!`.
const during_load = during_update;

/// Handing the host deferred work: `Task.spawn!`, and `Task.spawn_with!`
/// through it. The task's message comes back on a later input, which `init!`
/// never sees, and `render!` does not change the world.
const during_spawn = PhaseSet.initMany(&.{ .update, .task });

/// Constant-time operations with nothing to allocate and no I/O to do: reading
/// a font metric, asking whether a sound is still playing, taking a random
/// number. Valid in every callback, but not outside callbacks. Operations that
/// copy, allocate, write files, or access a driver do not belong in this set.
const constant_time_anywhere = PhaseSet.initMany(&.{ .startup, .update, .render, .task });

/// One-way diagnostic annotations. Kept distinct from constant-time queries:
/// annotations may validate and copy a bounded label into recorder storage.
const diagnostic_anywhere = PhaseSet.initMany(&.{ .startup, .update, .render, .task });

/// Effects that wait. On a task they park the coroutine; in `init!` they
/// block. Never during a frame.
const during_wait = PhaseSet.initMany(&.{ .startup, .task });

/// Waiting effects whose answer is a frame that has to be drawn first.
///
/// `during_wait` minus `init!`. A screenshot is read back at the end of a
/// frame, and `init!` runs before the frame loop has gone around once, so a
/// screenshot asked for there would park for a frame that cannot arrive while
/// it holds the frame thread. That is a programming error with a fix -- spawn
/// a task from `update!` -- rather than a condition to report, so it is
/// refused by name here rather than coming back as an `Unavailable` that says
/// nothing about what to do instead.
const during_frame_wait = PhaseSet.initOne(.task);

/// The host-side hooks the task registry needs: Roc entry points and the
/// phase guard, kept here because `active_phase` is file-private.
const TaskHooks = struct {
    pub fn enterTaskPhase(task_id: u64) void {
        active_phase = .task;
        const owner = beginTraceOwner();
        rememberTaskTraceOwner(task_id, owner);
    }
    pub fn leaveTaskPhase(task_id: u64) void {
        forgetTaskTraceOwner(task_id);
        finishTraceOwner(active_trace_owner);
        active_trace_owner = 0;
        active_phase = .idle;
    }
    pub fn runTask(run: abi.RocErasedCallable) tasks_mod.TaskResult {
        return run_task_for_host(run);
    }
    pub fn dropResult(result: tasks_mod.TaskResult) void {
        abi.decrefErasedCallable(result, activeHost());
    }
    /// The Roc host a queued closure is released or started against. Only the
    /// frame thread ever asks, and only while an app is running.
    pub fn host() *RocHost {
        return activeHost();
    }
};

const AppTasks = tasks_mod.Tasks(TaskHooks);

/// Stable schema-version-one `task_events.kind` codes. New lifecycle kinds append;
/// existing captures keep these meanings for read-only analysis tools.
const ObservatoryTaskKind = enum(u8) {
    spawned,
    queued,
    started,
    parked,
    resumed,
    finished,
    delivered,
    cancelled,
};

fn packedTaskCounters(counters: tasks_mod.ObserverCounters) u64 {
    return (@as(u64, @intCast(@min(counters.live, std.math.maxInt(u32)))) << 32) |
        @as(u64, @intCast(@min(counters.queued, std.math.maxInt(u32))));
}

/// Schema-version-one task rows use `value_a` for the kind-specific scalar
/// (tasks ahead, queued cycles, wait hint, or cancellation stage). `value_b`
/// packs live in its high 32 bits and queued in its low 32 bits. `parent_id`
/// stays zero until the scheduler supplies a real parent task identity.
fn observatoryTaskEvent(event: tasks_mod.ObserverEvent) observatory.TaskEvent {
    var detail = observatory.TaskEvent{
        .cycle = event.cycle,
        .timestamp_ns = event.timestamp_ns,
        .kind = undefined,
        .subject_id = event.task_id,
        .value_b = packedTaskCounters(event.counters),
    };
    switch (event.kind) {
        .spawned => detail.kind = @intFromEnum(ObservatoryTaskKind.spawned),
        .queued => |queued| {
            detail.kind = @intFromEnum(ObservatoryTaskKind.queued);
            detail.value_a = queued.tasks_ahead;
        },
        .started => |started| {
            detail.kind = @intFromEnum(ObservatoryTaskKind.started);
            detail.value_a = started.queued_cycles;
        },
        .parked => |parked| {
            detail.kind = @intFromEnum(ObservatoryTaskKind.parked);
            detail.value_a = parked.millis_hint;
            detail.name = parked.effect;
        },
        .resumed => |resumed| {
            detail.kind = @intFromEnum(ObservatoryTaskKind.resumed);
            detail.name = resumed.effect;
        },
        .finished => detail.kind = @intFromEnum(ObservatoryTaskKind.finished),
        .delivered => detail.kind = @intFromEnum(ObservatoryTaskKind.delivered),
        .cancelled => |stage| {
            detail.kind = @intFromEnum(ObservatoryTaskKind.cancelled);
            detail.value_a = @intFromEnum(stage);
            detail.name = @tagName(stage);
        },
    }
    return detail;
}

fn observatoryTaskNow(_: *anyopaque) u64 {
    return if (observatory_task_detail) traceNowNs() else 0;
}

fn recordObservatoryTask(context: *anyopaque, event: tasks_mod.ObserverEvent) void {
    observatory_cycle_counts.task +|= 1;
    switch (event.kind) {
        .cancelled => |stage| if (stage == .live) abortTaskTraceOwner(event.task_id, sessionFromContext(context)),
        else => {},
    }
    if (!observatory_task_detail) return;
    switch (event.kind) {
        .finished => {
            if (!rememberTaskFinish(event.task_id, event.timestamp_ns)) sessionFromContext(context).noteLoss(.structural_latency, 1);
        },
        .delivered => if (takeTaskFinish(event.task_id)) |finished_ns| recordStructuralLatency(3, event.task_id, observatory_current_input_id, finished_ns, "task_finish_to_delivery"),
        else => {},
    }
    const session: *observatory.Session = @ptrCast(@alignCast(context));
    var detail = observatoryTaskEvent(event);
    switch (event.kind) {
        .delivered => detail.parent_id = observatory_current_input_id,
        // zone_abort rows were submitted synchronously just above. Sample the
        // cancellation row afterwards so cross-table timestamp comparison
        // preserves that causal ordering in an end-to-end capture.
        .cancelled => detail.timestamp_ns = traceNowNs(),
        else => {},
    }
    _ = session.recordTask(detail);
}

fn recordObservatoryTaskQueue(context: *anyopaque, event: tasks_mod.QueueObservation) void {
    if (!observatory_task_detail) return;
    observatory_cycle_counts.queue +|= 1;
    _ = sessionFromContext(context).recordQueue(.{
        .cycle = event.cycle,
        .timestamp_ns = event.timestamp_ns,
        .kind = @intFromEnum(event.operation),
        .subject_id = event.high_water,
        .parent_id = if (event.capacity) |capacity| capacity else 0,
        .duration_ns = if (event.oldest_at_ns != 0) event.timestamp_ns -| event.oldest_at_ns else 0,
        .value_a = event.current,
        .value_b = event.amount,
        .name = "task pending closures",
    });
}

test "task finish correlations are bounded private identities consumed once" {
    task_finish_correlations = [_]TaskFinishCorrelation{.{}} ** task_finish_correlation_capacity;
    defer task_finish_correlations = [_]TaskFinishCorrelation{.{}} ** task_finish_correlation_capacity;
    try std.testing.expect(rememberTaskFinish(41, 900));
    try std.testing.expectEqual(@as(u64, 900), takeTaskFinish(41).?);
    try std.testing.expect(takeTaskFinish(41) == null);
    for (0..task_finish_correlation_capacity) |index| try std.testing.expect(rememberTaskFinish(index + 1, index));
    try std.testing.expect(!rememberTaskFinish(9999, 1));
}

fn sessionFromContext(context: *anyopaque) *observatory.Session {
    return @ptrCast(@alignCast(context));
}

fn taskObserver(session: *observatory.Session) tasks_mod.Observer {
    return .{ .context = session, .now_ns = observatoryTaskNow, .on_event = recordObservatoryTask, .on_queue = recordObservatoryTaskQueue };
}

test "task observer adapter preserves identity timing kinds waits and bounded counters" {
    const base = tasks_mod.ObserverEvent{
        .task_id = 17,
        .cycle = 9,
        .timestamp_ns = 1234,
        .counters = .{ .live = 4, .queued = 6, .finished = 2, .delivered = 1 },
        .kind = .spawned,
    };
    const spawned = observatoryTaskEvent(base);
    try std.testing.expectEqual(@as(u8, 0), spawned.kind);
    try std.testing.expectEqual(@as(u64, 17), spawned.subject_id);
    try std.testing.expectEqual(@as(u64, 9), spawned.cycle);
    try std.testing.expectEqual(@as(u64, 1234), spawned.timestamp_ns);
    try std.testing.expectEqual((@as(u64, 4) << 32) | 6, spawned.value_b);
    try std.testing.expectEqual(@as(u64, 0), spawned.parent_id);

    var event = base;
    event.kind = .{ .queued = .{ .tasks_ahead = 11 } };
    const queued = observatoryTaskEvent(event);
    try std.testing.expectEqual(@as(u8, 1), queued.kind);
    try std.testing.expectEqual(@as(u64, 11), queued.value_a);
    event.kind = .{ .started = .{ .queued_cycles = 3 } };
    const started = observatoryTaskEvent(event);
    try std.testing.expectEqual(@as(u8, 2), started.kind);
    try std.testing.expectEqual(@as(u64, 3), started.value_a);

    event.kind = .{ .parked = .{ .effect = "sqlite.run", .millis_hint = 50 } };
    const parked = observatoryTaskEvent(event);
    try std.testing.expectEqual(@as(u8, 3), parked.kind);
    try std.testing.expectEqualStrings("sqlite.run", parked.name);
    try std.testing.expectEqual(@as(u64, 50), parked.value_a);
    event.kind = .{ .resumed = .{ .effect = "sqlite.run" } };
    const resumed = observatoryTaskEvent(event);
    try std.testing.expectEqual(@as(u8, 4), resumed.kind);
    try std.testing.expectEqualStrings("sqlite.run", resumed.name);

    event.kind = .finished;
    try std.testing.expectEqual(@as(u8, 5), observatoryTaskEvent(event).kind);
    event.kind = .delivered;
    try std.testing.expectEqual(@as(u8, 6), observatoryTaskEvent(event).kind);
    event.kind = .{ .cancelled = .live };
    const cancelled = observatoryTaskEvent(event);
    try std.testing.expectEqual(@as(u8, 7), cancelled.kind);
    try std.testing.expectEqual(@as(u64, @intFromEnum(tasks_mod.CancellationStage.live)), cancelled.value_a);
    try std.testing.expectEqualStrings("live", cancelled.name);
}

/// `Task.spawn!`: hand an erased `() => Msg` closure to the task runtime.
///
/// The closure is owned by this call. It starts on its own coroutine at the
/// next pump, which the frame loop runs right after `update!` returns, so a
/// task spawned this cycle parks on its first wait before the frame is drawn.
fn hostedTaskSpawn(run: abi.RocErasedCallable) callconv(.c) void {
    enforcePhase("Task.spawn!", during_spawn);
    const effect = EffectScope.begin("Task.spawn!", 0);
    defer effect.end();
    // Spawning can hand control to the executor before it returns -- zio runs
    // a newly spawned coroutine as soon as its tick budget says to -- and a
    // task sets phases of its own while it runs, and clears them when it
    // parks. Restore ours, so a second `Task.spawn!` in the same `update!`
    // still sees `update`. Without this, spawning enough tasks in one call
    // makes the next spawn fail the phase guard.
    const scope = PhaseScope.enter(active_phase);
    defer scope.leave();
    AppTasks.spawnCurrent(activeHost(), run);
}

/// Stage every finished task's message for the next input.
fn stageTaskResults(app_tasks: *AppTasks, staging: *TaskResultStaging, roc_host: *RocHost) void {
    const finished = app_tasks.takeFinished();
    defer app_tasks.releaseTaken(finished);
    for (finished) |item| {
        // The recorder sees only its task identity and when the message became
        // eligible for a later Input, never the message or its layout.
        recordStructuralLatency(2, item.id, 0, traceNowNs(), "task_message_staged");
        staging.append(roc_host, item.result);
    }
}

/// The phase a waiting effect must restore when its park returns.
///
/// The phase is saved and cleared across the park: the frame loop runs in
/// between and sets phases of its own, and the task must see `.task` again
/// when it resumes.
const WaitScope = struct {
    resumed: Phase,
    resumed_trace_owner: u32,
    parked_started_ns: i96,

    fn enter() WaitScope {
        const scope = WaitScope{
            .resumed = active_phase,
            .resumed_trace_owner = active_trace_owner,
            .parked_started_ns = if (active_observatory != null) observatoryAwakeNs() else 0,
        };
        active_phase = .idle;
        active_trace_owner = 0;
        return scope;
    }

    fn leave(self: WaitScope) void {
        if (active_observatory != null and (self.resumed == .startup or self.resumed == .task) and self.resumed_trace_owner != 0) {
            chargeTraceParked(self.resumed_trace_owner, @intCast(@max(observatoryAwakeNs() - self.parked_started_ns, 0)));
        }
        active_phase = self.resumed;
        active_trace_owner = self.resumed_trace_owner;
    }
};

/// The `std.Io` a waiting effect performs its work through.
///
/// On a task, zio parks the coroutine on the io_uring/kqueue/IOCP completion
/// and switches to the executor, which returns to the frame loop; a later pump
/// resumes the task and the call returns. In `init!` the frame loop is zio's
/// own main task, so the same call parks that task and runs the event loop
/// until the answer is in -- effectively blocking, which is what startup wants.
/// Without a runtime (unit tests, or a runtime that would not start) this is
/// the frame thread's ordinary blocking implementation.
fn waitingIo() std.Io {
    if (AppTasks.currentRuntime()) |rt| return rt.io();
    return mainThreadIo();
}

/// `Task.sleep!`: park the calling task, or block during `init!`.
fn hostedTaskSleep(millis: u64) callconv(.c) void {
    enforcePhase("Task.sleep!", during_wait);
    var effect = EffectScope.begin("Task.sleep!", 0);
    defer effect.end();
    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("sleep", millis);
    const external_started = observatoryDetailMeasurementStart();
    zio.sleep(.fromMilliseconds(@intCast(millis))) catch |err| switch (err) {
        // Cancelled at shutdown: return at once so the task can run to its end.
        error.Canceled => {},
    };
    effect.setExternalElapsed(external_started);
    AppTasks.observeResume(park, "sleep");
}

/// Read a whole file on the waiting path, parked rather than blocking.
///
/// `limit` is the operation's own ceiling: a text read stops one byte past the
/// largest string the host will build, a byte read one past the per-file
/// ceiling, so a file of exactly the limit succeeds and one byte more is
/// `TooLarge` without the whole file having been read first.
fn readFileWaiting(allocator: std.mem.Allocator, path: []const u8, limit: usize, out_err: *u8) ?[]u8 {
    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("read", 0);
    defer AppTasks.observeResume(park, "read");
    return std.Io.Dir.cwd().readFileAlloc(waitingIo(), path, allocator, .limited(limit)) catch |err| {
        out_err.* = readErrorCode(err);
        return null;
    };
}

/// `Files.read_text!`: read a bounded UTF-8 file into a `Str`.
///
/// The whole file is copied into the string, so the ceiling is the small one:
/// this is the only read whose cost on the frame thread is proportional to the
/// file. A file that is not valid UTF-8 is reported rather than delivered,
/// because `RocStr.fromSlice` only copies and every later string operation on
/// an invalid one would be undefined.
fn hostedFilesReadText(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.HostABIFiles_read_textRetRecord {
    enforcePhase("Files.read_text!", during_wait);
    var effect = EffectScope.begin("Files.read_text!", path_arg.asSlice().len);
    defer effect.end();
    defer path_arg.decref(roc_host);

    const allocator = allocatorFromHost(roc_host);
    var err: u8 = READ_ERR_FAILED;
    const external_started = observatoryDetailMeasurementStart();
    const bytes = readFileWaiting(allocator, path_arg.asSlice(), MAX_INLINE_READ_BYTES + 1, &err) orelse {
        effect.setExternalElapsed(external_started);
        effect.setOutcome(if (err == READ_ERR_BUSY or err == READ_ERR_UNAVAILABLE) .refused else .runtime_error);
        return .{ .err = err, .contents = abi.RocStr.empty() };
    };
    effect.setExternalElapsed(external_started);
    defer allocator.free(bytes);

    const validation_started = observatoryDetailMeasurementStart();
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        effect.setValidationElapsed(validation_started);
        effect.setOutcome(.runtime_error);
        return .{ .err = READ_ERR_NOT_UTF8, .contents = abi.RocStr.empty() };
    }
    effect.setValidationElapsed(validation_started);
    effect.addCopiedBytes(bytes.len);
    const conversion_started = observatoryDetailMeasurementStart();
    const contents = abi.RocStr.fromSlice(bytes, roc_host);
    effect.setConversionElapsed(conversion_started);
    return .{ .err = 0, .contents = contents };
}

fn exportedFilesReadText(path_arg: abi.RocStr) callconv(.c) abi.HostABIFiles_read_textRetRecord {
    return hostedFilesReadText(activeHost(), path_arg);
}

/// `Files.read_bytes!`: read a bounded file without copying its payload.
///
/// The buffer the read filled is the buffer Roc gets: it moves into the typed
/// byte-list heap and out again as an owning seamless `List(U8)`, so a 16 MiB
/// file costs one allocation and no copy. A delivery slot is reserved before
/// any I/O starts, so a full heap answers `Busy` rather than reading a file and
/// discarding it.
fn hostedFilesReadBytes(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.HostABIFiles_read_bytesRetRecord {
    enforcePhase("Files.read_bytes!", during_wait);
    var effect = EffectScope.begin("Files.read_bytes!", path_arg.asSlice().len);
    defer effect.end();
    defer path_arg.decref(roc_host);
    const result = readByteListWaiting(roc_host, path_arg.asSlice(), .read);
    if (result.err != 0) {
        effect.setOutcome(if (result.err == READ_ERR_BUSY or result.err == READ_ERR_UNAVAILABLE) .refused else .runtime_error);
    } else {
        effect.addOwnershipTransferBytes(result.bytes.items().len);
    }
    return result;
}

fn exportedFilesReadBytes(path_arg: abi.RocStr) callconv(.c) abi.HostABIFiles_read_bytesRetRecord {
    return hostedFilesReadBytes(activeHost(), path_arg);
}

/// `Files.list!`: one directory's entries, encoded into the same byte list a
/// read delivers and decoded by `Files`.
fn hostedFilesList(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.HostABIFiles_listRetRecord {
    enforcePhase("Files.list!", during_wait);
    var effect = EffectScope.begin("Files.list!", path_arg.asSlice().len);
    defer effect.end();
    defer path_arg.decref(roc_host);
    // Structurally the same record as a byte read's, but a distinct generated
    // type, so copy it across field by field rather than casting.
    const result = readByteListWaiting(roc_host, path_arg.asSlice(), .list);
    if (result.err != 0) effect.setOutcome(if (result.err == READ_ERR_BUSY or result.err == READ_ERR_UNAVAILABLE) .refused else .runtime_error);
    return .{ .err = result.err, .bytes = result.bytes };
}

fn exportedFilesList(path_arg: abi.RocStr) callconv(.c) abi.HostABIFiles_listRetRecord {
    return hostedFilesList(activeHost(), path_arg);
}

/// Name a failed stat in the app's vocabulary.
///
/// A stat can be refused for a reason a read cannot: a directory on the way to
/// the path may be one this process may not look inside, which is a permission
/// the app can ask the user about rather than a path it should fix.
fn statErrorCode(err: anyerror) u8 {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName, error.NameTooLong => READ_ERR_NOT_FOUND,
        error.AccessDenied, error.PermissionDenied => WRITE_ERR_PERMISSION_DENIED,
        error.Canceled => READ_ERR_UNAVAILABLE,
        else => READ_ERR_FAILED,
    };
}

/// The listing kind byte for what a stat found at the end of a path.
///
/// Symbolic links do not appear: a stat follows them, so what is reported is
/// the kind of the thing the link points at.
fn statEntryKind(kind: std.Io.File.Kind) u8 {
    return switch (kind) {
        .file => DIR_ENTRY_FILE,
        .directory => DIR_ENTRY_DIR,
        else => DIR_ENTRY_OTHER,
    };
}

/// Stat one path on the waiting path, parked rather than blocking.
///
/// Shaped exactly like a read: the phase guard, the park, and the trace are
/// the same, and the difference is only that the answer is five numbers rather
/// than a payload, so there is no delivery slot to reserve and nothing to
/// bound but the wait itself.
fn statPathIn(base: std.Io.Dir, io: std.Io, path: []const u8) abi.HostABIFiles_metadataRetRecord {
    const stat = base.statFile(io, path, .{ .follow_symlinks = true }) catch |err|
        return .{ .err = statErrorCode(err), .kind = 0, .size_bytes = 0, .modified_seconds = 0, .modified_nanosecond = 0 };
    const modified = timestampFromNanos(stat.mtime.nanoseconds);
    return .{
        .err = 0,
        .kind = statEntryKind(stat.kind),
        .size_bytes = stat.size,
        .modified_seconds = modified.seconds,
        .modified_nanosecond = modified.nanosecond,
    };
}

/// `Files.metadata!`: what one path is, how big it is, and when it changed.
fn hostedFilesMetadata(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.HostABIFiles_metadataRetRecord {
    enforcePhase("Files.metadata!", during_wait);
    var effect = EffectScope.begin("Files.metadata!", path_arg.asSlice().len);
    defer effect.end();
    defer path_arg.decref(roc_host);
    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("stat", 0);
    defer AppTasks.observeResume(park, "stat");
    const result = statPathIn(std.Io.Dir.cwd(), waitingIo(), path_arg.asSlice());
    if (result.err != 0) effect.setOutcome(if (result.err == READ_ERR_UNAVAILABLE) .refused else .runtime_error);
    return result;
}

fn exportedFilesMetadata(path_arg: abi.RocStr) callconv(.c) abi.HostABIFiles_metadataRetRecord {
    return hostedFilesMetadata(activeHost(), path_arg);
}

/// Replace a whole file on the waiting path, parked rather than blocking.
///
/// Missing parent directories are created, which is what `writeWholeFile` does
/// for every file the host writes itself; the two differ only in that this one
/// names its failure in the app's vocabulary instead of the capture codes.
///
/// The path is used as the app gave it. `Files` is not sandboxed in either
/// direction -- reads take any path the process can open, and so do writes.
/// `Capture` is the one part of this host with an output root, and it confines
/// captures only.
fn writeFileWaiting(path: []const u8, bytes: []const u8) u8 {
    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("write", 0);
    defer AppTasks.observeResume(park, "write");
    // Written through std's threaded implementation on zio's blocking pool
    // rather than through the runtime's own file backend: creating
    // directories and files through that backend fails on Windows. The pool
    // parks the calling task the same way the event loop would, and the
    // worker touches only the host-visible path and payload bytes.
    const allocator = allocatorFromHost(activeHost());
    const rt = AppTasks.currentRuntime() orelse return writeFileBlocking(allocator, path, bytes);
    var blocking = rt.spawnBlocking(writeFileBlocking, .{ allocator, path, bytes }) catch return READ_ERR_FAILED;
    return blocking.join();
}

/// The write itself, on whichever thread the caller chose.
fn writeFileBlocking(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    return writeFileWaitingIn(std.Io.Dir.cwd(), threaded.io(), path, bytes);
}

/// `writeFileWaiting` against an explicit base directory, so a test can point
/// it at a temporary tree without depending on the process working directory.
fn writeFileWaitingIn(base: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) u8 {
    if (std.fs.path.dirname(path)) |parent| {
        base.createDirPath(io, parent) catch |err| return writeErrorCode(err);
    }
    base.writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| return writeErrorCode(err);
    return 0;
}

/// `Files.write_text!`: replace a file's contents with a UTF-8 string.
fn hostedFilesWriteText(roc_host: *RocHost, path_arg: abi.RocStr, contents_arg: abi.RocStr) callconv(.c) u8 {
    enforcePhase("Files.write_text!", during_wait);
    var effect = EffectScope.begin("Files.write_text!", path_arg.asSlice().len +| contents_arg.asSlice().len);
    defer effect.end();
    defer path_arg.decref(roc_host);
    defer contents_arg.decref(roc_host);
    const result = writeFileWaiting(path_arg.asSlice(), contents_arg.asSlice());
    if (result != 0) effect.setOutcome(if (result == READ_ERR_UNAVAILABLE) .refused else .runtime_error);
    return result;
}

fn exportedFilesWriteText(path_arg: abi.RocStr, contents_arg: abi.RocStr) callconv(.c) u8 {
    return hostedFilesWriteText(activeHost(), path_arg, contents_arg);
}

/// `Files.write_bytes!`: replace a file's contents with the app's bytes.
fn hostedFilesWriteBytes(roc_host: *RocHost, path_arg: abi.RocStr, bytes_arg: abi.RocListWith(u8, false)) callconv(.c) u8 {
    enforcePhase("Files.write_bytes!", during_wait);
    var effect = EffectScope.begin("Files.write_bytes!", path_arg.asSlice().len +| bytes_arg.items().len);
    defer effect.end();
    defer path_arg.decref(roc_host);
    defer bytes_arg.decref(roc_host);
    const result = writeFileWaiting(path_arg.asSlice(), bytes_arg.items());
    if (result != 0) effect.setOutcome(if (result == READ_ERR_UNAVAILABLE) .refused else .runtime_error);
    return result;
}

fn exportedFilesWriteBytes(path_arg: abi.RocStr, bytes_arg: abi.RocListWith(u8, false)) callconv(.c) u8 {
    return hostedFilesWriteBytes(activeHost(), path_arg, bytes_arg);
}

/// Split a wall-clock reading into the normalized parts `Time.Timestamp` holds.
///
/// The seconds are floored rather than truncated, so the fractional part is
/// always the nanoseconds elapsed within the instant's own second on both
/// sides of the epoch. A reading a signed 64-bit count of seconds cannot hold
/// saturates: no real clock reaches it, and an app is better served by an
/// instant at the end of time than by a wrapped one in the middle of it.
fn timestampFromNanos(nanos: i128) abi.HostABITime_nowRetRecord {
    const whole = @divFloor(nanos, std.time.ns_per_s);
    const seconds = std.math.cast(i64, whole) orelse {
        return .{
            .seconds = if (whole < 0) std.math.minInt(i64) else std.math.maxInt(i64),
            .nanosecond = 0,
        };
    };
    return .{ .seconds = seconds, .nanosecond = @intCast(nanos - whole * std.time.ns_per_s) };
}

/// `Time.now!`: what time it is in the world.
///
/// Reading the clock changes nothing and waits for nothing, but it is refused
/// during `render!` all the same. Wall time is not the timeline this platform
/// paces: an animation driven from it would ignore the fixed step a capture
/// records under, and `render!` is handed the model rather than an input, so
/// the instant a frame draws is one the model already decided on.
/// The reading itself is `Clock.real`, which is settable and can jump when the
/// administrator or NTP moves it. That is what a calendar is; the timeline
/// that only moves forward is `input.time`, and the two are deliberately
/// different values. Reading a clock does not block, so this takes no
/// `WaitScope` and needs none of the parking machinery a waiting effect has.
fn hostedTimeNow() callconv(.c) abi.HostABITime_nowRetRecord {
    enforcePhase("Time.now!", during_update);
    const effect = EffectScope.begin("Time.now!", 0);
    defer effect.end();
    return timestampFromNanos(std.Io.Clock.real.now(waitingIo()).nanoseconds);
}

/// The stream a `StdioHost` call names. Mirrored in `StdioHost.roc`.
const STDIO_STREAM_STDOUT: u8 = 1;

/// The ring one of those numbers stands for.
///
/// The number is written by `Stdout` and `Stderr` rather than by the app, so
/// there is no third case to report: anything that is not standard output is
/// standard error.
fn streamRing(stream: u8) u8 {
    return if (stream == STDIO_STREAM_STDOUT) stdio_effect.stdout_index else stdio_effect.stderr_index;
}

/// Copy one payload into a stream's queue. See `src/stdio_effect.zig`.
///
/// `head` and `tail` are one payload in that order, so a line reserves its
/// text and its newline together and nothing another write queues can land
/// between them. The copy happens here, on the frame thread, while the Roc
/// value is still alive; the caller releases it as this returns.
fn queueStreamWrite(stream: u8, head: []const u8, tail: []const u8) u8 {
    return stdio_effect.write(streamRing(stream), head, tail);
}

/// `Stdout.write!` and `Stderr.write!`: the app's string, with nothing added.
fn hostedStdioWriteText(roc_host: *RocHost, stream: u8, text_arg: abi.RocStr) callconv(.c) u8 {
    const name = if (stream == STDIO_STREAM_STDOUT) "Stdout.write!" else "Stderr.write!";
    enforcePhase(name, during_update);
    var effect = EffectScope.begin(name, text_arg.asSlice().len);
    defer effect.end();
    defer text_arg.decref(roc_host);
    const result = queueStreamWrite(stream, text_arg.asSlice(), &.{});
    if (result != 0) effect.setOutcome(.refused);
    return result;
}

fn exportedStdioWriteText(stream: u8, text_arg: abi.RocStr) callconv(.c) u8 {
    return hostedStdioWriteText(activeHost(), stream, text_arg);
}

/// `Stdout.line!` and `Stderr.line!`: the app's string and one newline.
///
/// The newline is the host's byte rather than a copy of the app's string with
/// one appended, so a line costs no allocation and is queued as one payload.
fn hostedStdioWriteLine(roc_host: *RocHost, stream: u8, text_arg: abi.RocStr) callconv(.c) u8 {
    const name = if (stream == STDIO_STREAM_STDOUT) "Stdout.line!" else "Stderr.line!";
    enforcePhase(name, during_update);
    var effect = EffectScope.begin(name, text_arg.asSlice().len);
    defer effect.end();
    defer text_arg.decref(roc_host);
    const result = queueStreamWrite(stream, text_arg.asSlice(), "\n");
    if (result != 0) effect.setOutcome(.refused);
    return result;
}

fn exportedStdioWriteLine(stream: u8, text_arg: abi.RocStr) callconv(.c) u8 {
    return hostedStdioWriteLine(activeHost(), stream, text_arg);
}

/// `Stdout.write_bytes!` and `Stderr.write_bytes!`: bytes, passed through.
fn hostedStdioWriteBytes(roc_host: *RocHost, stream: u8, bytes_arg: abi.RocListWith(u8, false)) callconv(.c) u8 {
    const name = if (stream == STDIO_STREAM_STDOUT) "Stdout.write_bytes!" else "Stderr.write_bytes!";
    enforcePhase(name, during_update);
    var effect = EffectScope.begin(name, bytes_arg.items().len);
    defer effect.end();
    defer bytes_arg.decref(roc_host);
    const result = queueStreamWrite(stream, bytes_arg.items(), &.{});
    if (result != 0) effect.setOutcome(.refused);
    return result;
}

fn exportedStdioWriteBytes(stream: u8, bytes_arg: abi.RocListWith(u8, false)) callconv(.c) u8 {
    return hostedStdioWriteBytes(activeHost(), stream, bytes_arg);
}

/// `Capture.screenshot!`: one PNG of the frame the caller is waiting on.
///
/// The readback has to happen on the frame thread inside the drawing scope, so
/// the effect registers the request, parks the task, and is woken by
/// `serviceCaptureRequests` with the pixels. Encoding a 1080p PNG is tens of
/// milliseconds, so it runs on zio's blocking pool -- which parks the task
/// again rather than stalling the frame, and never touches Roc.
///
/// A task is the only place this works: waiting for the end of a frame from
/// `init!` would wait for a frame the frame loop has not started yet. See
/// `during_frame_wait`.
fn hostedCaptureScreenshot(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) u8 {
    enforcePhase("Capture.screenshot!", during_frame_wait);
    var effect = EffectScope.begin("Capture.screenshot!", path_arg.asSlice().len);
    defer effect.end();
    defer path_arg.decref(roc_host);
    const path = path_arg.asSlice();

    const validation = capture.validateRelativePath(path);
    if (validation != capture.err_none) return validation;

    // No framebuffer to read, so the request is answered without writing a
    // file of zeroes. Headless runs exist to produce identical output twice.
    if (headlessMode()) return capture.err_none;

    // No runtime at all: a unit test, or a runtime that would not start. The
    // phase guard has already refused every callback but a task, and under
    // `zig test` it only records the violation, so this second check is what
    // keeps a test from parking on a frame loop that is not running.
    const rt = AppTasks.currentRuntime() orelse return capture.err_unavailable;
    if (active_phase != .task) return capture.err_unavailable;

    if (screenshot_wait != null or capture_screenshot_pending) {
        return capture.err_already_recording;
    }
    if (!storeCapturePath(&capture_screenshot_path, &capture_screenshot_path_len, path)) {
        return capture.err_path_invalid;
    }

    var resolved_storage: [capture.path_capacity]u8 = undefined;
    const resolved = capture.joinOutputPath(&resolved_storage, captureOutputDir(), path) orelse
        return capture.err_write_failed;
    var resolved_copy: [capture.path_capacity]u8 = undefined;
    @memcpy(resolved_copy[0..resolved.len], resolved);

    var wait = ScreenshotWait{};
    screenshot_wait = &wait;
    capture_screenshot_pending = true;

    {
        const scope = WaitScope.enter();
        defer scope.leave();
        const park = AppTasks.observePark("screenshot", 0);
        defer AppTasks.observeResume(park, "screenshot");
        wait.ready.wait() catch {
            // Cancelled at shutdown before the frame ended. Nothing was
            // captured, so there is nothing to free.
            screenshot_wait = null;
            capture_screenshot_pending = false;
            return capture.err_unavailable;
        };
    }
    screenshot_wait = null;
    if (wait.err != capture.err_none) return wait.err;
    effect.setDrawMetrics(@as(u64, wait.width) *| wait.height, @intCast(wait.pixels.len));

    const allocator = allocatorFromHost(roc_host);
    defer allocator.free(wait.pixels);

    const scope = WaitScope.enter();
    defer scope.leave();
    var blocking = rt.spawnBlocking(encodeAndWritePng, .{
        allocator,
        wait.pixels,
        wait.width,
        wait.height,
        resolved_copy[0..resolved.len],
    }) catch return capture.err_out_of_memory;
    return blocking.join();
}

/// Encode RGBA pixels as a PNG and write the file. Runs on zio's blocking
/// pool: plain Zig values in, an error code out, and no Roc call anywhere.
fn encodeAndWritePng(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
    path: []const u8,
) u8 {
    const encoded = png.encodeRgba(allocator, pixels, width, height) catch |err| return switch (err) {
        error.OutOfMemory => capture.err_out_of_memory,
        else => capture.err_write_failed,
    };
    defer allocator.free(encoded);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    return writeWholeFile(threaded.io(), path, encoded);
}

fn exportedCaptureScreenshot(path_arg: abi.RocStr) callconv(.c) u8 {
    return hostedCaptureScreenshot(activeHost(), path_arg);
}

/// `Capture.screenshot_texture!`: one PNG of what a render target holds.
///
/// Unlike a screenshot this waits for nothing on the frame loop. The readback
/// needs the graphics context, which lives on this thread, and Roc only ever
/// runs on this thread -- so the pixels are taken synchronously, here, from
/// whatever the last completed `render!` left in the target. Only the encode
/// and the write park, on zio's blocking pool, which is why `init!` is a legal
/// place to call this and is not for `Capture.screenshot!`.
fn hostedCaptureScreenshotTexture(roc_host: *RocHost, args: abi.HostABICapture_screenshot_textureArgs) callconv(.c) u8 {
    enforcePhase("Capture.screenshot_texture!", during_wait);
    var effect = EffectScope.begin("Capture.screenshot_texture!", 0);
    defer effect.end();
    defer args.path.decref(roc_host);
    const path = args.path.asSlice();

    var pixels: []u8 = &.{};
    var width: u32 = 0;
    var height: u32 = 0;
    var reserved: u64 = 0;

    // Everything that touches the graphics context or the target's reference,
    // in one scope: the box is released here, before anything parks, because
    // nothing after this point needs the resource.
    const readback = readback: {
        defer releaseResourceBox(roc_host, args.target.handle);

        const validation = capture.validateRelativePath(path);
        if (validation != capture.err_none) break :readback validation;

        // Resolved before the headless answer, so a released or `stub` target
        // is reported the same way whether or not there is a window.
        const resource = render_texture_heap.get(args.target.handle.*) orelse
            break :readback capture.err_target_unavailable;

        // A headless render target has no pixels at all -- every draw into it
        // was a no-op -- so there is nothing to write. Answering `Ok` with no
        // file is what `Capture.screenshot!` does for the same reason, and it
        // keeps an exporting app runnable under `--host-headless`.
        const target = switch (resource.*) {
            .headless => break :readback capture.err_none,
            .native => |native| native,
        };
        if (headlessMode()) break :readback capture.err_none;

        // The target's own dimensions, not the ones the Roc value carries: the
        // readback is sized by what the GPU actually holds.
        const admitted = still_budget.admit(
            @intCast(@max(target.texture.width, 0)),
            @intCast(@max(target.texture.height, 0)),
            &reserved,
        );
        if (admitted != capture.err_none) break :readback admitted;

        const image = raylib.readRenderTexture(target) orelse {
            still_budget.release(reserved);
            break :readback capture.err_readback_failed;
        };
        defer image.deinit();

        // Copied out of raylib's allocation so the encode can happen off this
        // thread while raylib's buffer is freed on it.
        const source = image.pixels();
        const copy = allocatorFromHost(roc_host).alloc(u8, source.len) catch {
            still_budget.release(reserved);
            break :readback capture.err_out_of_memory;
        };
        @memcpy(copy, source);
        pixels = copy;
        width = image.width();
        height = image.height();
        break :readback capture.err_none;
    };
    if (readback != capture.err_none) return readback;
    // Headless, or a unit test with no graphics context: admitted, read
    // nothing, wrote nothing.
    if (pixels.len == 0) return capture.err_none;
    effect.setDrawMetrics(@as(u64, width) *| height, @intCast(pixels.len));

    const allocator = allocatorFromHost(roc_host);
    defer allocator.free(pixels);
    defer still_budget.release(reserved);

    var resolved_storage: [capture.path_capacity]u8 = undefined;
    const resolved = capture.joinOutputPath(&resolved_storage, captureOutputDir(), path) orelse
        return capture.err_write_failed;

    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("export", 0);
    defer AppTasks.observeResume(park, "export");
    // No runtime means `init!` on a host whose task runtime never started, so
    // the encode happens inline the way a file write does there.
    const rt = AppTasks.currentRuntime() orelse
        return encodeAndWritePng(allocator, pixels, width, height, resolved);
    var blocking = rt.spawnBlocking(encodeAndWritePng, .{
        allocator,
        pixels,
        width,
        height,
        resolved,
    }) catch return capture.err_out_of_memory;
    return blocking.join();
}

fn exportedCaptureScreenshotTexture(args: abi.HostABICapture_screenshot_textureArgs) callconv(.c) u8 {
    return hostedCaptureScreenshotTexture(activeHost(), args);
}

/// The framebuffer the host last presented, kept so a later `update!` has
/// defined pixels to read.
///
/// The back buffer is not it: `EndDrawing` swaps the buffers, and after the
/// swap what a readback would find is driver-dependent rather than the frame
/// the player is looking at. So the frame loop copies the frame out while it
/// still owns it, in the same hook that services a screenshot, and a `Screen`
/// readback slices this instead of touching the GPU.
///
/// The allocator travels with the buffer, exactly as `FileBytesResource`'s
/// does, because the buffer outlives the call that made it and is freed from a
/// frame hook with no host argument to ask.
const ScreenSnapshot = struct {
    allocator: ?std.mem.Allocator = null,
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// What this snapshot reserved from `still_budget`, returned when it goes.
    reserved: u64 = 0,
};
var screen_snapshot: ScreenSnapshot = .{};

/// Whether any `Screen` readback has run since the last frame ended.
///
/// This is what makes the snapshot cost proportional to use. An app that never
/// reads the screen never pays a readback; one that reads it pays one per
/// frame; one that stops reading stops paying after the next frame. The
/// consequence an app sees is that its very first `Screen` read has no
/// snapshot yet and is `Unavailable`.
var screen_snapshot_requested = false;

/// Keep this frame's pixels for the next cycle's `Screen` readbacks.
///
/// Copied out of the backend's allocation because that one is freed on this
/// thread as the drawing scope closes, and this has to outlive the frame.
/// A snapshot that cannot be admitted or allocated simply does not happen: the
/// next read reports `Unavailable`, which is the same answer it would give
/// before the first frame.
fn storeScreenSnapshot(image: raylib.CaptureImage) void {
    releaseScreenSnapshot();

    var reserved: u64 = 0;
    if (still_budget.admit(image.width(), image.height(), &reserved) != capture.err_none) return;

    const allocator = allocatorFromHost(activeHost());
    const source = image.pixels();
    const copy = allocator.alloc(u8, source.len) catch {
        still_budget.release(reserved);
        return;
    };
    @memcpy(copy, source);
    screen_snapshot = .{
        .allocator = allocator,
        .pixels = copy,
        .width = image.width(),
        .height = image.height(),
        .reserved = reserved,
    };
}

/// Drop the snapshot and give its budget back.
fn releaseScreenSnapshot() void {
    if (screen_snapshot.allocator) |allocator| allocator.free(screen_snapshot.pixels);
    still_budget.release(screen_snapshot.reserved);
    screen_snapshot = .{};
}

/// Where one readback's pixels came from, and what it owes when it is done.
///
/// A `Screen` read borrows the snapshot the frame loop already holds, so it
/// owns nothing. A `Target` read has to pull the whole target off the GPU for
/// this call alone, so it carries both the backend image and the budget
/// reservation that admitted it.
const ReadbackPixels = struct {
    bytes: []const u8,
    width: u32,
    height: u32,
    image: ?raylib.CaptureImage = null,
    reserved: u64 = 0,

    fn deinit(self: ReadbackPixels) void {
        // Only a windowed run ever holds an image: without a graphics context
        // a target readback answers `Unavailable` instead of producing one.
        // Saying so here rather than only in the optional keeps the backend's
        // unloader out of a build that has no raylib to unload with, which is
        // what the unit-test host is.
        if (!headlessMode()) {
            if (self.image) |image| image.deinit();
        }
        still_budget.release(self.reserved);
    }
};

/// Resolve a readback source to pixels, or to the code saying why there are none.
///
/// Does not touch the source's render-target reference: both callers own that
/// for the whole call and release it on every path, so a refused read cannot
/// keep a target alive and a taken one cannot drop it early.
fn resolveReadbackSource(source: abi.HostABICapture_pixel_atArg0Source, err: *u8) ?ReadbackPixels {
    if (source.screen) {
        // Every read re-arms the snapshot, including one that fails for want
        // of it: that is what makes the read after this one succeed.
        screen_snapshot_requested = true;
        if (screen_snapshot.pixels.len == 0) {
            err.* = capture.err_unavailable;
            return null;
        }
        return .{
            .bytes = screen_snapshot.pixels,
            .width = screen_snapshot.width,
            .height = screen_snapshot.height,
        };
    }

    // Resolved before the headless answer, so a released target or the
    // `Draw.RenderTexture.stub` a pure test holds reads the same either way.
    const resource = render_texture_heap.get(source.target.handle.*) orelse {
        err.* = capture.err_target_unavailable;
        return null;
    };
    const target = switch (resource.*) {
        // A headless target holds nothing: every draw into it was a no-op, so
        // there is no colour to invent for the app.
        .headless => {
            err.* = capture.err_unavailable;
            return null;
        },
        .native => |native| native,
    };
    if (headlessMode()) {
        err.* = capture.err_unavailable;
        return null;
    }

    // The target's own dimensions rather than the ones the Roc value carries,
    // for the reason `Capture.screenshot_texture!` gives: the readback is
    // sized by what the GPU holds. A target too large for the whole budget and
    // one that would fit but for other work in flight are both `err_busy`
    // here; a readback reports one "not now" and the difference between them
    // is in the documentation rather than in the tag.
    var reserved: u64 = 0;
    if (still_budget.admit(
        @intCast(@max(target.texture.width, 0)),
        @intCast(@max(target.texture.height, 0)),
        &reserved,
    ) != capture.err_none) {
        err.* = capture.err_busy;
        return null;
    }

    const image = raylib.readRenderTexture(target) orelse {
        still_budget.release(reserved);
        err.* = capture.err_readback_failed;
        return null;
    };
    return .{
        .bytes = image.pixels(),
        .width = image.width(),
        .height = image.height(),
        .image = image,
        .reserved = reserved,
    };
}

fn pixelReadFailure(err: u8) abi.HostABICapture_pixel_atRetRecord {
    return .{ .err = err, .r = 0, .g = 0, .b = 0, .a = 0 };
}

/// `Capture.pixel_at!`: one pixel's colour, with nothing allocated to carry it.
///
/// Synchronous rather than waiting. The screen comes from a snapshot the host
/// already holds and a render target is read through the graphics context this
/// thread owns, so there is nothing here to park on.
fn hostedCapturePixelAt(roc_host: *RocHost, args: abi.HostABICapture_pixel_atArgs) abi.HostABICapture_pixel_atRetRecord {
    enforcePhase("Capture.pixel_at!", during_update);
    var effect = EffectScope.begin("Capture.pixel_at!", 0);
    defer effect.end();
    defer releaseResourceBox(roc_host, args.source.target.handle);

    var err: u8 = capture.err_readback_failed;
    const pixels = resolveReadbackSource(args.source, &err) orelse return pixelReadFailure(err);
    defer pixels.deinit();

    const bounds = capture.validatePoint(args.x, args.y, pixels.width, pixels.height);
    if (bounds != capture.err_none) return pixelReadFailure(bounds);

    const channels = capture.pixelAt(pixels.bytes, pixels.width, args.x, args.y);
    effect.setDrawMetrics(1, 4);
    return .{ .err = capture.err_none, .r = channels[0], .g = channels[1], .b = channels[2], .a = channels[3] };
}

fn exportedCapturePixelAt(args: abi.HostABICapture_pixel_atArgs) callconv(.c) abi.HostABICapture_pixel_atRetRecord {
    return hostedCapturePixelAt(activeHost(), args);
}

/// `Capture.read_region!`: a rectangle of RGBA8 bytes, handed over rather than
/// copied.
///
/// The order of the checks is the point. A region no source could satisfy is
/// refused before anything is read, and a delivery slot is reserved before the
/// readback, so the expensive part never runs for a read that has nowhere to
/// put its answer -- the same admission `Files.read_bytes!` does before it
/// opens a path, and for the same reason.
fn hostedCaptureReadRegion(roc_host: *RocHost, args: abi.HostABICapture_read_regionArgs) abi.HostABICapture_read_regionRetRecord {
    enforcePhase("Capture.read_region!", during_update);
    var effect = EffectScope.begin("Capture.read_region!", 0);
    defer effect.end();
    defer releaseResourceBox(roc_host, args.source.target.handle);

    const empty = abi.RocListWith(u8, false).empty();
    const region = capture.Region{ .x = args.x, .y = args.y, .width = args.width, .height = args.height };

    const bytes = capture.regionBytes(region) orelse
        return .{ .err = capture.err_region_out_of_bounds, .bytes = empty };
    if (bytes > capture.max_readback_bytes)
        return .{ .err = capture.err_region_out_of_bounds, .bytes = empty };

    if (!file_bytes_delivery_reservations.reserve()) return .{ .err = capture.err_busy, .bytes = empty };
    defer file_bytes_delivery_reservations.release();

    var err: u8 = capture.err_readback_failed;
    const pixels = resolveReadbackSource(args.source, &err) orelse return .{ .err = err, .bytes = empty };
    defer pixels.deinit();

    const bounds = capture.validateRegion(region, pixels.width, pixels.height);
    if (bounds != capture.err_none) return .{ .err = bounds, .bytes = empty };

    const allocator = allocatorFromHost(roc_host);
    const copy = allocator.alloc(u8, @intCast(bytes)) catch
        return .{ .err = capture.err_busy, .bytes = empty };
    capture.copyRegion(copy, pixels.bytes, pixels.width, region);

    // The transfer itself, shared with every other handed-over byte list. Its
    // only refusal is a full heap, which is the same "no slot" this call
    // already reserved against and reports as `Busy`.
    const installed = installReadBytes(allocator, copy);
    if (installed.err != 0) return .{ .err = capture.err_busy, .bytes = empty };
    effect.addOwnershipTransferBytes(@intCast(bytes));
    effect.setDrawMetrics(@as(u64, @intCast(args.width)) *| @as(u64, @intCast(args.height)), bytes);
    return .{ .err = capture.err_none, .bytes = installed.bytes };
}

fn exportedCaptureReadRegion(args: abi.HostABICapture_read_regionArgs) callconv(.c) abi.HostABICapture_read_regionRetRecord {
    return hostedCaptureReadRegion(activeHost(), args);
}

/// Which of the two byte-list producing waits to run. They share everything
/// after the syscall: the same admission, the same ownership transfer, and the
/// same list on the way out.
const ByteListWait = enum { read, list };

fn readByteListWaiting(roc_host: *RocHost, path: []const u8, kind: ByteListWait) abi.HostABIFiles_read_bytesRetRecord {
    const empty = abi.RocListWith(u8, false).empty();
    // Reserve before any filesystem work starts. A terminal `Busy` here means
    // precisely that nothing was read.
    if (!file_bytes_delivery_reservations.reserve()) {
        return .{ .err = READ_ERR_BUSY, .bytes = empty };
    }
    defer file_bytes_delivery_reservations.release();

    const allocator = allocatorFromHost(roc_host);
    const bytes = switch (kind) {
        .read => blk: {
            var err: u8 = READ_ERR_FAILED;
            break :blk readFileWaiting(allocator, path, MAX_FILE_READ_BYTES + 1, &err) orelse
                return .{ .err = err, .bytes = empty };
        },
        .list => blk: {
            const scope = WaitScope.enter();
            defer scope.leave();
            const park = AppTasks.observePark("list", 0);
            defer AppTasks.observeResume(park, "list");
            var encoded: ?[]u8 = null;
            const err = encodeListing(waitingIo(), allocator, path, &encoded);
            break :blk encoded orelse return .{
                .err = if (err == 0) READ_ERR_FAILED else err,
                .bytes = empty,
            };
        },
    };

    return installReadBytes(allocator, bytes);
}

/// Move an owned buffer into a typed heap slot and hand it back as an owning
/// seamless `List(U8)`.
///
/// Its allocation pointer is the typed heap payload, one word after the slot
/// refcount, exactly where Roc list ARC expects it. The seamless tag prevents
/// reusing or resizing the backing allocation, but a unique List operation may
/// still mutate visible elements in place. Safety comes from the complete
/// transfer: the host never reads or shares these bytes afterwards, while
/// sublists retain the one allocation.
///
/// An empty read becomes the canonical empty list rather than occupying a slot,
/// and a full heap frees the buffer and reports `Busy` -- the read happened,
/// but there is nowhere to hand it over.
fn installReadBytes(allocator: std.mem.Allocator, bytes: []u8) abi.HostABIFiles_read_bytesRetRecord {
    const empty = abi.RocListWith(u8, false).empty();
    if (bytes.len == 0) {
        allocator.free(bytes);
        return .{ .err = 0, .bytes = empty };
    }
    const resource = file_bytes_heap.insert(0, .{ .allocator = allocator, .bytes = bytes }) orelse {
        allocator.free(bytes);
        return .{ .err = READ_ERR_BUSY, .bytes = empty };
    };
    return .{ .err = 0, .bytes = seamlessByteList(resource, bytes) };
}

/// `Http.send!`: run one HTTP exchange, parking the task while it waits.
///
/// The phase handling mirrors `hostedTaskSleep`: the request parks this
/// coroutine, the frame loop runs in between and sets phases of its own, and
/// the task must see `.task` again when the response arrives.
fn hostedHttpSend(request: http_effect.Request) callconv(.c) http_effect.Response {
    enforcePhase("Http.send!", during_wait);
    var effect = EffectScope.begin("Http.send!", 0);
    defer effect.end();
    const roc_host = activeHost();
    const resume_phase = active_phase;
    active_phase = .idle;
    defer active_phase = resume_phase;
    const external_started = observatoryMeasurementStart();
    const result = http_effect.send(roc_host, allocatorFromHost(roc_host), request);
    effect.setExternalElapsed(external_started);
    if (result.err != 0) effect.setOutcome(.runtime_error);
    return result;
}

/// This process's own environment, as `std.process.Environ`.
///
/// `Cmd.run!` needs it twice over: it is where a bare program name is resolved
/// against `PATH`, and it is what a child inherits unless the command replaces
/// it. `host_environ` is what `platform_main` captured off the process stack;
/// under `zig test` no `platform_main` ran, so the libc-linked test binary
/// reads the C runtime's own global instead of running the tests against an
/// empty environment.
fn hostProcessEnviron() std.process.Environ {
    if (comptime builtin.os.tag == .windows) return .{ .block = .global };
    if (host_environ.len != 0) {
        const entries: [*:null]const ?[*:0]const u8 = @ptrCast(host_environ.ptr);
        return .{ .block = .{ .slice = entries[0..host_environ.len :null] } };
    }
    if (comptime builtin.link_libc) {
        var count: usize = 0;
        while (std.c.environ[count] != null) : (count += 1) {}
        const entries: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        return .{ .block = .{ .slice = entries[0..count :null] } };
    }
    return .empty;
}

/// A run that started no child, carrying only its code.
fn cmdRunFailure(code: u8) abi.HostABICmd_runRetRecord {
    return .{
        .err = code,
        .exit_code = 0,
        .stdout = abi.RocListWith(u8, false).empty(),
        .stderr = abi.RocListWith(u8, false).empty(),
    };
}

/// Copy the command out of the Roc record into host-owned storage.
///
/// The copy is the point: the child runs on a blocking-pool worker, and a
/// worker may not read a Roc value. Everything it needs -- the program, the
/// arguments, the environment pairs, the working directory -- is duplicated
/// into an arena the frame thread owns and discards when the run returns.
fn copyCmdSpec(arena: std.mem.Allocator, args: abi.HostABICmd_runArgs) ?cmd_effect.Spec {
    const program = arena.dupe(u8, args.program.asSlice()) catch return null;
    const working_dir = arena.dupe(u8, args.working_dir.asSlice()) catch return null;

    const arg_items = args.args.items();
    const copied_args = arena.alloc([]const u8, arg_items.len) catch return null;
    for (arg_items, copied_args) |item, *slot| {
        slot.* = arena.dupe(u8, item.asSlice()) catch return null;
    }

    const env_items = args.envs.items();
    const copied_envs = arena.alloc(cmd_effect.EnvPair, env_items.len) catch return null;
    for (env_items, copied_envs) |item, *slot| {
        slot.* = .{
            .name = arena.dupe(u8, item.name.asSlice()) catch return null,
            .value = arena.dupe(u8, item.value.asSlice()) catch return null,
        };
    }

    return .{
        .program = program,
        .args = copied_args,
        .envs = copied_envs,
        .clear_envs = args.clear_envs,
        .working_dir = working_dir,
        .timeout_ms = args.timeout_ms,
        .stdout_limit_bytes = args.stdout_limit_bytes,
        .stderr_limit_bytes = args.stderr_limit_bytes,
    };
}

/// `Cmd.run!`: start one child process and park until it has finished.
///
/// A child slot is reserved before anything is copied or started, so a
/// terminal `Busy` means precisely that no process was created.
///
/// The child itself runs through `std.Io.Threaded` on zio's blocking pool
/// rather than through the runtime's own backend, for the same reason
/// `writeFileWaiting` does: process creation and reaping are what that backend
/// does not implement everywhere. The pool parks this coroutine the way the
/// event loop would, and the worker sees only the host-owned copy `copyCmdSpec`
/// made.
///
/// Both streams cross as ordinary copies rather than through the byte-list
/// transfer path. A run produces two payloads where that path hands over one
/// allocation per slot, and both are already bounded by limits the app stated.
fn hostedCmdRun(roc_host: *RocHost, args: abi.HostABICmd_runArgs) callconv(.c) abi.HostABICmd_runRetRecord {
    enforcePhase("Cmd.run!", during_wait);
    var effect = EffectScope.begin("Cmd.run!", 0);
    defer effect.end();
    defer args.decref(roc_host);

    if (!cmd_effect.reserve()) {
        effect.setOutcome(.refused);
        return cmdRunFailure(cmd_effect.ERR_BUSY);
    }
    defer cmd_effect.release();

    const allocator = allocatorFromHost(roc_host);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const spec = copyCmdSpec(arena_state.allocator(), args) orelse
        {
            effect.setOutcome(.runtime_error);
            return cmdRunFailure(cmd_effect.ERR_SPAWN_FAILED);
        };

    const environ = hostProcessEnviron();
    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("cmd", spec.timeout_ms);
    defer AppTasks.observeResume(park, "cmd");

    const worker_started = observatoryMeasurementStart();
    const outcome = outcome: {
        // No runtime means `init!` on a host whose task runtime never started,
        // so the child runs inline the way a file write does there.
        const rt = AppTasks.currentRuntime() orelse
            break :outcome cmd_effect.run(allocator, environ, spec);
        // A pool that would not take the work is reported rather than run
        // here: this is the frame thread, and a command may wait a deadline
        // the app chose to be as long as it likes.
        var blocking = rt.spawnBlocking(cmd_effect.run, .{ allocator, environ, spec }) catch
            break :outcome cmd_effect.Outcome{
                .err = cmd_effect.ERR_SPAWN_FAILED,
                .exit_code = 0,
                .stdout = &.{},
                .stderr = &.{},
            };
        break :outcome blocking.join();
    };
    effect.setWorkerElapsed(worker_started);
    defer outcome.deinit(allocator);
    if (outcome.err != 0) effect.setOutcome(.runtime_error);

    return .{
        .err = outcome.err,
        .exit_code = outcome.exit_code,
        .stdout = abi.RocListWith(u8, false).fromSlice(outcome.stdout, roc_host),
        .stderr = abi.RocListWith(u8, false).fromSlice(outcome.stderr, roc_host),
    };
}

fn exportedCmdRun(args: abi.HostABICmd_runArgs) callconv(.c) abi.HostABICmd_runRetRecord {
    return hostedCmdRun(activeHost(), args);
}

/// `Udp.bind!`: open one IPv4 UDP socket and put it in the socket heap.
///
/// Binding does not wait for anything -- it makes a descriptor -- so this is an
/// ordinary effect rather than a waiting one, and an app can start networking
/// from `update!` when the player asks it to rather than having to spawn a task
/// for it. The one subtlety is that reaching the event loop to submit the bind
/// can hand a turn to the executor, which runs other tasks' Roc code; the
/// `PhaseScope` restore is what keeps the rest of this `update!` in the right
/// phase afterwards, exactly as `Task.spawn!` does.
fn hostedUdpBind(host: *RocHost, args: abi.HostABIUdp_bindArgs) callconv(.c) abi.HostABIUdp_bindRetRecord {
    enforcePhase("Udp.bind!", during_load);
    var effect = EffectScope.begin("Udp.bind!", args.ip.asSlice().len);
    defer effect.end();
    defer args.decref(host);
    const scope = PhaseScope.enter(active_phase);
    defer scope.leave();

    const ip = udp_effect.parseIp4(args.ip.asSlice()) orelse {
        effect.setOutcome(.runtime_error);
        return udpBindFailure(udp_effect.ERR_INVALID_ADDRESS);
    };

    const socket = switch (udp_effect.bind(ip, args.port)) {
        .ok => |value| value,
        .err => |code| {
            effect.setOutcome(.runtime_error);
            return udpBindFailure(code);
        },
    };

    // The descriptor exists before its slot does, so a full heap closes it
    // again rather than leaking it. `insert` finishes its own heap's
    // outstanding destruction first, so a socket the app has already released
    // is reclaimed here; nothing reaches for the global retirement drain,
    // which would put a GPU or audio-device call inside this `update!`.
    const handle = udp_socket_heap.insert(0, socket) orelse {
        var rejected = socket;
        destroyUdpSocket(&rejected);
        effect.setOutcome(.refused);
        return udpBindFailure(udp_effect.ERR_RESOURCE_LIMIT);
    };
    return .{
        .handle = handle,
        .ip = socket.local_ip,
        .port = socket.local_port,
        .err = 0,
    };
}

fn exportedUdpBind(args: abi.HostABIUdp_bindArgs) callconv(.c) abi.HostABIUdp_bindRetRecord {
    return hostedUdpBind(activeHost(), args);
}

/// A bind that produced no socket. The handle is the shared invalid token, so
/// `Udp` still gets a structurally valid value to discard.
fn udpBindFailure(code: u8) abi.HostABIUdp_bindRetRecord {
    return .{ .handle = invalidResourceHandle(), .ip = 0, .port = 0, .err = code };
}

/// `Udp.send!`: hand one datagram to the kernel, without waiting.
///
/// No `WaitScope` and no event loop: `udp_effect.send` issues the syscall
/// straight at the non-blocking descriptor. That is what makes this legal in
/// `update!` -- there is no park for the frame to pay for, and no window in
/// which another task's Roc code could run in the middle of an update.
fn hostedUdpSend(host: *RocHost, args: abi.HostABIUdp_sendArgs) callconv(.c) u8 {
    enforcePhase("Udp.send!", during_update);
    var effect = EffectScope.begin("Udp.send!", args.ip.asSlice().len +| args.bytes.items().len);
    defer effect.end();
    defer args.decref(host);

    const validation_started = observatoryMeasurementStart();
    const socket = udp_socket_heap.get(args.socket.*) orelse {
        effect.setValidationElapsed(validation_started);
        effect.setOutcome(.refused);
        return udp_effect.ERR_UNAVAILABLE;
    };
    const ip = udp_effect.parseIp4(args.ip.asSlice()) orelse {
        effect.setValidationElapsed(validation_started);
        effect.setOutcome(.runtime_error);
        return udp_effect.ERR_INVALID_ADDRESS;
    };
    effect.setValidationElapsed(validation_started);
    const external_started = observatoryMeasurementStart();
    const result = udp_effect.send(socket, ip, args.port, args.bytes.items());
    effect.setExternalElapsed(external_started);
    if (result != 0) effect.setOutcome(.runtime_error);
    return result;
}

fn exportedUdpSend(args: abi.HostABIUdp_sendArgs) callconv(.c) u8 {
    return hostedUdpSend(activeHost(), args);
}

/// `Udp.receive!`: park until a datagram arrives, then deliver the batch.
///
/// The phase handling mirrors `hostedTaskSleep`: the receive parks this
/// coroutine, the frame loop runs in between and sets phases of its own, and
/// the task must see `.task` again when the datagrams arrive.
///
/// The batch is built in host memory first and copied into Roc values only
/// once it is complete, so a cancelled or failed receive cannot leave a
/// half-built Roc value behind.
fn hostedUdpReceive(host: *RocHost, args: abi.HostABIUdp_receiveArgs) callconv(.c) abi.HostABIUdp_receiveRetRecord {
    enforcePhase("Udp.receive!", during_wait);
    var effect = EffectScope.begin("Udp.receive!", 0);
    defer effect.end();
    defer args.decref(host);

    const socket = udp_socket_heap.get(args.socket.*) orelse {
        effect.setOutcome(.refused);
        return udpReceiveFailure(udp_effect.ERR_UNAVAILABLE);
    };

    const allocator = allocatorFromHost(host);
    var slices: std.ArrayList(udp_effect.Slice) = .empty;
    defer slices.deinit(allocator);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("udp receive", args.timeout_ms);
    const external_started = observatoryMeasurementStart();
    const outcome = udp_effect.receive(
        socket,
        args.timeout_ms,
        args.max_datagrams,
        &slices,
        &payload,
        allocator,
    );
    effect.setExternalElapsed(external_started);
    AppTasks.observeResume(park, "udp receive");

    const batch = switch (outcome) {
        .ok => |value| value,
        .err => |code| {
            effect.setOutcome(.runtime_error);
            return udpReceiveFailure(code);
        },
    };
    const conversion_started = observatoryMeasurementStart();
    const result: abi.HostABIUdp_receiveRetRecord = .{
        .err = 0,
        .payload = abi.RocListWith(u8, false).fromSlice(batch.payload, host),
        .slices = udpRocSlices(host, batch.slices),
    };
    effect.setConversionElapsed(conversion_started);
    return result;
}

fn exportedUdpReceive(args: abi.HostABIUdp_receiveArgs) callconv(.c) abi.HostABIUdp_receiveRetRecord {
    return hostedUdpReceive(activeHost(), args);
}

/// A receive that produced no datagrams, carrying only its code.
fn udpReceiveFailure(code: u8) abi.HostABIUdp_receiveRetRecord {
    return .{
        .err = code,
        .payload = abi.RocListWith(u8, false).empty(),
        .slices = abi.RocListWith(abi.HostABIUdp_receiveSlices, false).empty(),
    };
}

/// Copy the batch index into the Roc list `Udp` decodes.
fn udpRocSlices(
    host: *RocHost,
    slices: []const udp_effect.Slice,
) abi.RocListWith(abi.HostABIUdp_receiveSlices, false) {
    if (slices.len == 0) return abi.RocListWith(abi.HostABIUdp_receiveSlices, false).empty();
    const list = abi.RocListWith(abi.HostABIUdp_receiveSlices, false).allocate(slices.len, host);
    const elements = list.elements_ptr.?;
    for (slices, 0..) |slice, index| {
        elements[index] = .{
            .ip = slice.ip,
            .port = slice.port,
            .start = slice.start,
            .len = slice.len,
        };
    }
    return list;
}

/// The `Sqlite` effects.
///
/// Each one waits: the query runs on zio's blocking pool and this coroutine
/// parks in `join()`, so the frame loop keeps running. The phase handling
/// mirrors `hostedHttpSend` -- the frame loop enters phases of its own while
/// this is parked, so the task must see its own phase again when the answer
/// arrives. Roc's own arguments are decref'd here; everything a worker reads
/// was copied out of them first.
fn hostedSqliteOpen(
    path_arg: abi.RocStr,
    mode: u8,
    busy_timeout_ms: u64,
    max_result_bytes: u64,
) callconv(.c) abi.HostABISqlite_open {
    enforcePhase("Sqlite.Db.open!", during_wait);
    var effect = EffectScope.begin("Sqlite.Db.open!", path_arg.asSlice().len);
    defer effect.end();
    const roc_host = activeHost();
    defer path_arg.decref(roc_host);
    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("sqlite.open", 0);
    defer AppTasks.observeResume(park, "sqlite.open");
    const worker_started = observatoryMeasurementStart();
    const result = sqlite_effect.open(
        roc_host,
        AppTasks.currentRuntime(),
        path_arg,
        mode,
        busy_timeout_ms,
        max_result_bytes,
    );
    effect.setWorkerElapsed(worker_started);
    if (result.err != 0) effect.setOutcome(.runtime_error);
    return result;
}

fn hostedSqliteClose(db_arg: *u64) callconv(.c) abi.HostABISqlite_close {
    enforcePhase("Sqlite.Db.close!", during_wait);
    var effect = EffectScope.begin("Sqlite.Db.close!", 0);
    defer effect.end();
    const roc_host = activeHost();
    defer releaseResourceBox(roc_host, db_arg);
    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("sqlite.close", 0);
    defer AppTasks.observeResume(park, "sqlite.close");
    const worker_started = observatoryMeasurementStart();
    const result = sqlite_effect.close(roc_host, AppTasks.currentRuntime(), db_arg);
    effect.setWorkerElapsed(worker_started);
    if (result.err != 0) effect.setOutcome(.runtime_error);
    return result;
}

fn hostedSqlitePrepare(db_arg: *u64, sql_arg: abi.RocStr) callconv(.c) abi.HostABISqlite_prepare {
    enforcePhase("Sqlite.prepare!", during_wait);
    var effect = EffectScope.begin("Sqlite.prepare!", sql_arg.asSlice().len);
    defer effect.end();
    const roc_host = activeHost();
    defer releaseResourceBox(roc_host, db_arg);
    defer sql_arg.decref(roc_host);
    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("sqlite.prepare", 0);
    defer AppTasks.observeResume(park, "sqlite.prepare");
    const worker_started = observatoryMeasurementStart();
    const result = sqlite_effect.prepare(roc_host, AppTasks.currentRuntime(), db_arg, sql_arg);
    effect.setWorkerElapsed(worker_started);
    if (result.err != 0) effect.setOutcome(.runtime_error);
    return result;
}

fn hostedSqliteRunStmt(
    stmt_arg: *u64,
    bindings_arg: abi.RocList(abi.HostABISqlite_run_stmtArg1),
) callconv(.c) abi.HostABISqlite_run_stmt {
    enforcePhase("Sqlite.Stmt.query!", during_wait);
    var effect = EffectScope.begin("Sqlite.Stmt.query!", 0);
    defer effect.end();
    const roc_host = activeHost();
    defer releaseResourceBox(roc_host, stmt_arg);
    defer abi.decrefListOf__AnonStruct_90c9f98ccd96f8ce(bindings_arg, roc_host);
    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("sqlite.run", 0);
    defer AppTasks.observeResume(park, "sqlite.run");
    const worker_started = observatoryMeasurementStart();
    const result = sqlite_effect.runStmt(roc_host, AppTasks.currentRuntime(), stmt_arg, bindings_arg);
    effect.setWorkerElapsed(worker_started);
    if (result.err != 0) effect.setOutcome(.runtime_error);
    return result;
}

fn hostedSqliteRunOnce(
    db_arg: *u64,
    sql_arg: abi.RocStr,
    bindings_arg: abi.RocList(abi.HostABISqlite_run_stmtArg1),
) callconv(.c) abi.HostABISqlite_run_once {
    enforcePhase("Sqlite.query!", during_wait);
    var effect = EffectScope.begin("Sqlite.query!", sql_arg.asSlice().len);
    defer effect.end();
    const roc_host = activeHost();
    defer releaseResourceBox(roc_host, db_arg);
    defer sql_arg.decref(roc_host);
    defer abi.decrefListOf__AnonStruct_90c9f98ccd96f8ce(bindings_arg, roc_host);
    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("sqlite.run", 0);
    defer AppTasks.observeResume(park, "sqlite.run");
    const worker_started = observatoryMeasurementStart();
    const result = sqlite_effect.runOnce(roc_host, AppTasks.currentRuntime(), db_arg, sql_arg, bindings_arg);
    effect.setWorkerElapsed(worker_started);
    if (result.err != 0) effect.setOutcome(.runtime_error);
    return result;
}

fn hostedSqliteExecScript(db_arg: *u64, sql_arg: abi.RocStr) callconv(.c) abi.HostABISqlite_exec_script {
    enforcePhase("Sqlite.exec_script!", during_wait);
    var effect = EffectScope.begin("Sqlite.exec_script!", sql_arg.asSlice().len);
    defer effect.end();
    const roc_host = activeHost();
    defer releaseResourceBox(roc_host, db_arg);
    defer sql_arg.decref(roc_host);
    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("sqlite.script", 0);
    defer AppTasks.observeResume(park, "sqlite.script");
    const worker_started = observatoryMeasurementStart();
    const result = sqlite_effect.execScript(roc_host, AppTasks.currentRuntime(), db_arg, sql_arg);
    effect.setWorkerElapsed(worker_started);
    if (result.err != 0) effect.setOutcome(.runtime_error);
    return result;
}

var active_phase: Phase = .idle;

/// Enter a phase for one call, restoring the prior phase to preserve nesting.
const PhaseScope = struct {
    previous: Phase,
    previous_trace_owner: u32,
    trace_owner: u32,

    fn enter(phase: Phase) PhaseScope {
        const previous = active_phase;
        const previous_trace_owner = active_trace_owner;
        const trace_owner = if (previous == .idle and phase != .idle) beginTraceOwner() else active_trace_owner;
        const scope = PhaseScope{ .previous = previous, .previous_trace_owner = previous_trace_owner, .trace_owner = trace_owner };
        active_phase = phase;
        return scope;
    }

    fn leave(self: PhaseScope) void {
        if (self.previous == .idle and self.trace_owner != 0) finishTraceOwner(self.trace_owner);
        active_phase = self.previous;
        active_trace_owner = self.previous_trace_owner;
    }
};

/// The rejection a phase guard produced, recorded instead of aborting in tests.
const PhaseViolation = struct { operation: []const u8, allowed: PhaseSet, actual: Phase };
var last_phase_violation: ?PhaseViolation = null;

/// Name the phases an operation was allowed in, for a rejection message.
fn describePhases(allowed: PhaseSet, buffer: []u8) []const u8 {
    var written: usize = 0;
    var iterator = allowed.iterator();
    while (iterator.next()) |phase| {
        const separator = if (written == 0) "" else " or ";
        const printed = std.fmt.bufPrint(buffer[written..], "{s}{s}", .{ separator, phase.label() }) catch break;
        written += printed.len;
    }
    return buffer[0..written];
}

/// Refuse an operation reached from the wrong callback phase.
///
/// A blocking loader during a frame violates the frame-time contract, while a
/// draw outside `render!` reaches raylib outside its drawing scope. Both are
/// programming errors and abort in every non-test build.
///
/// Under `zig test` the violation is recorded rather than raised: the unit
/// tests call hosted effects directly, with no callback entered, and aborting
/// the runner would make the guard itself untestable.
fn enforcePhase(operation: []const u8, allowed: PhaseSet) void {
    if (allowed.contains(active_phase)) {
        // A draw summary counts accepted public Draw effects, including scope
        // changes and frame queries. It is a boundary-crossing summary, not a
        // claim about backend batches or GPU draw calls.
        if ((active_observatory != null or (builtin.is_test and observatory_task_detail)) and active_phase == .render and allowed.eql(during_render) and std.mem.startsWith(u8, operation, "Draw.")) {
            observatory_draw_calls +|= 1;
        }
        return;
    }
    last_phase_violation = .{ .operation = operation, .allowed = allowed, .actual = active_phase };
    if (comptime builtin.is_test) return;
    var buffer: [160]u8 = undefined;
    std.debug.panic("roc-ray: {s} is only valid during {s}, but it was called during {s}.{s}", .{
        operation,
        describePhases(allowed, &buffer),
        active_phase.label(),
        if (allowed.eql(during_startup))
            " It is an App.Startup capability: call it in init! and keep what it returns in your model."
        else if (allowed.eql(during_update))
            " It changes host state rather than drawing: call it from init!, update!, or a task, not from render!."
        else if (allowed.eql(during_render))
            " Drawing is only defined inside the frame scope the host opens around render!."
        else if (allowed.eql(during_spawn))
            " Deferred work answers on a later input: start it from update! or from another task."
        else if (allowed.eql(during_wait))
            " It waits: call it inside Task.spawn!, where it parks the task, or in init!, where it blocks."
        else if (allowed.eql(during_frame_wait))
            " It waits for the end of a frame, so it only works inside Task.spawn!: init! runs before the first frame is drawn."
        else
            "",
    });
}

test "draw summary counts accepted public draw boundary calls only" {
    const previous = observatory_draw_calls;
    defer observatory_draw_calls = previous;
    const previous_detail = observatory_task_detail;
    defer observatory_task_detail = previous_detail;
    observatory_task_detail = true;
    observatory_draw_calls = 0;
    const phase = PhaseScope.enter(.render);
    defer phase.leave();

    enforcePhase("Draw.circle!", during_render);
    const effect = EffectScope.begin("Draw.circle!", 0);
    defer effect.end();
    enforcePhase("Draw.frame_size!", during_render);
    enforcePhase("Trace.mark!", diagnostic_anywhere);
    try std.testing.expectEqual(@as(u64, 2), observatory_draw_calls);
}

const TRACE_LABEL_MAX_BYTES: usize = 255;
const TRACE_ZONE_DEPTH: usize = 64;
const TRACE_TRACK_CAPACITY: usize = tasks_mod.max_live_tasks + 2;

const TraceZoneEntry = struct {
    token: u64,
    started_ns: u64,
    parked_ns: u64 = 0,
    label_len: u8,
    label: [TRACE_LABEL_MAX_BYTES]u8,
};
const TraceTrack = struct {
    owner: u32 = 0,
    depth: u8 = 0,
    cancelling: bool = false,
    zones: [TRACE_ZONE_DEPTH]TraceZoneEntry = undefined,
};
var trace_tracks: [TRACE_TRACK_CAPACITY]TraceTrack = [_]TraceTrack{.{}} ** TRACE_TRACK_CAPACITY;
var active_trace_owner: u32 = 0;
var next_trace_owner: u32 = 1;
var next_trace_token: u32 = 1;
var last_trace_violation: ?[]const u8 = null;
const TaskTraceOwner = struct { task_id: u64 = 0, owner: u32 = 0 };
var task_trace_owners: [tasks_mod.max_live_tasks]TaskTraceOwner = [_]TaskTraceOwner{.{}} ** tasks_mod.max_live_tasks;

fn rememberTaskTraceOwner(task_id: u64, owner: u32) void {
    if (task_id == 0) return;
    for (&task_trace_owners) |*entry| if (entry.task_id == 0) {
        entry.* = .{ .task_id = task_id, .owner = owner };
        return;
    };
    traceProgrammerError("no bounded task annotation owner slot is available");
}

fn forgetTaskTraceOwner(task_id: u64) void {
    for (&task_trace_owners) |*entry| if (entry.task_id == task_id) {
        entry.* = .{};
        return;
    };
}

fn abortTaskTraceOwner(task_id: u64, session: *observatory.Session) void {
    for (&task_trace_owners) |*mapping| {
        if (mapping.task_id != task_id) continue;
        const track = traceTrack(mapping.owner, false) orelse {
            mapping.* = .{};
            return;
        };
        const ended_ns = traceNowNs();
        while (track.depth != 0) {
            const entry = &track.zones[track.depth - 1];
            const durations = traceZoneDurations(entry.started_ns, entry.parked_ns, ended_ns);
            _ = session.recordAnnotation(.{
                .cycle = observatory_cycle,
                .timestamp_ns = ended_ns,
                .phase = @intFromEnum(Phase.task),
                .kind = .zone_abort,
                .name = entry.label[0..entry.label_len],
                .integer = @bitCast(entry.token),
                .wall_ns = durations.wall,
                .active_ns = durations.active,
                .parked_ns = durations.parked,
            });
            track.depth -= 1;
        }
        // Keep the bounded track until cancellation has unwound the Roc task.
        // Cleanup may call `Trace.end!` for the zones just recorded as aborted;
        // those calls acknowledge cancellation rather than double-end a zone.
        track.cancelling = true;
        mapping.* = .{};
        return;
    }
}

fn traceProgrammerError(message: []const u8) void {
    last_trace_violation = message;
    if (!builtin.is_test) std.debug.panic("roc-ray: invalid Trace annotation: {s}", .{message});
}

fn beginTraceOwner() u32 {
    const owner = next_trace_owner;
    next_trace_owner +%= 1;
    if (next_trace_owner == 0) next_trace_owner = 1;
    active_trace_owner = owner;
    return owner;
}

fn traceTrack(owner: u32, create: bool) ?*TraceTrack {
    for (&trace_tracks) |*track| if (track.owner == owner) return track;
    if (!create) return null;
    for (&trace_tracks) |*track| {
        if (track.owner == 0) {
            track.owner = owner;
            track.depth = 0;
            track.cancelling = false;
            return track;
        }
    }
    traceProgrammerError("no bounded annotation track is available");
    return null;
}

fn finishTraceOwner(owner: u32) void {
    const track = traceTrack(owner, false) orelse return;
    if (track.depth != 0) traceProgrammerError("an annotation zone escaped its callback or task body");
    track.owner = 0;
    track.depth = 0;
    track.cancelling = false;
}

/// Charge one completed wait to every open zone for its callback/task owner.
/// Nested zones intentionally receive the same parked interval.
fn chargeTraceParked(owner: u32, duration_ns: u64) void {
    const track = traceTrack(owner, false) orelse return;
    for (track.zones[0..track.depth]) |*zone| zone.parked_ns +|= duration_ns;
}

fn traceZoneDurations(started_ns: u64, parked_ns: u64, ended_ns: u64) struct { wall: u64, active: u64, parked: u64 } {
    const wall = ended_ns -| started_ns;
    const parked = @min(parked_ns, wall);
    return .{ .wall = wall, .active = wall - parked, .parked = parked };
}

fn activeTraceZoneToken() u64 {
    const track = traceTrack(active_trace_owner, false) orelse return 0;
    if (track.depth == 0) return 0;
    return track.zones[track.depth - 1].token;
}

fn validateTraceLabel(label: abi.RocStr) bool {
    const bytes = label.asSlice();
    if (bytes.len > TRACE_LABEL_MAX_BYTES) {
        traceProgrammerError("annotation labels must be at most 255 UTF-8 bytes");
        return false;
    }
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        traceProgrammerError("annotation labels must be valid UTF-8");
        return false;
    }
    return true;
}

fn traceNowNs() u64 {
    if (observatory_origin_ns == 0) return 0;
    return @intCast(@max(std.Io.Clock.awake.now(mainThreadIo()).nanoseconds - observatory_origin_ns, 0));
}

var observatory_test_clock: ?*const fn () i96 = null;

fn observatoryAwakeNs() i96 {
    if (observatory_test_clock) |clock| return clock();
    return std.Io.Clock.awake.now(mainThreadIo()).nanoseconds;
}

/// Start an automatic Observatory interval only while a sink is installed.
/// This keeps the recorder's automatic clock sampling off every ordinary run.
fn observatoryMeasurementStart() i96 {
    if (active_observatory == null) return 0;
    return observatoryAwakeNs();
}

/// Start a high-volume sub-interval only when standard/full detail admits it.
fn observatoryDetailMeasurementStart() i96 {
    if (!observatory_task_detail) return 0;
    return observatoryMeasurementStart();
}

fn observatoryMeasurementElapsed(started_ns: i96) u64 {
    if (started_ns == 0 or active_observatory == null) return 0;
    return @intCast(@max(observatoryAwakeNs() - started_ns, 0));
}

fn traceEmit(kind: observatory.AnnotationKind, label: []const u8, integer: i64, real: f64, unit: u8) void {
    const session = active_observatory orelse return;
    _ = session.recordAnnotation(.{
        .cycle = observatory_cycle,
        .timestamp_ns = traceNowNs(),
        .phase = @intFromEnum(active_phase),
        .kind = kind,
        .name = label,
        .integer = integer,
        .real = real,
        .unit = unit,
    });
}

fn observeHostResource(event: host_resource.Observation) u64 {
    observatory_cycle_counts.resource +|= 1;
    // Per-use volume is already represented by the cycle counter. Persist
    // only lifecycle and capacity transitions at standard/full detail.
    if (event.operation == .use) return 0;
    if (!observatory_task_detail) return 0;
    const now = traceNowNs();
    const session = active_observatory orelse return now;
    const private_id = switch (event.operation) {
        .create => resourceCorrelation(event.subject_id, true),
        .saturation => 0,
        .retire, .destroy, .use, .reuse => resourceCorrelation(event.subject_id, false),
    };
    if (event.subject_id != 0 and private_id == 0) {
        session.noteLoss(.resource_lifecycle, 1);
        return now;
    }
    _ = session.recordResource(.{
        .cycle = observatory_cycle,
        .timestamp_ns = now,
        .kind = @intFromEnum(event.operation),
        .subject_id = private_id,
        .duration_ns = if (event.retired_at != 0) now -| event.retired_at else 0,
        .value_a = @intCast(event.active),
        .value_b = @intCast(event.high_water),
        .name = @tagName(event.kind),
    });
    if (event.operation == .destroy) forgetResourceCorrelation(event.subject_id);
    return now;
}

fn observeCommandQueue(event: cmd_effect.QueueObservation) u64 {
    observatory_cycle_counts.queue +|= 1;
    if (!observatory_task_detail) return 0;
    const now = traceNowNs();
    const session = active_observatory orelse return now;
    _ = session.recordQueue(.{
        .cycle = observatory_cycle,
        .timestamp_ns = now,
        .kind = @intFromEnum(event.operation),
        .subject_id = @intCast(event.high_water),
        .parent_id = @intCast(event.capacity),
        .duration_ns = if (event.oldest_at != 0) now -| event.oldest_at else 0,
        .value_a = @intCast(event.current),
        .value_b = @intCast(event.capacity),
        .name = "cmd children",
        .producer = switch (event.operation) {
            .release => .host_worker,
            .reserve, .saturation => .frame_thread,
        },
    });
    return now;
}

fn observeCaptureQueue(event: capture.StillBudget.QueueObservation) u64 {
    observatory_cycle_counts.queue +|= 1;
    if (!observatory_task_detail) return 0;
    const now = traceNowNs();
    const session = active_observatory orelse return now;
    _ = session.recordQueue(.{
        .cycle = observatory_cycle,
        .timestamp_ns = now,
        .kind = @intFromEnum(event.operation),
        .subject_id = event.high_water,
        .parent_id = event.capacity,
        .duration_ns = if (event.oldest_at != 0) now -| event.oldest_at else 0,
        .value_a = event.current,
        .value_b = event.amount,
        .name = "capture still bytes",
        .producer = switch (event.operation) {
            .release => .host_worker,
            .reserve, .saturation => .frame_thread,
        },
    });
    return now;
}

fn observeStdioQueue(event: stdio_effect.QueueObservation) void {
    observatory_cycle_counts.queue +|= 1;
    if (!observatory_task_detail) return;
    const session = active_observatory orelse return;
    const at: i96 = @intCast(event.timestamp_ns);
    _ = session.recordQueue(.{
        .cycle = observatory_cycle,
        .timestamp_ns = @intCast(@max(at - observatory_origin_ns, 0)),
        .kind = @intFromEnum(event.operation),
        .subject_id = event.high_water,
        .parent_id = event.capacity_bytes,
        .duration_ns = if (event.oldest_at_ns != 0) event.timestamp_ns -| event.oldest_at_ns else 0,
        .value_a = event.current,
        .value_b = event.amount,
        .name = if (event.stream == 0) "stdio stdout bytes" else "stdio stderr bytes",
        .producer = switch (event.operation) {
            .release => .host_worker,
            .reserve, .saturation => .frame_thread,
        },
    });
}

fn observeInputQueue(event: raylib.InputQueueObservation) u64 {
    observatory_cycle_counts.queue +|= 1;
    if (!observatory_task_detail) return 0;
    const now = traceNowNs();
    const session = active_observatory orelse return now;
    _ = session.recordQueue(.{
        .cycle = observatory_cycle,
        .timestamp_ns = now,
        .kind = @intFromEnum(event.operation),
        .subject_id = event.high_water,
        .parent_id = event.capacity,
        .duration_ns = if (event.oldest_at != 0) now -| event.oldest_at else 0,
        .value_a = event.current,
        .value_b = event.amount,
        .name = switch (event.buffer) {
            .hardware_events => "input hardware events",
            .virtual_events => "input virtual events",
            .text_codepoints => "input text codepoints",
        },
    });
    return now;
}

/// Record a lossy interval overflow distinctly from queue saturation. The
/// source only exposes that at least one item was lost, not an invented count.
fn recordInputOverflow(name: []const u8, retained: usize) void {
    const session = active_observatory orelse return;
    if (!observatory_task_detail) return;
    _ = session.recordQueue(.{
        .cycle = observatory_cycle,
        .timestamp_ns = traceNowNs(),
        .kind = 3,
        .value_a = @intCast(retained),
        .value_b = 1,
        .name = name,
    });
}

/// Brackets one hosted call after its phase check. `copied_bytes` counts bytes
/// copied across the boundary when the entry point can know that exactly;
/// zero means none or not measured, never an inferred payload size.
const EffectScope = struct {
    name: []const u8,
    phase: Phase,
    started_ns: i96,
    effect_id: u64,
    correlation_id: u64,
    inbound_copied_bytes: u64,
    outbound_copied_bytes: u64 = 0,
    ownership_transfer_bytes: u64 = 0,
    validation_ns: ?u64 = null,
    conversion_ns: ?u64 = null,
    worker_ns: ?u64 = null,
    external_ns: ?u64 = null,
    outcome: observatory.EffectOutcome = .success,
    active: bool,
    items: u64 = 1,
    draw_bytes: u64 = 0,
    draw_metrics_set: bool = false,
    is_draw: bool = false,
    draw_kind: ?u8 = null,

    fn begin(name: []const u8, inbound_copied_bytes: u64) EffectScope {
        const draw_kind = if (active_phase == .render) drawDetailKind(name) else null;
        const is_draw = draw_kind != null;
        if (active_observatory == null) {
            return .{ .name = name, .phase = active_phase, .started_ns = 0, .effect_id = 0, .correlation_id = 0, .inbound_copied_bytes = 0, .active = false, .is_draw = is_draw, .draw_kind = draw_kind };
        }
        if (!observatory_task_detail or (is_draw and !observatory_full_detail)) {
            // Summary needs only the scalar aggregate call count. It neither
            // assigns a detail identity nor samples the trace clock. Standard
            // treats draw calls the same way; their individual detail is full-only.
            return .{ .name = name, .phase = active_phase, .started_ns = 0, .effect_id = 0, .correlation_id = 0, .inbound_copied_bytes = 0, .active = true, .is_draw = is_draw, .draw_kind = draw_kind };
        }
        const effect_id = observatory_next_effect_id;
        observatory_next_effect_id +|= 1;
        return .{ .name = name, .phase = active_phase, .started_ns = observatoryAwakeNs(), .effect_id = effect_id, .correlation_id = active_trace_owner, .inbound_copied_bytes = inbound_copied_bytes, .active = true, .is_draw = is_draw, .draw_kind = draw_kind };
    }

    fn setOutcome(self: *EffectScope, outcome: observatory.EffectOutcome) void {
        self.outcome = outcome;
    }

    fn addCopiedBytes(self: *EffectScope, bytes: usize) void {
        self.outbound_copied_bytes +|= bytes;
    }

    fn addOwnershipTransferBytes(self: *EffectScope, bytes: usize) void {
        self.ownership_transfer_bytes +|= bytes;
    }

    /// Attach full draw detail derived from boundary structure, never payload.
    fn setDrawMetrics(self: *EffectScope, items: u64, bytes: u64) void {
        self.items = items;
        self.draw_bytes = bytes;
        self.draw_metrics_set = true;
    }

    fn drawValues(self: EffectScope) struct { items: u64, bytes: u64 } {
        return .{
            .items = self.items,
            .bytes = if (self.draw_metrics_set) self.draw_bytes else self.inbound_copied_bytes +| self.outbound_copied_bytes,
        };
    }

    fn setValidationElapsed(self: *EffectScope, started_ns: i96) void {
        if (self.active) self.validation_ns = observatoryMeasurementElapsed(started_ns);
    }

    fn setConversionElapsed(self: *EffectScope, started_ns: i96) void {
        if (self.active) self.conversion_ns = observatoryMeasurementElapsed(started_ns);
    }

    fn setWorkerElapsed(self: *EffectScope, started_ns: i96) void {
        if (self.active) self.worker_ns = observatoryMeasurementElapsed(started_ns);
    }

    fn setExternalElapsed(self: *EffectScope, started_ns: i96) void {
        if (self.active) self.external_ns = observatoryMeasurementElapsed(started_ns);
    }

    fn end(self: EffectScope) void {
        if (!self.active) return;
        observatory_cycle_counts.effect +|= 1;
        if (self.is_draw) {
            if (!observatory_full_detail) return;
            const kind = self.draw_kind.?;
            const session = active_observatory orelse return;
            const values = self.drawValues();
            _ = session.recordDraw(.{
                .cycle = observatory_cycle,
                .timestamp_ns = @intCast(@max(self.started_ns - observatory_origin_ns, 0)),
                .kind = kind,
                .duration_ns = @intCast(@max(observatoryAwakeNs() - self.started_ns, 0)),
                .value_a = values.items,
                .value_b = values.bytes,
                .name = self.name,
            });
            return;
        }
        if (!observatory_task_detail) return;
        const session = active_observatory orelse return;
        _ = session.recordEffect(.{
            .cycle = observatory_cycle,
            .timestamp_ns = @intCast(@max(self.started_ns - observatory_origin_ns, 0)),
            .kind = @intFromEnum(self.phase),
            .effect_id = self.effect_id,
            .correlation_id = self.correlation_id,
            .duration_ns = @intCast(@max(observatoryAwakeNs() - self.started_ns, 0)),
            .outcome = self.outcome,
            .inbound_copied_bytes = self.inbound_copied_bytes,
            .outbound_copied_bytes = self.outbound_copied_bytes,
            .ownership_transfer_bytes = self.ownership_transfer_bytes,
            .validation_ns = self.validation_ns,
            .conversion_ns = self.conversion_ns,
            .worker_ns = self.worker_ns,
            .external_ns = self.external_ns,
            .name = self.name,
        });
    }
};

fn drawByteCount(comptime Element: type, count: usize) u64 {
    return std.math.mul(u64, @intCast(count), @sizeOf(Element)) catch std.math.maxInt(u64);
}

/// Stable full-detail draw categories: primitive, batch, upload, state,
/// readback, and render-target change. Classification uses public effect names
/// only and never examines an application payload.
fn drawDetailKind(name: []const u8) ?u8 {
    if (std.mem.indexOf(u8, name, "read_region") != null or std.mem.indexOf(u8, name, "pixel_at") != null or std.mem.indexOf(u8, name, "screenshot") != null) return 4;
    if (std.mem.indexOf(u8, name, "with_render_texture") != null) return 5;
    if (std.mem.indexOf(u8, name, "instances") != null or std.mem.indexOf(u8, name, "Tilemap.draw_layers") != null) return 1;
    if (std.mem.indexOf(u8, name, "TextureUniform.set") != null) return 3;
    if (std.mem.indexOf(u8, name, "update_texture") != null or std.mem.indexOf(u8, name, "from_bytes") != null or std.mem.indexOf(u8, name, "Uniform.set") != null) return 2;
    if (std.mem.indexOf(u8, name, "with_") != null or std.mem.indexOf(u8, name, "set_texture_") != null or std.mem.indexOf(u8, name, "clear!") != null) return 3;
    if (std.mem.startsWith(u8, name, "Draw.") or std.mem.startsWith(u8, name, "Text.Prepared.draw")) return 0;
    return null;
}

test "full draw detail names map to stable non-payload categories" {
    try std.testing.expectEqual(@as(?u8, 0), drawDetailKind("Draw.circle!"));
    try std.testing.expectEqual(@as(?u8, 1), drawDetailKind("Draw.texture_instances!"));
    try std.testing.expectEqual(@as(?u8, 2), drawDetailKind("Assets.update_texture!"));
    try std.testing.expectEqual(@as(?u8, 2), drawDetailKind("Draw.Vec4Uniform.set!"));
    try std.testing.expectEqual(@as(?u8, 3), drawDetailKind("Draw.TextureUniform.set!"));
    try std.testing.expectEqual(@as(?u8, 3), drawDetailKind("Draw.with_shader!"));
    try std.testing.expectEqual(@as(?u8, 4), drawDetailKind("Capture.read_region!"));
    try std.testing.expectEqual(@as(?u8, 5), drawDetailKind("Draw.with_render_texture!"));
    try std.testing.expect(drawDetailKind("Http.send!") == null);
    try std.testing.expectEqual(@as(u64, 12), drawByteCount(u32, 3));
    try std.testing.expectEqual(@as(u64, 4), drawByteCount(abi.ColorRgba, 1));

    var exact = EffectScope.begin("test", 99);
    exact.setDrawMetrics(6, 24);
    try std.testing.expectEqual(@as(u64, 6), exact.drawValues().items);
    try std.testing.expectEqual(@as(u64, 24), exact.drawValues().bytes);
    var fallback = EffectScope.begin("test", 9);
    fallback.inbound_copied_bytes = 9;
    fallback.outbound_copied_bytes = 3;
    try std.testing.expectEqual(@as(u64, 12), fallback.drawValues().bytes);
}

test "disabled and summary effect scopes do not read a clock" {
    const Clock = struct {
        var reads: usize = 0;
        fn now() i96 {
            reads += 1;
            return 1;
        }
    };
    const previous_clock = observatory_test_clock;
    const previous_observatory = active_observatory;
    const previous_detail = observatory_task_detail;
    defer {
        observatory_test_clock = previous_clock;
        active_observatory = previous_observatory;
        observatory_task_detail = previous_detail;
    }
    observatory_test_clock = Clock.now;
    active_observatory = null;
    observatory_task_detail = false;
    const allocations_before = alloc_meter.alloc_calls;
    const bytes_before = alloc_meter.alloc_bytes;
    var disabled = EffectScope.begin("test.disabled!", 4);
    try std.testing.expect(!disabled.active);
    disabled.addCopiedBytes(8);
    disabled.end();
    try std.testing.expectEqual(@as(i96, 0), observatoryMeasurementStart());
    try std.testing.expectEqual(@as(u64, 0), observatoryMeasurementElapsed(1));
    try std.testing.expectEqual(@as(usize, 0), Clock.reads);
    try std.testing.expectEqual(allocations_before, alloc_meter.alloc_calls);
    try std.testing.expectEqual(bytes_before, alloc_meter.alloc_bytes);
    active_observatory = @ptrFromInt(@alignOf(observatory.Session));
    var summary = EffectScope.begin("test.summary!", 4);
    try std.testing.expect(summary.active);
    try std.testing.expectEqual(@as(i96, 0), observatoryDetailMeasurementStart());
    summary.end();
    try std.testing.expectEqual(@as(usize, 0), Clock.reads);
    active_observatory = null;
    observatory_task_detail = false;
    try std.testing.expectEqual(@as(u64, 0), observatoryTaskNow(@ptrCast(&Clock.reads)));
}

fn hostedTraceMark(label: abi.RocStr) callconv(.c) void {
    defer label.decref(activeHost());
    enforcePhase("Trace.mark!", diagnostic_anywhere);
    if (!diagnostic_anywhere.contains(active_phase) or !validateTraceLabel(label)) return;
    traceEmit(.mark, label.asSlice(), 0, 0, 0);
}

fn hostedTraceBegin(label: abi.RocStr) callconv(.c) u64 {
    defer label.decref(activeHost());
    enforcePhase("Trace.begin!", diagnostic_anywhere);
    if (!diagnostic_anywhere.contains(active_phase) or !validateTraceLabel(label)) return 0;
    if (active_trace_owner == 0) {
        traceProgrammerError("Trace.begin! has no active callback or task owner");
        return 0;
    }
    const track = traceTrack(active_trace_owner, true) orelse return 0;
    if (track.depth == TRACE_ZONE_DEPTH) {
        traceProgrammerError("annotation zones may nest at most 64 deep");
        return 0;
    }
    const sequence = next_trace_token;
    next_trace_token +%= 1;
    if (next_trace_token == 0) next_trace_token = 1;
    const token = (@as(u64, active_trace_owner) << 32) | sequence;
    const entry = &track.zones[track.depth];
    entry.token = token;
    // Disabled annotations preserve the exact same structural stack without
    // paying for timestamps that cannot be observed or persisted.
    entry.started_ns = if (active_observatory != null) traceNowNs() else 0;
    entry.parked_ns = 0;
    entry.label_len = @intCast(label.asSlice().len);
    @memcpy(entry.label[0..entry.label_len], label.asSlice());
    track.depth += 1;
    traceEmit(.zone_begin, label.asSlice(), @bitCast(token), 0, 0);
    return token;
}

fn hostedTraceEnd(token: u64) callconv(.c) void {
    enforcePhase("Trace.end!", diagnostic_anywhere);
    if (!diagnostic_anywhere.contains(active_phase)) return;
    const owner: u32 = @truncate(token >> 32);
    if (owner == 0 or owner != active_trace_owner) {
        traceProgrammerError("annotation zone belongs to another callback or task");
        return;
    }
    const track = traceTrack(owner, false) orelse {
        traceProgrammerError("annotation zone is expired or already ended");
        return;
    };
    if (track.cancelling) return;
    if (track.depth == 0 or track.zones[track.depth - 1].token != token) {
        traceProgrammerError("annotation zones must end once in strict LIFO order");
        return;
    }
    const entry = &track.zones[track.depth - 1];
    const session = active_observatory;
    if (session) |recorder| {
        const ended_ns = traceNowNs();
        const durations = traceZoneDurations(entry.started_ns, entry.parked_ns, ended_ns);
        _ = recorder.recordAnnotation(.{
            .cycle = observatory_cycle,
            .timestamp_ns = ended_ns,
            .phase = @intFromEnum(active_phase),
            .kind = .zone_end,
            .name = entry.label[0..entry.label_len],
            .integer = @bitCast(token),
            .wall_ns = durations.wall,
            .active_ns = durations.active,
            .parked_ns = durations.parked,
        });
    }
    track.depth -= 1;
}

fn validateTraceUnit(unit: u8) bool {
    if (unit <= 5) return true;
    traceProgrammerError("annotation sample unit is invalid");
    return false;
}

fn hostedTraceSampleI64(label: abi.RocStr, value: i64, unit: u8) callconv(.c) void {
    defer label.decref(activeHost());
    enforcePhase("Trace.sample_i64!", diagnostic_anywhere);
    if (!diagnostic_anywhere.contains(active_phase) or !validateTraceLabel(label) or !validateTraceUnit(unit)) return;
    traceEmit(.sample_i64, label.asSlice(), value, 0, unit);
}

fn hostedTraceSampleF64(label: abi.RocStr, value: f64, unit: u8) callconv(.c) void {
    defer label.decref(activeHost());
    enforcePhase("Trace.sample_f64!", diagnostic_anywhere);
    if (!diagnostic_anywhere.contains(active_phase) or !validateTraceLabel(label) or !std.math.isFinite(value) or !validateTraceUnit(unit)) {
        if (!std.math.isFinite(value)) traceProgrammerError("floating-point annotation samples must be finite");
        return;
    }
    traceEmit(.sample_f64, label.asSlice(), 0, value, unit);
}

test "Trace annotations validate labels units and every callback phase" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    active_roc_host = &roc_host;
    defer active_roc_host = null;
    last_trace_violation = null;

    inline for (.{ Phase.startup, .update, .render, .task }) |phase| {
        const scope = PhaseScope.enter(phase);
        hostedTraceMark(abi.RocStr.fromSlice("mark", &roc_host));
        hostedTraceSampleI64(abi.RocStr.fromSlice("count", &roc_host), -1, 1);
        hostedTraceSampleF64(abi.RocStr.fromSlice("ratio", &roc_host), -0.5, 5);
        const zone = hostedTraceBegin(abi.RocStr.fromSlice("zone", &roc_host));
        try std.testing.expect(zone != 0);
        hostedTraceEnd(zone);
        scope.leave();
        try std.testing.expect(last_trace_violation == null);
    }

    const update = PhaseScope.enter(.update);
    hostedTraceSampleI64(abi.RocStr.fromSlice("bad-unit", &roc_host), 0, 6);
    try std.testing.expectEqualStrings("annotation sample unit is invalid", last_trace_violation.?);
    last_trace_violation = null;
    hostedTraceSampleF64(abi.RocStr.fromSlice("nan", &roc_host), std.math.nan(f64), 0);
    try std.testing.expectEqualStrings("floating-point annotation samples must be finite", last_trace_violation.?);
    last_trace_violation = null;
    var long_label: [TRACE_LABEL_MAX_BYTES + 1]u8 = @splat('x');
    hostedTraceMark(abi.RocStr.fromSlice(&long_label, &roc_host));
    try std.testing.expectEqualStrings("annotation labels must be at most 255 UTF-8 bytes", last_trace_violation.?);
    update.leave();
}

test "disabled Trace zones and waits preserve structure without reading a clock" {
    const Clock = struct {
        var reads: usize = 0;
        fn now() i96 {
            reads += 1;
            return 1;
        }
    };
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    const previous_host = active_roc_host;
    const previous_clock = observatory_test_clock;
    const previous_observatory = active_observatory;
    defer {
        active_roc_host = previous_host;
        observatory_test_clock = previous_clock;
        active_observatory = previous_observatory;
    }
    active_roc_host = &roc_host;
    observatory_test_clock = Clock.now;
    active_observatory = null;

    const task = PhaseScope.enter(.task);
    const zone = hostedTraceBegin(abi.RocStr.fromSlice("disabled", &roc_host));
    const wait = WaitScope.enter();
    wait.leave();
    hostedTraceEnd(zone);
    task.leave();
    try std.testing.expectEqual(@as(usize, 0), Clock.reads);
}

test "Trace zones are owner scoped strict LIFO handles" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    active_roc_host = &roc_host;
    defer active_roc_host = null;
    last_trace_violation = null;

    const update = PhaseScope.enter(.update);
    const parent = hostedTraceBegin(abi.RocStr.fromSlice("parent", &roc_host));
    const child = hostedTraceBegin(abi.RocStr.fromSlice("child", &roc_host));
    hostedTraceEnd(parent);
    try std.testing.expectEqualStrings("annotation zones must end once in strict LIFO order", last_trace_violation.?);
    last_trace_violation = null;
    hostedTraceEnd(child);
    hostedTraceEnd(parent);
    hostedTraceEnd(parent);
    try std.testing.expectEqualStrings("annotation zones must end once in strict LIFO order", last_trace_violation.?);
    last_trace_violation = null;
    update.leave();

    const render = PhaseScope.enter(.render);
    hostedTraceEnd(parent);
    try std.testing.expectEqualStrings("annotation zone belongs to another callback or task", last_trace_violation.?);
    render.leave();
}

test "Trace accepts exactly 64 nested zones and rejects the 65th" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    active_roc_host = &roc_host;
    defer active_roc_host = null;
    last_trace_violation = null;
    const task = PhaseScope.enter(.task);
    var handles: [TRACE_ZONE_DEPTH]u64 = undefined;
    for (&handles) |*handle| {
        handle.* = hostedTraceBegin(abi.RocStr.fromSlice("depth", &roc_host));
        try std.testing.expect(handle.* != 0);
    }
    try std.testing.expectEqual(@as(u64, 0), hostedTraceBegin(abi.RocStr.fromSlice("too deep", &roc_host)));
    try std.testing.expectEqualStrings("annotation zones may nest at most 64 deep", last_trace_violation.?);
    last_trace_violation = null;
    var index = handles.len;
    while (index != 0) {
        index -= 1;
        hostedTraceEnd(handles[index]);
    }
    task.leave();
    try std.testing.expect(last_trace_violation == null);
}

test "Trace copied handles double ends expiry and callback escape are diagnosed" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    active_roc_host = &roc_host;
    defer active_roc_host = null;
    last_trace_violation = null;

    const update = PhaseScope.enter(.update);
    const handle = hostedTraceBegin(abi.RocStr.fromSlice("copied", &roc_host));
    const copied = handle;
    hostedTraceEnd(handle);
    hostedTraceEnd(copied);
    try std.testing.expectEqualStrings("annotation zones must end once in strict LIFO order", last_trace_violation.?);
    last_trace_violation = null;
    update.leave();

    const render = PhaseScope.enter(.render);
    hostedTraceEnd(copied);
    try std.testing.expectEqualStrings("annotation zone belongs to another callback or task", last_trace_violation.?);
    last_trace_violation = null;
    _ = hostedTraceBegin(abi.RocStr.fromSlice("escape", &roc_host));
    render.leave();
    try std.testing.expectEqualStrings("an annotation zone escaped its callback or task body", last_trace_violation.?);
}

test "Trace end during cancellation acknowledges an already aborted zone" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    active_roc_host = &roc_host;
    defer active_roc_host = null;
    last_trace_violation = null;

    const task = PhaseScope.enter(.task);
    const handle = hostedTraceBegin(abi.RocStr.fromSlice("cancelled", &roc_host));
    const track = traceTrack(active_trace_owner, false).?;
    // `abortTaskTraceOwner` records and pops every zone before the coroutine
    // is cancelled. Model that completed synchronous step without requiring a
    // recorder, then exercise the Roc cleanup call made during stack unwind.
    track.depth = 0;
    track.cancelling = true;
    hostedTraceEnd(handle);
    try std.testing.expect(last_trace_violation == null);
    task.leave();
}

test "nested Trace zones accumulate every wait and derive complete durations while disabled" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    active_roc_host = &roc_host;
    defer active_roc_host = null;
    const previous_observatory = active_observatory;
    active_observatory = null;
    defer active_observatory = previous_observatory;
    last_trace_violation = null;

    const task = PhaseScope.enter(.task);
    const owner = active_trace_owner;
    const parent = hostedTraceBegin(abi.RocStr.fromSlice("parent waits", &roc_host));
    chargeTraceParked(owner, 5);
    const child = hostedTraceBegin(abi.RocStr.fromSlice("child waits", &roc_host));
    chargeTraceParked(owner, 7);
    chargeTraceParked(owner, 11);
    const track = traceTrack(owner, false).?;
    try std.testing.expectEqual(@as(u64, 23), track.zones[0].parked_ns);
    try std.testing.expectEqual(@as(u64, 18), track.zones[1].parked_ns);

    const durations = traceZoneDurations(100, 18, 150);
    try std.testing.expectEqual(@as(u64, 50), durations.wall);
    try std.testing.expectEqual(@as(u64, 32), durations.active);
    try std.testing.expectEqual(@as(u64, 18), durations.parked);
    hostedTraceEnd(child);
    hostedTraceEnd(parent);
    task.leave();
    try std.testing.expect(last_trace_violation == null);

    const update = PhaseScope.enter(.update);
    const update_zone = hostedTraceBegin(abi.RocStr.fromSlice("update", &roc_host));
    const wait = WaitScope.enter();
    wait.leave();
    try std.testing.expectEqual(@as(u64, 0), traceTrack(active_trace_owner, false).?.zones[0].parked_ns);
    hostedTraceEnd(update_zone);
    update.leave();
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
/// The task waiting for `Capture.screenshot!` to finish, and its answer.
///
/// One slot, because the host reads the framebuffer back once per frame and
/// keeps one pending path. A second concurrent screenshot is `AlreadyPending`
/// rather than silently replacing the first.
const ScreenshotWait = struct {
    /// Signalled by the frame loop once the readback has been handed to the
    /// waiting task, which then encodes and writes it.
    ready: zio.ResetEvent = .init,
    /// The captured pixels, owned by the waiting task once `ready` is set.
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// Non-zero when the frame loop could not produce a readback at all.
    err: u8 = 0,
};
var screenshot_wait: ?*ScreenshotWait = null;
/// Readback memory held by `Capture.screenshot_texture!` calls in flight.
///
/// Several tasks can export at once -- nothing serializes them the way the
/// single end-of-frame readback serializes screenshots -- so this is what keeps
/// their combined footprint bounded. See `capture.StillBudget`.
var still_budget: capture.StillBudget = .{};
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
/// Scripted keyboard state, replacing the hardware keyboard while active.
///
/// Held flags: the same derivation that runs over hardware runs over this
/// array, so pressed and released fall out of consecutive frames rather than
/// being described here. A tap that starts and ends inside one cycle is the
/// one thing a level cannot say, so a script records that as an edge instead
/// (`raylib.recordVirtualKeyEdge`), exactly as the window system's callbacks
/// do for hardware. Nothing about the real keyboard changes -- a key the user
/// is holding is simply not what Roc is told about.
var virtual_keys_active: bool = false;
var virtual_key_down: [ffi.KEY_COUNT]bool = @splat(false);
/// Scripted text queued for the next input, in the order it was entered.
///
/// The same bound as the hardware channel, and it overflows the same way: a
/// longer script loses its tail rather than spilling into the following
/// frame, and the input says so.
var virtual_text: [raylib.TEXT_INPUT_CAPACITY]u32 = @splat(0);
var virtual_text_len: usize = 0;
var virtual_text_overflowed: bool = false;
/// Nanoseconds of divergence introduced by fixed-step recordings.
///
/// Fixed-step recording reports exact `1/fps` deltas instead of raylib's
/// measured values. Carrying the difference keeps Roc's clock monotonic when a
/// recording starts or stops.
var capture_clock_offset_ns: i128 = 0;
var capture_clock_last_real_ns: u64 = 0;

var headless_screen_width: i32 = 800;
var headless_screen_height: i32 = 600;
/// A headless run reports a focused, non-minimized window. There is no window
/// to ask, and a constant keeps `--host-headless` output reproducible.
const HEADLESS_WINDOW_FOCUSED = true;
const HEADLESS_WINDOW_MINIMIZED = false;
/// A headless run has no display to enumerate, so it answers with one virtual
/// monitor the size of the configured window. That keeps an app that places
/// itself on a monitor, or divides by the DPI scale, on the same code path in
/// CI as on a desktop, without inventing a geometry the run was never told
/// about.
const HEADLESS_MONITOR_NAME = "Headless";
const HEADLESS_MONITOR_REFRESH_HZ: i32 = 60;
/// The scale of an ordinary, non-HiDPI display: the headless answer, and the
/// stand-in for a factor the backend cannot state usefully.
const DEFAULT_WINDOW_SCALE: f32 = 1;
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
var render_texture_leases: [SCOPE_STACK_LIMIT]?*u64 = @splat(null);
/// Dimensions of each open render-target scope, pushed and popped in step with
/// `render_texture_leases` so entry `n` describes lease `n`.
///
/// This is what makes `Draw.Frame.size!` answer for the *active* target rather
/// than always for the window: the top of the stack is the surface a draw call
/// would land on, and an empty stack means that surface is the window. The
/// numbers are the ones the `RenderTexture` carries -- the dimensions it was
/// loaded with -- so no raylib query is involved and a headless run reports the
/// same size a windowed one does.
var render_target_sizes: [SCOPE_STACK_LIMIT]abi.HostABIDraw_frame_size = @splat(.{ .height = 0, .width = 0 });
var headless_tilemap_draw_calls: usize = 0;
var headless_tilemap_tiles: usize = 0;
var headless_tilemap_last_quad: ?TilemapQuadProbe = null;
var headless_texture_instance_batches: usize = 0;
var headless_texture_instances: usize = 0;
var render_texture_lease_count: usize = 0;
var shader_leases: [SCOPE_STACK_LIMIT]?*u64 = @splat(null);
var shader_lease_count: usize = 0;
var blend_scopes: [SCOPE_STACK_LIMIT]u8 = undefined;
var blend_scope_count: usize = 0;
var camera_scopes: [SCOPE_STACK_LIMIT]abi.HostABIDraw_begin_cameraArgs = undefined;
var camera_scope_count: usize = 0;
var scissor_scopes: [SCOPE_STACK_LIMIT]abi.HostABIDraw_begin_scissorArgs = undefined;
var scissor_scope_count: usize = 0;

const INVALID_RESOURCE_TOKEN = std.math.maxInt(u64);

const InvalidResourceBox = extern struct {
    refcount: isize = 0,
    token: u64 = INVALID_RESOURCE_TOKEN,
};

var invalid_resource_box: InvalidResourceBox = .{};

const DefaultFontBox = extern struct {
    refcount: isize = 0,
    token: u64 = 0,
};

var default_font_box: DefaultFontBox = .{};

const InvalidTextureBox = extern struct {
    refcount: isize = 0,
    payload: u64 = INVALID_RESOURCE_TOKEN,
};

var invalid_texture_box: InvalidTextureBox = .{};

const SoundResource = union(enum) {
    headless,
    native: raylib.Sound,
};

/// A native music stream and the encoded file it plays out of.
///
/// `LoadMusicStreamFromMemory` decodes lazily from the buffer it is handed
/// rather than copying it, so those bytes have to stay alive for as long as
/// the stream does. The slot owns them: the stream is unloaded first, then the
/// bytes are freed, and nothing outside the slot can reach either.
const NativeMusic = struct {
    stream: raylib.Music,
    encoded: []u8,
    allocator: std.mem.Allocator,
};

const MusicResource = union(enum) {
    headless,
    native: NativeMusic,
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

/// An opened root directory. Its `Dir` is the capability that makes asset
/// operations independent of later process-CWD changes. This first slice uses
/// normal OS path resolution inside the directory, so a symlink beneath the
/// root can still point outside it; public docs state that this is not a
/// sandbox/confinement boundary.
const StoreResource = struct {
    root: std.Io.Dir,
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
        .native => |music| {
            if (!builtin.is_test) raylib.unloadMusic(music.stream);
            music.allocator.free(music.encoded);
        },
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

var texture_destroy_count: usize = 0;

fn destroyTexture(resource: *TextureResource) void {
    if (builtin.is_test) texture_destroy_count += 1;
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

fn destroyStore(resource: *StoreResource) void {
    resource.root.close(mainThreadIo());
}

/// Close the descriptor when the last Roc reference to a socket is gone.
///
/// This is the whole lifecycle: there is no `close!` effect, so dropping the
/// handle -- from the model, from a task closure, at shutdown -- is what closes
/// the socket. A task still parked in `receive` cannot reach here, because it
/// holds a reference of its own for as long as it is parked.
fn destroyUdpSocket(resource: *udp_effect.Socket) void {
    resource.inner.close();
}

fn writeU64Token(payload: *u64, token: u64) void {
    payload.* = token;
}

fn readU64Token(payload: *const u64) u64 {
    return payload.*;
}

const SoundHeap = host_resource.HostResourceHeap(u64, SoundResource, 128, .sound, writeU64Token, readU64Token, destroySound);
const MusicHeap = host_resource.HostResourceHeap(u64, MusicResource, 16, .music, writeU64Token, readU64Token, destroyMusic);
const FontHeap = host_resource.HostResourceHeap(u64, FontResource, 32, .font, writeU64Token, readU64Token, destroyFont);
const TextureHeap = host_resource.HostResourceHeap(u64, TextureResource, 128, .texture, writeU64Token, readU64Token, destroyTexture);
const RenderTextureHeap = host_resource.HostResourceHeap(u64, RenderTextureResource, 32, .render_texture, writeU64Token, readU64Token, destroyRenderTexture);
const ShaderHeap = host_resource.HostResourceHeap(u64, ShaderResource, 32, .shader, writeU64Token, readU64Token, destroyShader);
const PreparedTextHeap = host_resource.HostResourceHeap(u64, PreparedTextResource, 256, .prepared_text, writeU64Token, readU64Token, destroyPreparedText);
const StoreHeap = host_resource.HostResourceHeap(u64, StoreResource, 16, .store, writeU64Token, readU64Token, destroyStore);

/// How many UDP sockets an app may hold open at once.
///
/// Small on purpose: a game binds one socket, or two when it also runs a
/// discovery or telemetry channel. Each slot carries its own 64 KiB receive
/// staging buffer, which is what the cap is really bounding, and a bind past
/// it is `ResourceLimit` rather than an unbounded descriptor count.
const MAX_LIVE_UDP_SOCKETS: usize = 8;

const UdpSocketHeap = host_resource.HostResourceHeap(u64, udp_effect.Socket, MAX_LIVE_UDP_SOCKETS, .udp_socket, writeU64Token, readU64Token, destroyUdpSocket);

/// Bytes a finished read handed over, and the allocator that owns them.
///
/// The allocator travels with the buffer rather than being assumed, because
/// the buffer outlives the call that made it: it is freed when Roc drops the
/// last reference to the list built on it, from `destroyFileBytes`, with no
/// read in progress to ask. Whoever allocated it is who frees it.
const FileBytesResource = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
};

fn destroyFileBytes(resource: *FileBytesResource) void {
    resource.allocator.free(resource.bytes);
    resource.bytes = &.{};
}

/// Finished byte buffers live on Roc's refcount, just like all other host
/// resources. The payload itself is deliberately a word-sized token: a
/// seamless primitive `List` may use the payload address as its ARC allocation
/// pointer, while the token keeps the heap's usual structural validation.
const FileBytesHeap = host_resource.HostResourceHeap(u64, FileBytesResource, MAX_LIVE_FILE_BYTE_LISTS, .file_bytes, writeU64Token, readU64Token, destroyFileBytes);
var file_bytes_heap: FileBytesHeap = .{};

/// Make the sole heap reference for `resource` into the delivered byte list.
///
/// This has no payload allocation and no payload copy. `HostResourceHeap`
/// guarantees that its `u64` payload follows the slot refcount immediately, so
/// decrementing the list calls `nativeRocDealloc` with this slot base. The low
/// tag selects the seamless-list representation: it prevents reuse or resizing
/// the backing allocation, but does not prohibit unique in-window mutation.
/// The transfer is safe because the host never reads or shares `bytes` again.
fn seamlessByteList(resource: *u64, bytes: []u8) abi.RocListWith(u8, false) {
    std.debug.assert(bytes.len != 0);
    std.debug.assert((@intFromPtr(resource) & 1) == 0);
    return .{
        .elements_ptr = bytes.ptr,
        .length = bytes.len,
        .capacity_or_alloc_ptr = @intFromPtr(resource) | 1,
    };
}

/// Slots promised to reads that have started but have not yet handed their
/// bytes over. `Files.read_bytes!` has to reserve one before it opens the
/// path: otherwise a full heap could let `MAX_LIVE_FILE_BYTE_LISTS` large
/// files be read only to discard each one when there is no slot to install it
/// in, so the app would pay for the I/O and still get `Busy`.
///
/// This is deliberately just a count. Every read runs on the frame thread, so
/// there is one reader and writer and nothing to synchronize, and
/// `MAX_LIVE_FILE_BYTE_LISTS` bounds it. No read admission allocates.
const FileBytesDeliveryReservations = struct {
    count: usize = 0,

    fn reserve(self: *FileBytesDeliveryReservations) bool {
        const live = file_bytes_heap.active();
        std.debug.assert(live <= MAX_LIVE_FILE_BYTE_LISTS);
        std.debug.assert(self.count <= MAX_LIVE_FILE_BYTE_LISTS);
        if (live + self.count >= MAX_LIVE_FILE_BYTE_LISTS) return false;
        self.count += 1;
        return true;
    }

    fn release(self: *FileBytesDeliveryReservations) void {
        std.debug.assert(self.count != 0);
        self.count -= 1;
    }

    /// Shutdown has cancelled every task that could still have been reading.
    /// The reads they were parked in will never resume to release their own
    /// promises, so forget them all before another app lifetime can begin.
    fn clearAfterWorkStops(self: *FileBytesDeliveryReservations) void {
        self.count = 0;
    }
};

var file_bytes_delivery_reservations = FileBytesDeliveryReservations{};

var sound_heap: SoundHeap = .{};
var music_heap: MusicHeap = .{};
var font_heap: FontHeap = .{};
const StartupFontConfig = struct {
    path: []const u8 = &.{},
    size: i32 = 20,
};

/// Host-lifetime owner for a configured startup font, when present.
var startup_font_handle: ?*u64 = null;
var startup_font_config: StartupFontConfig = .{};
var texture_heap: TextureHeap = .{};
var render_texture_heap: RenderTextureHeap = .{};
var shader_heap: ShaderHeap = .{};
var prepared_text_heap: PreparedTextHeap = .{};
var store_heap: StoreHeap = .{};
var udp_socket_heap: UdpSocketHeap = .{};

/// Every typed resource heap the host owns: what a Roc deallocation is offered
/// to, and what the kind-coverage check below reads.
const resource_heaps = .{
    &sound_heap,
    &music_heap,
    &font_heap,
    &texture_heap,
    &render_texture_heap,
    &shader_heap,
    &prepared_text_heap,
    &file_bytes_heap,
    &store_heap,
    &udp_socket_heap,
    &sqlite_effect.stmt_heap,
    &sqlite_effect.db_heap,
};

comptime {
    // `Kind` is the only place a resource number is written down, and this is
    // what keeps that true in both directions: a kind nobody declares a heap
    // for, or two heaps declaring the same one, fails the build here.
    for (std.enums.values(host_resource.Kind)) |kind| {
        var heaps_with_kind: usize = 0;
        for (resource_heaps) |heap| {
            if (@TypeOf(heap.*).resource_kind == kind) heaps_with_kind += 1;
        }
        if (heaps_with_kind != 1) {
            @compileError("each host resource kind needs exactly one heap: " ++ @tagName(kind));
        }
    }
}

var prepared_text_prepare_calls: usize = 0;
var prepared_text_draw_calls: usize = 0;
var prepared_text_storage_allocations: usize = 0;

fn releaseResourceBox(host: *RocHost, handle: anytype) void {
    const Payload = @TypeOf(handle.*);
    abi.decrefBoxWith(@ptrCast(handle), @alignOf(Payload), false, null, host);
}

/// Captured `envp` for the process. On Linux the host runs with `-nostdlib`, so
/// glibc never populates an environ global; `platform_main` captures it from the
/// process stack. Other (libc-linked) targets read `std.c.environ` instead.
var host_environ: []const [*:0]u8 = &.{};

/// Look up an environment variable without `std.posix.getenv` (removed in 0.16).
/// Scans `host_environ`, which is captured once in `platform_main`.
fn hostGetEnv(key: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) {
        // Windows does not expose a stable `environ` pointer: the PEB-owned
        // block can move when the process environment changes. Copy the few
        // host options we query into process-lifetime storage instead.
        const environ: std.process.Environ = .{ .block = .global };
        return environ.getAlloc(std.heap.page_allocator, key) catch null;
    }
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
    inline for (resource_heaps) |heap| {
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
    if (observatory_full_detail) {
        const storage = @max(alignment, @alignOf(usize));
        allocation_realloc_old_pointer = @intFromPtr(ptr) - storage;
        if (allocation_identities.get(allocation_realloc_old_pointer)) |identity| {
            allocation_realloc_id = identity.id;
            allocation_realloc_old_bytes = identity.bytes;
        }
    }
    defer {
        allocation_realloc_id = 0;
        allocation_realloc_old_pointer = 0;
        allocation_realloc_old_bytes = 0;
        allocation_realloc_in_place = false;
    }
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
/// explicitly blocking: an effect that waits must use `waitingIo()`, the zio
/// runtime's, so it parks its coroutine and lets the frame loop run. Reaching
/// for this one there would stall the frame and would appear to work.
fn mainThreadIo() std.Io {
    if (comptime builtin.is_test) {
        return std.testing.io;
    } else {
        return std.Io.Threaded.global_single_threaded.io();
    }
}

fn emptyAppReadFileResult() AppReadFileResult {
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

fn resetHeadlessRuntime(app_config: AppConfig) void {
    capture_session.reset();
    resetVirtualInput();

    capture_screenshot_pending = false;
    // The snapshot is freed before the budget is zeroed: a reset that only
    // forgot the reservation would leave the buffer behind for the next app
    // lifetime to read as if it were its own frame.
    releaseScreenSnapshot();
    screen_snapshot_requested = false;
    still_budget.reset();
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
    render_target_sizes = @splat(.{ .height = 0, .width = 0 });
    shader_lease_count = 0;
    blend_scope_count = 0;
    camera_scope_count = 0;
    scissor_scope_count = 0;
    prepared_text_prepare_calls = 0;
    prepared_text_draw_calls = 0;
    prepared_text_storage_allocations = 0;
}

const FontMetric = abi.HostABIText_font_metricsGlyphs;

/// The headless font is deliberately small but still proportional. It exercises
/// the pure snapshot path without pretending to have a GPU font resource.
const HEADLESS_GLYPHS = [_]FontMetric{
    .{ .advance_x = 1, .codepoint = '?', .height = 2, .offset_x = 0, .offset_y = 0, .width = 1 },
    .{ .advance_x = 2, .codepoint = 'W', .height = 2, .offset_x = 0, .offset_y = 0, .width = 2 },
    .{ .advance_x = 1, .codepoint = 'i', .height = 2, .offset_x = 0, .offset_y = 0, .width = 1 },
    .{ .advance_x = 1, .codepoint = 0xE9, .height = 2, .offset_x = 0, .offset_y = 0, .width = 1 },
};
const HEADLESS_FONT_BASE_SIZE: f32 = 2;

fn metricAdvance(glyph: FontMetric) f32 {
    return if (glyph.advance_x > 0) glyph.advance_x else glyph.width + glyph.offset_x;
}

fn glyphAdvance(glyphs: []const FontMetric, fallback_index: usize, codepoint: u32) f32 {
    for (glyphs) |glyph| {
        if (glyph.codepoint == codepoint) return metricAdvance(glyph);
    }
    return metricAdvance(glyphs[fallback_index]);
}

const DecodedCodepoint = struct {
    codepoint: u32,
    next: usize,
};

const TextMeasurement = struct {
    width: f32,
    height: f32,
};

/// Input originated as a Roc `Str`, so all non-NUL bytes form valid UTF-8.
fn decodeUtf8(text: []const u8, index: usize) DecodedCodepoint {
    const first: u32 = text[index];
    if (first < 0x80) return .{ .codepoint = first, .next = index + 1 };
    if (first < 0xE0) return .{
        .codepoint = (first - 0xC0) * 64 + @as(u32, text[index + 1]) - 0x80,
        .next = index + 2,
    };
    if (first < 0xF0) return .{
        .codepoint = (first - 0xE0) * 4096 + (@as(u32, text[index + 1]) - 0x80) * 64 + @as(u32, text[index + 2]) - 0x80,
        .next = index + 3,
    };
    return .{
        .codepoint = (first - 0xF0) * 262144 + (@as(u32, text[index + 1]) - 0x80) * 4096 + (@as(u32, text[index + 2]) - 0x80) * 64 + @as(u32, text[index + 3]) - 0x80,
        .next = index + 4,
    };
}

/// Match raylib 6's `MeasureTextEx` from a scalar metric snapshot.
fn measureTextWithMetrics(text: []const u8, glyphs: []const FontMetric, base_size: f32, fallback_index: usize, line_spacing: f32, size: f32, spacing: f32) TextMeasurement {
    if (text.len == 0 or text[0] == 0) return .{ .height = 0, .width = 0 };

    var index: usize = 0;
    var line_width: f32 = 0;
    var widest_width: f32 = 0;
    var line_codepoints: usize = 0;
    var widest_codepoints: usize = 0;
    var height = size;
    while (index < text.len and text[index] != 0) {
        const decoded = decodeUtf8(text, index);
        index = decoded.next;
        if (decoded.codepoint == '\n') {
            widest_width = @max(widest_width, line_width);
            widest_codepoints = @max(widest_codepoints, line_codepoints);
            line_width = 0;
            line_codepoints = 0;
            height += size + line_spacing;
        } else {
            line_width += glyphAdvance(glyphs, fallback_index, decoded.codepoint);
            line_codepoints += 1;
        }
    }
    const width = @max(widest_width, line_width) * (size / base_size) + (@as(f32, @floatFromInt(@max(widest_codepoints, line_codepoints))) - 1) * spacing;
    return .{ .height = height, .width = width };
}

/// Match raylib 6's `MeasureTextEx` for the scalar headless font.
fn headlessMeasureText(text: []const u8, size: f32, spacing: f32) TextMeasurement {
    return measureTextWithMetrics(
        text,
        &HEADLESS_GLYPHS,
        HEADLESS_FONT_BASE_SIZE,
        0,
        RAYLIB_DEFAULT_TEXT_LINE_SPACING,
        size,
        spacing,
    );
}

test "headless text measurement keeps raylib codepoint, newline, and NUL rules" {
    try std.testing.expectEqual(@as(c_int, 6), raylib.majorVersion());
    try std.testing.expectEqual(@as(f32, 2), RAYLIB_DEFAULT_TEXT_LINE_SPACING);

    const iii = headlessMeasureText("iii", 20, 1);
    try std.testing.expectEqual(@as(f32, 32), iii.width);
    try std.testing.expectEqual(@as(f32, 20), iii.height);

    const www = headlessMeasureText("WWW", 20, 1);
    try std.testing.expectEqual(@as(f32, 62), www.width);

    const multibyte = headlessMeasureText("\xC3\xA9", 20, 1);
    try std.testing.expectEqual(@as(f32, 10), multibyte.width);

    const newline = headlessMeasureText("i\nW", 20, 1);
    try std.testing.expectEqual(@as(f32, 20), newline.width);
    try std.testing.expectEqual(@as(f32, 42), newline.height);

    const fallback = headlessMeasureText("\xF0\x9F\x98\x80", 20, 1);
    try std.testing.expectEqual(@as(f32, 10), fallback.width);

    const nul_terminated = headlessMeasureText("i\x00W", 20, 1);
    try std.testing.expectEqual(@as(f32, 10), nul_terminated.width);
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
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), prepared_text_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        // No frame loop here to end, so the retirement queue is drained by
        // hand -- and without a frame's budget, since there is no frame to
        // protect and anything left behind reads as a leak.
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    prepared_text_prepare_calls = 0;
    prepared_text_draw_calls = 0;
    prepared_text_storage_allocations = 0;
    var long_text: [CSTRING_STACK_CAPACITY + 128]u8 = undefined;
    @memset(&long_text, 'x');
    const font = storeFont(.headless).?;
    const result = hostedTextPrepareRaw(&roc_host, .{
        .font = font,
        .text = abi.RocStr.fromSlice(&long_text, &roc_host),
        .size = 18,
        .spacing = 1,
    });
    try std.testing.expectEqual(RESOURCE_ERR_NONE, result.err);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 1), prepared_text_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
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
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 1), prepared_text_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 1), font_heap.active());

    releaseResourceBox(&roc_host, result.prepared);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), prepared_text_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());
}

test "prepared text rejects resource kind confusion and releases transferred owners" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        // No frame loop here to end, so the retirement queue is drained by
        // hand -- and without a frame's budget, since there is no frame to
        // protect and anything left behind reads as a leak.
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    const draw_shader = storeShader(.headless).?;
    hostedDrawPreparedTextRaw(&roc_host, .{
        .prepared = draw_shader,
        .pos = .{ .x = 0, .y = 0 },
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    });
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());

    const font_shader = storeShader(.headless).?;
    const result = hostedTextPrepareRaw(&roc_host, .{
        .font = font_shader,
        .text = abi.RocStr.empty(),
        .size = 16,
        .spacing = 1,
    });
    try std.testing.expectEqual(RESOURCE_ERR_FAILED, result.err);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), prepared_text_heap.active());
}

test "nested render and shader scopes lease last references until matching end" {
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        // No frame loop here to end, so the retirement queue is drained by
        // hand -- and without a frame's budget, since there is no frame to
        // protect and anything left behind reads as a leak.
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    const outer_target = storeRenderTexture(.headless).?;
    const inner_target = storeRenderTexture(.headless).?;
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginRenderTextureRaw(.{ .handle = outer_target, .height = 90, .width = 160 }));
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginRenderTextureRaw(.{ .handle = inner_target, .height = 45, .width = 80 }));
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 2), render_texture_heap.active());
    try std.testing.expectEqual(@as(u8, 2), headless_render_texture_depth);
    hostedDrawEndRenderTextureRaw();
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 1), render_texture_heap.active());
    hostedDrawEndRenderTextureRaw();
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    try std.testing.expectEqual(@as(u8, 0), headless_render_texture_depth);

    const outer_shader = storeShader(.headless).?;
    const inner_shader = storeShader(.headless).?;
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginShaderRaw(.{ .arg0 = outer_shader }));
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginShaderRaw(.{ .arg0 = inner_shader }));
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 2), shader_heap.active());
    try std.testing.expectEqual(@as(u8, 2), headless_shader_depth);
    hostedDrawEndShaderRaw();
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 1), shader_heap.active());
    hostedDrawEndShaderRaw();
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
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
    const outer_camera = abi.HostABIDraw_begin_cameraArgs{
        .target = .{ .x = 10, .y = 20 },
        .offset = .{ .x = 30, .y = 40 },
        .rotation = 5,
        .zoom = 2,
    };
    const inner_camera = abi.HostABIDraw_begin_cameraArgs{
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

    const outer_scissor = abi.HostABIDraw_begin_scissorArgs{ .x = 10, .y = 20, .width = 300, .height = 200 };
    const inner_scissor = abi.HostABIDraw_begin_scissorArgs{ .x = 30, .y = 40, .width = 50, .height = 60 };
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

test "the frame reports the active render target, and the window again once it closes" {
    // This is the case a window size carried in the model gets silently wrong.
    // Inside a render texture the surface being drawn to is the target, so a
    // HUD laid out against the window lands somewhere else entirely -- and
    // nothing about the model says so.
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    const restore_width = headless_screen_width;
    const restore_height = headless_screen_height;
    last_phase_violation = null;
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        headless_screen_width = restore_width;
        headless_screen_height = restore_height;
        last_phase_violation = null;
        active_headless = false;
        active_roc_host = null;
    }

    headless_screen_width = 1100;
    headless_screen_height = 760;

    const phase = PhaseScope.enter(.render);
    defer phase.leave();

    const window_size = hostedDrawFrameSizeRaw();
    try std.testing.expectEqual(@as(f32, 1100), window_size.width);
    try std.testing.expectEqual(@as(f32, 760), window_size.height);

    // Real heap-backed targets, taken and released exactly as a running app's
    // are. A zeroed stand-in would make the leases below no-ops and leave the
    // unwinding this test is about untested.
    const outer_target = storeRenderTexture(.headless).?;
    const inner_target = storeRenderTexture(.headless).?;

    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginRenderTextureRaw(.{ .handle = outer_target, .height = 90, .width = 160 }));
    const outer_size = hostedDrawFrameSizeRaw();
    try std.testing.expectEqual(@as(f32, 160), outer_size.width);
    try std.testing.expectEqual(@as(f32, 90), outer_size.height);

    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginRenderTextureRaw(.{ .handle = inner_target, .height = 45, .width = 80 }));
    const inner_size = hostedDrawFrameSizeRaw();
    try std.testing.expectEqual(@as(f32, 80), inner_size.width);
    try std.testing.expectEqual(@as(f32, 45), inner_size.height);

    // Closing the inner scope reveals the outer target, not the window: the
    // stack unwinds a level at a time, the same way the native target does.
    hostedDrawEndRenderTextureRaw();
    const reverted = hostedDrawFrameSizeRaw();
    try std.testing.expectEqual(@as(f32, 160), reverted.width);
    try std.testing.expectEqual(@as(f32, 90), reverted.height);

    hostedDrawEndRenderTextureRaw();
    const restored = hostedDrawFrameSizeRaw();
    try std.testing.expectEqual(@as(f32, 1100), restored.width);
    try std.testing.expectEqual(@as(f32, 760), restored.height);

    // The window is asked, not remembered, so a `Window.suggest_size!` called
    // from `update!` reaches the `render!` of the same cycle -- one cycle
    // sooner than a size sampled in `update!` could report it.
    headless_screen_width = 640;
    headless_screen_height = 480;
    const resized = hostedDrawFrameSizeRaw();
    try std.testing.expectEqual(@as(f32, 640), resized.width);
    try std.testing.expectEqual(@as(f32, 480), resized.height);

    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());

    // A refused scope draws nowhere new, so it must not report anywhere new.
    const saturating = storeRenderTexture(.headless).?;
    abi.increfBox(@ptrCast(saturating), SCOPE_STACK_LIMIT);
    for (0..SCOPE_STACK_LIMIT) |_| try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginRenderTextureRaw(.{ .handle = saturating, .height = 16, .width = 16 }));
    try std.testing.expectEqual(SCOPE_LIMIT, hostedDrawBeginRenderTextureRaw(.{ .handle = saturating, .height = 999, .width = 999 }));
    const saturated = hostedDrawFrameSizeRaw();
    try std.testing.expectEqual(@as(f32, 16), saturated.width);
    try std.testing.expectEqual(@as(f32, 16), saturated.height);
    for (0..SCOPE_STACK_LIMIT) |_| hostedDrawEndRenderTextureRaw();
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    try std.testing.expectEqual(@as(usize, 0), render_texture_lease_count);

    // Every read above was made from `render!`, which is the only phase that
    // admits one.
    try std.testing.expectEqual(@as(?PhaseViolation, null), last_phase_violation);
}

test "resource scopes report bounded saturation without leaking transferred owners" {
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        // No frame loop here to end, so the retirement queue is drained by
        // hand -- and without a frame's budget, since there is no frame to
        // protect and anything left behind reads as a leak.
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    const target = storeRenderTexture(.headless).?;
    abi.increfBox(@ptrCast(target), SCOPE_STACK_LIMIT);
    for (0..SCOPE_STACK_LIMIT) |_| try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginRenderTextureRaw(.{ .handle = target, .height = 16, .width = 16 }));
    try std.testing.expectEqual(SCOPE_LIMIT, hostedDrawBeginRenderTextureRaw(.{ .handle = target, .height = 16, .width = 16 }));
    for (0..SCOPE_STACK_LIMIT) |_| hostedDrawEndRenderTextureRaw();
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());

    const shader = storeShader(.headless).?;
    abi.increfBox(@ptrCast(shader), SCOPE_STACK_LIMIT);
    for (0..SCOPE_STACK_LIMIT) |_| try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginShaderRaw(.{ .arg0 = shader }));
    try std.testing.expectEqual(SCOPE_LIMIT, hostedDrawBeginShaderRaw(.{ .arg0 = shader }));
    for (0..SCOPE_STACK_LIMIT) |_| hostedDrawEndShaderRaw();
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
}

test "scope kind confusion fails and releases transferred owners" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        // No frame loop here to end, so the retirement queue is drained by
        // hand -- and without a frame's budget, since there is no frame to
        // protect and anything left behind reads as a leak.
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    const shader = storeShader(.headless).?;
    try std.testing.expectEqual(SCOPE_UNAVAILABLE, hostedDrawBeginRenderTextureRaw(.{ .handle = @ptrCast(shader), .height = 16, .width = 16 }));
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    const target = storeRenderTexture(.headless).?;
    try std.testing.expectEqual(SCOPE_UNAVAILABLE, hostedDrawBeginShaderRaw(.{ .arg0 = @ptrCast(target) }));
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
}

test "invalid headless render target dimensions do not consume a heap slot" {
    active_headless = true;
    defer active_headless = false;
    const before = render_texture_heap.active();
    const target = hostedTextureLoadRenderTargetRaw(.{ .height = 0, .width = 160 });
    try std.testing.expectEqual(RESOURCE_ERR_FAILED, target.err);
    try std.testing.expectEqual(INVALID_RESOURCE_TOKEN, target.target.handle.*);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(before, render_texture_heap.active());
}

test "last resource references remain live through owning host operations" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        // No frame loop here to end, so the retirement queue is drained by
        // hand -- and without a frame's budget, since there is no frame to
        // protect and anything left behind reads as a leak.
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    const sound = storeSound(.headless).?;
    hostedAudioPlay(sound);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), sound_heap.active());

    const music = storeMusic(.headless).?;
    _ = hostedAudioMusicLength(music);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), music_heap.active());

    const texture = storeTexture(.{ .headless = .{ .width = 2, .height = 2 } }).?;
    hostedTextureSetFilterRaw(.{ .handle = texture, .height = 2, .width = 2 }, 1);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());

    const shader = storeShader(.headless).?;
    hostedDrawSetShaderFloatRaw(.{ .uniform = .{ .shader = shader, .location = 0 }, .value = 1 });
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());

    const sampler_shader = storeShader(.headless).?;
    const sampler_texture = storeTexture(.{ .headless = .{ .width = 1, .height = 1 } }).?;
    hostedDrawSetShaderTextureRaw(.{
        .texture = .{ .handle = sampler_texture, .height = 1, .width = 1 },
        .uniform = .{ .shader = sampler_shader, .location = 0 },
    });
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());

    const target = storeRenderTexture(.headless).?;
    hostedDrawTextureRaw(.{
        .texture = .{ .handle = target, .height = 8, .width = 8 },
        .dest = .{ .height = 8, .width = 8, .x = 0, .y = 0 },
        .origin = .{ .x = 0, .y = 0 },
        .rotation = 0,
        .source = .{ .height = 8, .width = 8, .x = 0, .y = 0 },
        .tint = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    });
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
}

test "copied shared texture destroys its native resource exactly once after the final reference" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    const handle = storeTexture(.{ .headless = .{ .width = 7, .height = 5 } }).?;
    const original = abi.Texture{ .handle = handle, .height = 5, .width = 7 };
    const copied = original;
    copied.incref(1);
    const destroyed_before = texture_destroy_count;

    original.decref(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 1), texture_heap.active());
    try std.testing.expectEqual(destroyed_before, texture_destroy_count);

    copied.decref(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());
    try std.testing.expectEqual(destroyed_before + 1, texture_destroy_count);

    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(destroyed_before + 1, texture_destroy_count);
}

/// Allocate the real Roc box carried by a resource `stub` value.
///
/// The box is a genuine Roc allocation rather than a fake, so the host's
/// decref of it runs the same path it runs at runtime and the testing allocator
/// reports a leak or a double free either way.
fn allocateTestResourceStub(host: *RocHost) *u64 {
    const handle: *u64 = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(u64), @alignOf(u64), false, host)));
    handle.* = INVALID_RESOURCE_TOKEN;
    return handle;
}

fn allocateTestTextureStub(host: *RocHost, width: f32, height: f32) abi.Texture {
    return .{ .handle = allocateTestResourceStub(host), .width = width, .height = height };
}

/// Take a second reference to a live host resource handle, the way a Roc value
/// copied into two effect calls would. Each hosted effect releases the handle
/// it was passed, so a test that calls two of them against one resource has to
/// hand each its own reference.
fn retainTestResourceBox(handle: *u64) *u64 {
    const refcount: *isize = @ptrFromInt(@intFromPtr(handle) - @sizeOf(isize));
    refcount.* += 1;
    return handle;
}

test "resource-free texture is safe across hosted operations and ordinary deallocation" {
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());

    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    const destroyed_before = texture_destroy_count;
    try std.testing.expect(nativeTextureForToken(INVALID_RESOURCE_TOKEN) == null);

    {
        const scope = PhaseScope.enter(.render);
        defer scope.leave();

        hostedDrawTextureRaw(.{
            .texture = allocateTestTextureStub(&roc_host, 16, 8),
            .dest = .{ .height = 8, .width = 16, .x = 0, .y = 0 },
            .origin = .{ .x = 0, .y = 0 },
            .rotation = 0,
            .source = .{ .height = 8, .width = 16, .x = 0, .y = 0 },
            .tint = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        });

        hostedDrawTextureQuadRaw(.{
            .texture = allocateTestTextureStub(&roc_host, 16, 8),
            .bottom_left = .{ .x = 0, .y = 8 },
            .bottom_right = .{ .x = 16, .y = 8 },
            .q_bottom_left = 1,
            .q_bottom_right = 1,
            .q_top_left = 1,
            .q_top_right = 1,
            .source = .{ .height = 8, .width = 16, .x = 0, .y = 0 },
            .top_left = .{ .x = 0, .y = 0 },
            .top_right = .{ .x = 16, .y = 0 },
            .tint = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        });
    }

    {
        const scope = PhaseScope.enter(.update);
        defer scope.leave();

        hostedTextureSetFilterRaw(allocateTestTextureStub(&roc_host, 16, 8), 1);
        hostedTextureSetWrapRaw(allocateTestTextureStub(&roc_host, 16, 8), 1);

        const whole_err = hostedTextureUpdateRaw(&roc_host, .{
            .pixels = abi.RocListWith(Color, false).empty(),
            .texture = allocateTestTextureStub(&roc_host, 16, 8),
        });
        try std.testing.expectEqual(TEXTURE_UPDATE_NOT_MUTABLE, whole_err);

        const region_err = hostedTextureUpdateRegionRaw(&roc_host, .{
            .pixels = abi.RocListWith(Color, false).empty(),
            .texture = allocateTestTextureStub(&roc_host, 16, 8),
            .height = 1,
            .width = 1,
            .x = 0,
            .y = 0,
        });
        try std.testing.expectEqual(TEXTURE_UPDATE_NOT_MUTABLE, region_err);
    }

    {
        const scope = PhaseScope.enter(.render);
        defer scope.leave();

        headless_tilemap_draw_calls = 0;
        headless_tilemap_tiles = 0;
        headless_tilemap_last_quad = null;
        const texture = allocateTestTextureStub(&roc_host, 16, 8);
        hostedTilemapDrawRaw(&roc_host, headlessTilemapRequest(&roc_host, texture.handle, TILEMAP_SELECTOR_ALL, 0, true));
        try std.testing.expectEqual(@as(usize, 1), headless_tilemap_draw_calls);
        try std.testing.expectEqual(@as(usize, 0), headless_tilemap_tiles);
        try std.testing.expect(headless_tilemap_last_quad == null);
    }

    allocateTestTextureStub(&roc_host, 0, 0).decref(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());
    try std.testing.expectEqual(@as(usize, 0), texture_heap.retiredCount());
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.retiredCount());
    try std.testing.expectEqual(destroyed_before, texture_destroy_count);
}

test "resource-free draw handles are inert, and leave real resources alone" {
    // The Roc side publishes a `stub` for every resource an app can hold in its
    // model -- `Text.font_stub`, `Draw.Shader.stub`, `Draw.RenderTexture.stub`,
    // `Text.Prepared.stub`, `Assets.Store.stub` -- so that a pure test can write
    // a model down. Every resource stub carries the maximum U64 token. The host
    // resolves none of them, refuses the operations they reach, and releases
    // the box exactly once.
    //
    // A real resource of each kind is live throughout, and goes through the
    // same calls itself. Stub traffic must not disturb it, and the operations
    // must still consume exactly the reference they were handed -- which is
    // what a heap built out of zeroed memory could never show.
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    try std.testing.expectEqual(@as(usize, 0), prepared_text_heap.active());

    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    // Stub tokens resolve nowhere. This is the property every stub rests on,
    // and the reason `stub` can be a pure value at all.
    try std.testing.expect(font_heap.get(INVALID_RESOURCE_TOKEN) == null);
    try std.testing.expect(shader_heap.get(INVALID_RESOURCE_TOKEN) == null);
    try std.testing.expect(render_texture_heap.get(INVALID_RESOURCE_TOKEN) == null);
    try std.testing.expect(prepared_text_heap.get(INVALID_RESOURCE_TOKEN) == null);
    try std.testing.expect(store_heap.get(INVALID_RESOURCE_TOKEN) == null);

    const real_shader = storeShader(.headless).?;
    const real_target = storeRenderTexture(.headless).?;

    {
        const scope = PhaseScope.enter(.startup);
        defer scope.leave();

        // A stub font has no metrics to snapshot; the headless answer is the
        // built-in one, and the transferred handle is still released.
        const snapshot = hostedTextFontMetricsRaw(&roc_host, allocateTestResourceStub(&roc_host));
        defer snapshot.glyphs.decref(&roc_host);

        // Preparing text with a stub font is refused rather than silently
        // prepared against the default font, and consumes no heap slot.
        const prepared = hostedTextPrepareRaw(&roc_host, .{
            .font = allocateTestResourceStub(&roc_host),
            .text = abi.RocStr.fromSlice("inert", &roc_host),
            .size = 16,
            .spacing = 1,
        });
        try std.testing.expectEqual(RESOURCE_ERR_FAILED, prepared.err);
        try std.testing.expectEqual(@as(f32, 0), prepared.width);
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        try std.testing.expectEqual(@as(usize, 0), prepared_text_heap.active());

        // A uniform cannot be resolved on a stub shader.
        try std.testing.expectEqual(@as(i32, -1), hostedDrawShaderLocationRaw(&roc_host, .{
            .shader = allocateTestResourceStub(&roc_host),
            .name = abi.RocStr.fromSlice("uTime", &roc_host),
        }));

        // Every store-backed loader reports the read it could not make.
        const store_texture = hostedTextureLoadStoreRaw(&roc_host, .{
            .store = allocateTestResourceStub(&roc_host),
            .path = abi.RocStr.fromSlice("atlas.png", &roc_host),
        });
        try std.testing.expectEqual(STORE_LOAD_ERR_READ, store_texture.err);

        const store_font = hostedTextLoadStoreFontRaw(&roc_host, .{
            .store = allocateTestResourceStub(&roc_host),
            .path = abi.RocStr.fromSlice("body.ttf", &roc_host),
            .size = 16,
        });
        try std.testing.expectEqual(STORE_LOAD_ERR_READ, store_font.err);

        const store_shader = hostedDrawLoadStoreShaderRaw(&roc_host, .{
            .store = allocateTestResourceStub(&roc_host),
            .vertex_path = abi.RocStr.empty(),
            .fragment_path = abi.RocStr.fromSlice("blur.fs", &roc_host),
        });
        try std.testing.expectEqual(STORE_LOAD_ERR_READ, store_shader.err);

        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        try std.testing.expectEqual(@as(usize, 0), font_heap.active());
        try std.testing.expectEqual(@as(usize, 0), texture_heap.active());
    }

    {
        const scope = PhaseScope.enter(.render);
        defer scope.leave();

        // A scope cannot be opened on a stub, and reports the same refusal a
        // released resource would. Nothing is leased, so there is no end call.
        try std.testing.expectEqual(SCOPE_UNAVAILABLE, hostedDrawBeginShaderRaw(.{ .arg0 = allocateTestResourceStub(&roc_host) }));
        try std.testing.expectEqual(@as(usize, 0), shader_lease_count);
        try std.testing.expectEqual(SCOPE_UNAVAILABLE, hostedDrawBeginRenderTextureRaw(.{
            .handle = allocateTestResourceStub(&roc_host),
            .height = 90,
            .width = 160,
        }));
        try std.testing.expectEqual(@as(usize, 0), render_texture_lease_count);
        try std.testing.expectEqual(@as(u8, 0), headless_render_texture_depth);

        // Drawing stub prepared text is skipped, exactly as drawing a released
        // one is: no draw is counted and nothing faults.
        const draws_before = prepared_text_draw_calls;
        hostedDrawPreparedTextRaw(&roc_host, .{
            .prepared = allocateTestResourceStub(&roc_host),
            .pos = .{ .x = 10, .y = 20 },
            .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        });
        try std.testing.expectEqual(draws_before, prepared_text_draw_calls);

        // The real shader and target still open their scopes, and still lease
        // the reference each call was given.
        for (0..3) |_| {
            abi.increfBox(@ptrCast(real_shader), 1);
            try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginShaderRaw(.{ .arg0 = real_shader }));
        }
        try std.testing.expectEqual(@as(u8, 3), headless_shader_depth);
        for (0..3) |_| hostedDrawEndShaderRaw();
        try std.testing.expectEqual(@as(u8, 0), headless_shader_depth);

        abi.increfBox(@ptrCast(real_target), 1);
        try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginRenderTextureRaw(.{ .handle = real_target, .height = 90, .width = 160 }));
        hostedDrawEndRenderTextureRaw();
    }

    // The stub traffic touched no slot, and the real resources are still there.
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 1), shader_heap.active());
    try std.testing.expectEqual(@as(usize, 1), render_texture_heap.active());
    try std.testing.expect(shader_heap.get(real_shader.*) != null);
    try std.testing.expect(render_texture_heap.get(real_target.*) != null);

    releaseResourceBox(&roc_host, real_shader);
    releaseResourceBox(&roc_host, real_target);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
}

test "resource-free audio handles are inert across every sound and music call" {
    // `Audio.Sound.stub` and `Audio.Music.stub` promise that a model built for
    // a pure test can be handed to the platform without playing anything. Every
    // transport call has to reach its unresolvable-handle branch and still
    // release the reference it was passed.
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), sound_heap.active());
    try std.testing.expectEqual(@as(usize, 0), music_heap.active());

    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    try std.testing.expect(sound_heap.get(INVALID_RESOURCE_TOKEN) == null);
    try std.testing.expect(music_heap.get(INVALID_RESOURCE_TOKEN) == null);

    const real_sound = storeSound(.headless).?;
    const real_music = storeMusic(.headless).?;

    {
        const scope = PhaseScope.enter(.update);
        defer scope.leave();

        hostedAudioPlay(allocateTestResourceStub(&roc_host));
        hostedAudioStop(allocateTestResourceStub(&roc_host));
        hostedAudioPause(allocateTestResourceStub(&roc_host));
        hostedAudioResume(allocateTestResourceStub(&roc_host));
        hostedAudioSetVolume(allocateTestResourceStub(&roc_host), 0.5);
        hostedAudioSetPitch(allocateTestResourceStub(&roc_host), 1.5);
        hostedAudioSetPan(allocateTestResourceStub(&roc_host), -0.25);
        try std.testing.expect(!hostedAudioIsPlaying(allocateTestResourceStub(&roc_host)));

        hostedAudioPlayMusic(allocateTestResourceStub(&roc_host));
        hostedAudioStopMusic(allocateTestResourceStub(&roc_host));
        hostedAudioPauseMusic(allocateTestResourceStub(&roc_host));
        hostedAudioResumeMusic(allocateTestResourceStub(&roc_host));
        hostedAudioSetMusicVolume(allocateTestResourceStub(&roc_host), 0.5);
        hostedAudioSetMusicPitch(allocateTestResourceStub(&roc_host), 1.5);
        hostedAudioSetMusicPan(allocateTestResourceStub(&roc_host), -0.25);
        hostedAudioSetMusicLooping(allocateTestResourceStub(&roc_host), true);
        hostedAudioSeekMusic(allocateTestResourceStub(&roc_host), 12.5);

        // A stream that does not exist has no length and has played nothing,
        // rather than reporting whatever the last real stream did.
        try std.testing.expect(!hostedAudioIsMusicPlaying(allocateTestResourceStub(&roc_host)));
        try std.testing.expectEqual(@as(f32, 0), hostedAudioMusicLength(allocateTestResourceStub(&roc_host)));
        try std.testing.expectEqual(@as(f32, 0), hostedAudioMusicTimePlayed(allocateTestResourceStub(&roc_host)));

        // The real resources go through the same calls. Each consumes the
        // reference it was handed, so each call gets its own.
        for (0..4) |_| {
            abi.increfBox(@ptrCast(real_sound), 1);
            hostedAudioStop(real_sound);
            abi.increfBox(@ptrCast(real_music), 1);
            hostedAudioPauseMusic(real_music);
        }
    }

    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 1), sound_heap.active());
    try std.testing.expectEqual(@as(usize, 1), music_heap.active());
    try std.testing.expect(sound_heap.get(real_sound.*) != null);
    try std.testing.expect(music_heap.get(real_music.*) != null);

    releaseResourceBox(&roc_host, real_sound);
    releaseResourceBox(&roc_host, real_music);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), sound_heap.active());
    try std.testing.expectEqual(@as(usize, 0), music_heap.active());
}

fn headlessTilemapRequest(
    host: *RocHost,
    texture: *u64,
    selector_kind: u8,
    selector_value: u64,
    culled: bool,
) abi.HostABITilemap_drawArgs {
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
    const layers = [_]abi.HostABITilemap_drawArg0Layers{
        .{ .gid_count = 6, .gid_start = 0, .height = 2, .width = 3, .role = 0, .visible = true },
        .{ .gid_count = 6, .gid_start = 6, .height = 2, .width = 3, .role = TILEMAP_ROLE_HIDDEN, .visible = true },
    };
    const tilesets = [_]abi.HostABITilemap_drawArg0Tilesets{
        .{
            .columns = 2,
            .first_gid = 1,
            .texture = .{ .handle = texture, .height = 16, .width = 16 },
            .tile_height = 8,
            .tile_width = 8,
        },
    };
    return .{
        .culled = culled,
        .gids = abi.RocListWith(u64, false).fromSlice(&gids, host),
        .layers = abi.RocListWith(abi.HostABITilemap_drawArg0Layers, false).fromSlice(&layers, host),
        .tilesets = abi.RocList(abi.HostABITilemap_drawArg0Tilesets).fromSlice(&tilesets, host),
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

fn headlessTextureInstances(host: *RocHost, count: usize) abi.RocListWith(abi.HostABIDraw_draw_texture_instancesArg0Instances, false) {
    const list = abi.RocListWith(abi.HostABIDraw_draw_texture_instancesArg0Instances, false).allocate(count, host);
    const items = list.elements_ptr.?;
    for (0..count) |index| {
        const offset: f32 = @floatFromInt(index);
        items[index] = .{
            .source = .{ .x = 0, .y = 0, .width = 16, .height = 8 },
            .dest = .{ .x = offset * 16, .y = 0, .width = 16, .height = 8 },
            .origin = .{ .x = 0, .y = 0 },
            .rotation = 0,
            .tint = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        };
    }
    return list;
}

test "one instance batch crosses once and releases its texture and list" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    headless_texture_instance_batches = 0;
    headless_texture_instances = 0;
    const phase = PhaseScope.enter(.render);
    defer {
        phase.leave();
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    const texture = storeTexture(.{ .headless = .{ .width = 16, .height = 8 } }).?;
    hostedDrawTextureInstancesRaw(&roc_host, .{
        .texture = .{ .handle = texture, .width = 16, .height = 8 },
        .instances = headlessTextureInstances(&roc_host, 4),
    });
    try std.testing.expectEqual(@as(usize, 1), headless_texture_instance_batches);
    try std.testing.expectEqual(@as(usize, 4), headless_texture_instances);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());

    // A handle of the wrong kind is the same failure an app sees after a
    // release: nothing is drawn, and both transferred references still go back.
    const shader = storeShader(.headless).?;
    hostedDrawTextureInstancesRaw(&roc_host, .{
        .texture = .{ .handle = shader, .width = 1, .height = 1 },
        .instances = headlessTextureInstances(&roc_host, 3),
    });
    try std.testing.expectEqual(@as(usize, 1), headless_texture_instance_batches);
    try std.testing.expectEqual(@as(usize, 4), headless_texture_instances);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
}

test "an instance batch called from update is rejected" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    const phase = PhaseScope.enter(.update);
    last_phase_violation = null;
    defer {
        last_phase_violation = null;
        phase.leave();
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    const texture = storeTexture(.{ .headless = .{ .width = 16, .height = 8 } }).?;
    hostedDrawTextureInstancesRaw(&roc_host, .{
        .texture = .{ .handle = texture, .width = 16, .height = 8 },
        .instances = headlessTextureInstances(&roc_host, 2),
    });

    const violation = last_phase_violation orelse return error.OperationWasNotRejected;
    try std.testing.expectEqualStrings("Draw.texture_instances!", violation.operation);
    try std.testing.expect(violation.allowed.eql(during_render));
    try std.testing.expectEqual(Phase.update, violation.actual);
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
        // No frame loop here to end, so the retirement queue is drained by
        // hand -- and without a frame's budget, since there is no frame to
        // protect and anything left behind reads as a leak.
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    const texture = storeTexture(.{ .headless = .{ .width = 16, .height = 8 } }).?;
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
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());
}

test "role batching cannot select hidden layers but named selection can" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        // No frame loop here to end, so the retirement queue is drained by
        // hand -- and without a frame's budget, since there is no frame to
        // protect and anything left behind reads as a leak.
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    headless_tilemap_tiles = 0;
    const rejected_texture = storeTexture(.{ .headless = .{ .width = 16, .height = 8 } }).?;
    hostedTilemapDrawRaw(&roc_host, headlessTilemapRequest(&roc_host, rejected_texture, TILEMAP_SELECTOR_ROLE, TILEMAP_ROLE_HIDDEN, false));
    try std.testing.expectEqual(@as(usize, 0), headless_tilemap_tiles);

    const named_texture = storeTexture(.{ .headless = .{ .width = 16, .height = 8 } }).?;
    hostedTilemapDrawRaw(&roc_host, headlessTilemapRequest(&roc_host, named_texture, TILEMAP_SELECTOR_LAYER, 1, false));
    try std.testing.expectEqual(@as(usize, 6), headless_tilemap_tiles);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());
}

test "render target textures report not mutable and release ownership" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        // No frame loop here to end, so the retirement queue is drained by
        // hand -- and without a frame's budget, since there is no frame to
        // protect and anything left behind reads as a leak.
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    const target = storeRenderTexture(.headless).?;
    const err = hostedTextureUpdateRaw(&roc_host, .{
        .pixels = abi.RocListWith(Color, false).empty(),
        .texture = .{ .handle = target, .height = 4, .width = 4 },
    });
    try std.testing.expectEqual(TEXTURE_UPDATE_NOT_MUTABLE, err);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
}

test "every fixed resource heap reports capacity plus one as ResourceLimit" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        // No frame loop here to end, so the retirement queue is drained by
        // hand -- and without a frame's budget, since there is no frame to
        // protect and anything left behind reads as a leak.
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
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

    var textures: [128]*u64 = undefined;
    for (&textures) |*texture| texture.* = storeTexture(.{ .headless = .{ .width = 1, .height = 1 } }).?;
    try std.testing.expectEqual(RESOURCE_ERR_LIMIT, hostedTextureGenerateColorRaw(.{
        .height = 1,
        .width = 1,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    }).err);
    for (textures) |texture| releaseResourceBox(&roc_host, texture);

    var targets: [32]*u64 = undefined;
    for (&targets) |*target| target.* = storeRenderTexture(.headless).?;
    try std.testing.expectEqual(RESOURCE_ERR_LIMIT, hostedTextureLoadRenderTargetRaw(.{ .height = 1, .width = 1 }).err);
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
        const result = hostedTextPrepareRaw(&roc_host, .{
            .font = defaultFontHandle(),
            .text = abi.RocStr.empty(),
            .size = 16,
            .spacing = 1,
        });
        try std.testing.expectEqual(RESOURCE_ERR_NONE, result.err);
        prepared.* = result.prepared;
    }
    try std.testing.expectEqual(RESOURCE_ERR_LIMIT, hostedTextPrepareRaw(&roc_host, .{
        .font = defaultFontHandle(),
        .text = abi.RocStr.empty(),
        .size = 16,
        .spacing = 1,
    }).err);
    for (prepared_texts) |prepared| releaseResourceBox(&roc_host, prepared);

    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), sound_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), music_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), prepared_text_heap.active());
}

fn storeFont(resource: FontResource) ?*u64 {
    return font_heap.insert(0, resource) orelse {
        var rejected = resource;
        destroyFont(&rejected);
        return null;
    };
}

fn defaultFontHandle() *u64 {
    return &default_font_box.token;
}

test "the built-in font is token zero and consumes no font heap slot" {
    try std.testing.expectEqual(@as(u64, 0), defaultFontHandle().*);
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());
}

fn releaseStartupFontHandle(host: *RocHost) void {
    if (startup_font_handle) |handle| releaseResourceBox(host, handle);
    startup_font_handle = null;
}

fn configuredStartupFont(host: *RocHost) abi.HostABIText_load_font_bytesRetRecord {
    enforcePhase("App.Startup.default_font!", during_startup);
    const effect = EffectScope.begin("App.Startup.default_font!", startup_font_config.path.len);
    defer effect.end();
    if (startup_font_config.path.len == 0) return .{ .font = defaultFontHandle(), .err = RESOURCE_ERR_NONE };
    if (!isSafeStoreRelativePath(startup_font_config.path)) return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_PATH };
    if (startup_font_config.size <= 0) return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_DECODE };

    if (startup_font_handle) |handle| {
        abi.increfBox(@ptrCast(handle), 1);
        return .{ .font = handle, .err = RESOURCE_ERR_NONE };
    }

    const file_type = fontFileTypeFromPath(startup_font_config.path) orelse return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_DECODE };
    const allocator = allocatorFromHost(host);
    const bytes = std.Io.Dir.cwd().readFileAlloc(mainThreadIo(), startup_font_config.path, allocator, .limited(MAX_ASSET_FILE_BYTES)) catch |err| {
        return .{
            .font = invalidResourceHandle(),
            .err = switch (err) {
                error.FileNotFound => STORE_LOAD_ERR_NOT_FOUND,
                else => STORE_LOAD_ERR_READ,
            },
        };
    };
    defer allocator.free(bytes);

    const handle = if (headlessMode())
        storeFont(.headless)
    else blk: {
        const font = raylib.loadFontFromMemory(file_type, bytes, startup_font_config.size) orelse return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_DECODE };
        break :blk storeFont(.{ .native = font });
    };
    const stored = handle orelse return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_LIMIT };
    startup_font_handle = stored;
    abi.increfBox(@ptrCast(stored), 1);
    return .{ .font = stored, .err = RESOURCE_ERR_NONE };
}

fn exportedTextStartupDefaultFontRaw() callconv(.c) abi.HostABIText_load_font_bytesRetRecord {
    return configuredStartupFont(activeHost());
}

test "configured startup font loads once and returns retained aliases" {
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    startup_font_config = .{ .path = "examples/live_plot/assets/fonts/LiberationSans-Regular.ttf", .size = 24 };
    const phase = PhaseScope.enter(.startup);
    defer {
        phase.leave();
        font_heap.deinitAll();
        startup_font_handle = null;
        startup_font_config = .{};
        active_headless = false;
        active_roc_host = null;
    }

    const first = configuredStartupFont(&roc_host);
    const second = configuredStartupFont(&roc_host);
    try std.testing.expectEqual(RESOURCE_ERR_NONE, first.err);
    try std.testing.expectEqual(RESOURCE_ERR_NONE, second.err);
    try std.testing.expectEqual(first.font, second.font);
    try std.testing.expectEqual(@as(usize, 1), font_heap.active());
    releaseResourceBox(&roc_host, first.font);
    releaseResourceBox(&roc_host, second.font);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 1), font_heap.active());
}

fn storePreparedText(resource: PreparedTextResource) ?*u64 {
    return prepared_text_heap.insert(0, resource) orelse {
        var rejected = resource;
        destroyPreparedText(&rejected);
        return null;
    };
}

fn storeTexture(resource: TextureResource) ?*u64 {
    return texture_heap.insert(0, resource) orelse {
        var rejected = resource;
        destroyTexture(&rejected);
        return null;
    };
}

fn invalidTexture() abi.Texture {
    return .{ .handle = &invalid_texture_box.payload, .height = 0, .width = 0 };
}

fn texturePixelCount(width: i32, height: i32) ?usize {
    if (width <= 0 or height <= 0) return null;
    return std.math.mul(usize, @intCast(width), @intCast(height)) catch null;
}

test "a structurally valid texture upload is not refused for host capacity" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    const scope = PhaseScope.enter(.update);
    defer {
        scope.leave();
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    // This exceeds the former 4 MiB per-cycle budget. The command owns the
    // explicit payload already, so capacity must not turn it into a no-op.
    const width: i32 = 1025;
    const height: i32 = 1024;
    const pixels = try std.testing.allocator.alloc(Color, @as(usize, @intCast(width * height)));
    defer std.testing.allocator.free(pixels);
    @memset(pixels, .{ .r = 1, .g = 2, .b = 3, .a = 255 });
    const handle = storeTexture(.{ .headless = .{ .width = width, .height = height } }).?;
    const result = hostedTextureUpdateRaw(&roc_host, .{
        .pixels = abi.RocListWith(Color, false).fromSlice(pixels, &roc_host),
        .texture = .{ .handle = handle, .height = @floatFromInt(height), .width = @floatFromInt(width) },
    });
    try std.testing.expectEqual(TEXTURE_UPDATE_OK, result);
}

test "texture pixel count validates dimensions" {
    try std.testing.expectEqual(@as(?usize, 16), texturePixelCount(4, 4));
    try std.testing.expectEqual(@as(?usize, null), texturePixelCount(0, 4));
    try std.testing.expectEqual(@as(?usize, null), texturePixelCount(4, -1));
}

test "texture updates validate native dimensions instead of public metadata" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    const scope = PhaseScope.enter(.update);
    defer {
        scope.leave();
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    const pixels = [_]Color{.{ .r = 1, .g = 2, .b = 3, .a = 255 }} ** 6;
    const whole_handle = storeTexture(.{ .headless = .{ .width = 2, .height = 3 } }).?;
    const whole_err = hostedTextureUpdateRaw(&roc_host, .{
        .pixels = abi.RocListWith(Color, false).fromSlice(&pixels, &roc_host),
        .texture = .{ .handle = whole_handle, .height = 99, .width = 99 },
    });
    try std.testing.expectEqual(TEXTURE_UPDATE_OK, whole_err);

    const region_handle = storeTexture(.{ .headless = .{ .width = 2, .height = 3 } }).?;
    const region_err = hostedTextureUpdateRegionRaw(&roc_host, .{
        .pixels = abi.RocListWith(Color, false).fromSlice(pixels[0..2], &roc_host),
        .texture = .{ .handle = region_handle, .height = 99, .width = 99 },
        .height = 1,
        .width = 2,
        .x = 1,
        .y = 0,
    });
    try std.testing.expectEqual(TEXTURE_UPDATE_OUT_OF_BOUNDS, region_err);
}

fn imageFileType(format: u8) ?[*:0]const u8 {
    return switch (format) {
        0 => ".png",
        1 => ".jpg",
        2 => ".bmp",
        3 => ".tga",
        4 => ".gif",
        5 => ".qoi",
        else => null,
    };
}

fn fontFileType(format: u8) ?[*:0]const u8 {
    return switch (format) {
        0 => ".ttf",
        1 => ".otf",
        else => null,
    };
}

/// Portable store-relative asset names use `/` regardless of host OS. We
/// reject backslashes too: accepting them would make a Windows-only traversal
/// spelling and would undermine the portable manifest namespace.
fn isSafeStoreRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn isSafeRootRelativePath(path: []const u8) bool {
    return isSafeStoreRelativePath(path);
}

fn openStoreRootRelative(io: std.Io, base: std.Io.Dir, root: []const u8) !std.Io.Dir {
    if (!isSafeRootRelativePath(root)) return error.InvalidRootPath;
    return base.openDir(io, root, .{});
}

fn storeErrorDescription(err: u8) []const u8 {
    return switch (err) {
        STORE_ERR_ROOT_NOT_FOUND => "root directory was not found",
        STORE_ERR_ROOT_NOT_DIRECTORY => "root is not a directory",
        STORE_ERR_ROOT_UNREADABLE => "root directory is not readable",
        STORE_ERR_INVALID_ROOT_PATH => "invalid root location",
        STORE_ERR_INVALID_EXPECTED_CONTENT_HASH => "expected SHA-256 is not 64 hexadecimal characters",
        STORE_ERR_MANIFEST_MISSING => "required roc-assets.manifest was not found",
        STORE_ERR_MANIFEST_UNREADABLE => "required roc-assets.manifest could not be read",
        STORE_ERR_MANIFEST_MALFORMED => "roc-assets.manifest is malformed",
        STORE_ERR_ASSET_SET_MISMATCH => "manifest asset_set does not match",
        STORE_ERR_SCHEMA_MISMATCH => "manifest schema does not match",
        STORE_ERR_CONTENT_VERSION_MISMATCH => "manifest content_version does not match",
        STORE_ERR_CONTENT_HASH_MISMATCH => "manifest content_sha256 does not match",
        STORE_ERR_LIMIT => "asset-store resource limit reached",
        else => "unknown asset-store error",
    };
}

fn storeOpenError(error_value: anyerror) u8 {
    return switch (error_value) {
        error.FileNotFound => STORE_ERR_ROOT_NOT_FOUND,
        error.NotDir => STORE_ERR_ROOT_NOT_DIRECTORY,
        error.AccessDenied => STORE_ERR_ROOT_UNREADABLE,
        else => STORE_ERR_ROOT_UNREADABLE,
    };
}

fn openStoreDirectoryIn(io: std.Io, allocator: std.mem.Allocator, location_kind: u8, root: []const u8) !std.Io.Dir {
    switch (location_kind) {
        // The executable directory is opened first, then the configured root
        // is opened through that handle. This remains CWD-independent even if
        // another library changes CWD later in the process lifetime.
        0 => {
            const executable_dir_path = try std.process.executableDirPathAlloc(io, allocator);
            defer allocator.free(executable_dir_path);
            const executable_dir = try std.Io.Dir.openDirAbsolute(io, executable_dir_path, .{});
            defer executable_dir.close(io);
            return openStoreRootRelative(io, executable_dir, root);
        },
        1 => {
            if (!isSafeRootRelativePath(root)) return error.InvalidRootPath;
            return std.Io.Dir.cwd().openDir(io, root, .{});
        },
        2 => {
            if (!std.fs.path.isAbsolute(root) or std.mem.indexOfScalar(u8, root, 0) != null) return error.InvalidRootPath;
            return std.Io.Dir.openDirAbsolute(io, root, .{});
        },
        else => return error.InvalidRootPath,
    }
}

/// The outcome of one directory open or one store-relative read, carried back
/// from a blocking worker as plain host data.
const StoreDirOpen = union(enum) { dir: std.Io.Dir, failed: anyerror };
const StoreDirRead = union(enum) { bytes: []u8, failed: anyerror };

/// Open a store root, and read a file beneath one, on zio's blocking pool.
///
/// These take the same path `writeFileWaiting` does rather than the runtime's
/// own file backend, for a reason of its own: a store keeps its directory
/// handle for the life of the store and closes it on the frame thread, so
/// handing that descriptor to the event loop for one read and to the blocking
/// implementation later would mix two ownership models over one fd. The pool
/// parks the calling task exactly as the event loop would, and the worker sees
/// only the host-owned directory, path and bytes -- never a Roc value.
fn openStoreDirectoryBlocking(allocator: std.mem.Allocator, location_kind: u8, root: []const u8) StoreDirOpen {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const dir = openStoreDirectoryIn(threaded.io(), allocator, location_kind, root) catch |err| return .{ .failed = err };
    return .{ .dir = dir };
}

fn openStoreDirectoryWaiting(allocator: std.mem.Allocator, location_kind: u8, root: []const u8) StoreDirOpen {
    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("store open", 0);
    defer AppTasks.observeResume(park, "store open");
    const rt = AppTasks.currentRuntime() orelse return openStoreDirectoryBlocking(allocator, location_kind, root);
    var blocking = rt.spawnBlocking(openStoreDirectoryBlocking, .{ allocator, location_kind, root }) catch
        return openStoreDirectoryBlocking(allocator, location_kind, root);
    return blocking.join();
}

fn readDirFileBlocking(allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, limit: usize) StoreDirRead {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const bytes = dir.readFileAlloc(threaded.io(), path, allocator, .limited(limit)) catch |err| return .{ .failed = err };
    return .{ .bytes = bytes };
}

fn readDirFileWaiting(allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, limit: usize) StoreDirRead {
    const scope = WaitScope.enter();
    defer scope.leave();
    const park = AppTasks.observePark("store read", 0);
    defer AppTasks.observeResume(park, "store read");
    const rt = AppTasks.currentRuntime() orelse return readDirFileBlocking(allocator, dir, path, limit);
    var blocking = rt.spawnBlocking(readDirFileBlocking, .{ allocator, dir, path, limit }) catch
        return readDirFileBlocking(allocator, dir, path, limit);
    return blocking.join();
}

const ParsedAssetManifest = struct {
    asset_set: ?[]const u8 = null,
    schema: ?u32 = null,
    content_version: ?u32 = null,
    content_hash: ?[]const u8 = null,
};

fn manifestValue(raw: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, raw, " \t\r");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    return if (value.len == 0) null else value;
}

fn parseAssetManifest(bytes: []const u8) ?ParsedAssetManifest {
    var manifest = ParsedAssetManifest{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const equals_at = std.mem.indexOfScalar(u8, line, '=') orelse return null;
        const key = std.mem.trim(u8, line[0..equals_at], " \t");
        const value = manifestValue(line[equals_at + 1 ..]) orelse return null;
        if (std.mem.eql(u8, key, "asset_set")) {
            if (manifest.asset_set != null) return null;
            manifest.asset_set = value;
        } else if (std.mem.eql(u8, key, "schema")) {
            if (manifest.schema != null) return null;
            manifest.schema = std.fmt.parseInt(u32, value, 10) catch return null;
        } else if (std.mem.eql(u8, key, "content_version")) {
            if (manifest.content_version != null) return null;
            manifest.content_version = std.fmt.parseInt(u32, value, 10) catch return null;
        } else if (std.mem.eql(u8, key, "content_sha256")) {
            if (manifest.content_hash != null or !isSha256Hex(value)) return null;
            manifest.content_hash = value;
        }
    }
    return manifest;
}

fn isSha256Hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        const hex = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f') or (byte >= 'A' and byte <= 'F');
        if (!hex) return false;
    }
    return true;
}

fn matchAssetManifest(manifest: ParsedAssetManifest, asset_set: []const u8, schema: u32, content_version: u32, expected_hash: ?[]const u8) u8 {
    if (manifest.asset_set == null or !std.mem.eql(u8, manifest.asset_set.?, asset_set)) return STORE_ERR_ASSET_SET_MISMATCH;
    if (manifest.schema == null or manifest.schema.? != schema) return STORE_ERR_SCHEMA_MISMATCH;
    if (manifest.content_version == null or manifest.content_version.? != content_version) return STORE_ERR_CONTENT_VERSION_MISMATCH;
    if (expected_hash) |hash| {
        if (manifest.content_hash == null or !std.ascii.eqlIgnoreCase(manifest.content_hash.?, hash)) return STORE_ERR_CONTENT_HASH_MISMATCH;
    }
    return STORE_ERR_NONE;
}

fn expectedManifestHash(args: abi.HostABIAssets_open_storeArgs) union(enum) { any, hash: []const u8, invalid } {
    const hash = args.content_hash.asSlice();
    return switch (args.content_hash_mode) {
        0 => if (hash.len == 0) .any else .invalid,
        1 => if (isSha256Hex(hash)) .{ .hash = hash } else .invalid,
        else => .invalid,
    };
}

fn validateStoreManifest(allocator: std.mem.Allocator, root: *std.Io.Dir, args: abi.HostABIAssets_open_storeArgs) u8 {
    if (!args.manifest_required) return STORE_ERR_NONE;
    const bytes = switch (readDirFileWaiting(allocator, root.*, "roc-assets.manifest", MAX_ASSET_MANIFEST_BYTES)) {
        .failed => |err| return switch (err) {
            error.FileNotFound => STORE_ERR_MANIFEST_MISSING,
            else => STORE_ERR_MANIFEST_UNREADABLE,
        },
        .bytes => |value| value,
    };
    defer allocator.free(bytes);
    const manifest = parseAssetManifest(bytes) orelse return STORE_ERR_MANIFEST_MALFORMED;
    const expected_hash: ?[]const u8 = switch (expectedManifestHash(args)) {
        .any => null,
        .hash => |hash| hash,
        .invalid => return STORE_ERR_INVALID_EXPECTED_CONTENT_HASH,
    };
    return matchAssetManifest(manifest, args.asset_set.asSlice(), args.schema, args.content_version, expected_hash);
}

fn reportStoreOpenFailure(code: u8, configured_root: []const u8, opened_root: ?*const std.Io.Dir) void {
    if (opened_root) |root| {
        var resolved: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (root.realPath(mainThreadIo(), &resolved)) |length| {
            std.debug.print("roc-ray: asset store startup validation failed ({s}) at resolved root \"{s}\"\n", .{ storeErrorDescription(code), resolved[0..length] });
            return;
        } else |_| {}
    }
    std.debug.print("roc-ray: asset store startup validation failed ({s}) at configured root \"{s}\"\n", .{ storeErrorDescription(code), configured_root });
}

test "asset store paths are portable and cannot lexically escape their root" {
    try std.testing.expect(isSafeStoreRelativePath("textures/floor.png"));
    try std.testing.expect(!isSafeStoreRelativePath(""));
    try std.testing.expect(!isSafeStoreRelativePath("/etc/passwd"));
    try std.testing.expect(!isSafeStoreRelativePath("textures/../secret.png"));
    try std.testing.expect(!isSafeStoreRelativePath("textures/./floor.png"));
    try std.testing.expect(!isSafeStoreRelativePath("textures//floor.png"));
    try std.testing.expect(!isSafeStoreRelativePath("textures/"));
    try std.testing.expect(!isSafeStoreRelativePath(".."));
    try std.testing.expect(!isSafeStoreRelativePath("textures\\floor.png"));
    try std.testing.expect(!isSafeStoreRelativePath("textures\x00floor.png"));
}

test "executable-relative asset roots resolve from the opened executable directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "installed/assets");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "installed/assets/sentinel", .data = "not from CWD" });
    const executable_dir = try tmp.dir.openDir(std.testing.io, "installed", .{});
    defer executable_dir.close(std.testing.io);
    var root = try openStoreRootRelative(std.testing.io, executable_dir, "assets");
    defer root.close(std.testing.io);
    const bytes = try root.readFileAlloc(std.testing.io, "sentinel", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("not from CWD", bytes);
}

test "asset manifests compare declared identity without walking loose files" {
    const hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const manifest = parseAssetManifest(
        "asset_set = \"screwbot\"\n" ++
            "schema = 1\n" ++
            "content_version = 4\n" ++
            "content_sha256 = \"" ++ hash ++ "\"\n",
    ).?;
    try std.testing.expectEqual(STORE_ERR_NONE, matchAssetManifest(manifest, "screwbot", 1, 4, hash));
    try std.testing.expectEqual(STORE_ERR_NONE, matchAssetManifest(manifest, "screwbot", 1, 4, null));
    try std.testing.expectEqual(STORE_ERR_CONTENT_HASH_MISMATCH, matchAssetManifest(manifest, "screwbot", 1, 4, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"));
    try std.testing.expectEqual(STORE_ERR_SCHEMA_MISMATCH, matchAssetManifest(manifest, "screwbot", 2, 4, hash));
    try std.testing.expect(parseAssetManifest("asset_set = x\nschema = 1\ncontent_version = 4\ncontent_sha256 = invalid\n") == null);
}

test "asset store owns its directory capability through typed ARC" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "asset.txt", .data = "owned by store" });

    const store_dir = try tmp.parent_dir.openDir(std.testing.io, &tmp.sub_path, .{});
    var heap: StoreHeap = .{};
    const payload = heap.insert(0, .{ .root = store_dir }).?;
    const token = payload.*;
    const bytes = switch (readStoreAsset(std.testing.allocator, heap.get(token).?, "asset.txt")) {
        .bytes => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("owned by store", bytes);

    const base: *isize = @ptrFromInt(@intFromPtr(payload) - @sizeOf(isize));
    base.* = 0;
    try std.testing.expectEqual(host_resource.DeallocRoute.deallocated, heap.routeDealloc(base));
    try std.testing.expectEqual(@as(usize, 1), heap.retiredCount());
    try std.testing.expectEqual(@as(usize, 1), heap.drainRetired(1));
    try std.testing.expectEqual(@as(usize, 0), heap.active());
}

fn testStoreOpenArgs(host: *RocHost, root: []const u8, manifest_required: bool, content_hash_mode: u8, content_hash: []const u8) abi.HostABIAssets_open_storeArgs {
    return .{
        .asset_set = abi.RocStr.fromSlice("test-assets", host),
        .content_hash = abi.RocStr.fromSlice(content_hash, host),
        .root = abi.RocStr.fromSlice(root, host),
        .content_version = 1,
        .schema = 1,
        .content_hash_mode = content_hash_mode,
        .location_kind = 1,
        .manifest_required = manifest_required,
    };
}

test "store startup failures close an untransferred root and successful insertion transfers it once" {
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), store_heap.active());
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    const startup = PhaseScope.enter(.startup);
    defer startup.leave();
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        store_heap.deinitAll();
    }

    // Invalid expected hashes are rejected before trying to open the root.
    const invalid_hash = hostedAssetsOpenStoreRaw(&roc_host, testStoreOpenArgs(&roc_host, "does-not-exist", false, 1, "not-a-sha"));
    try std.testing.expectEqual(STORE_ERR_INVALID_EXPECTED_CONTENT_HASH, invalid_hash.err);
    try std.testing.expectEqual(@as(usize, 0), store_heap.active());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "roc-assets.manifest", .data = "not a manifest" });
    var root_path: [256]u8 = undefined;
    const relative_root = try std.fmt.bufPrint(&root_path, testing_tmp_prefix ++ "{s}", .{tmp.sub_path});
    const malformed = hostedAssetsOpenStoreRaw(&roc_host, testStoreOpenArgs(&roc_host, relative_root, true, 0, ""));
    try std.testing.expectEqual(STORE_ERR_MANIFEST_MALFORMED, malformed.err);
    // The root was opened to read the manifest, then explicitly closed rather
    // than leaking because this hosted function returns an ABI record.
    try std.testing.expectEqual(@as(usize, 0), store_heap.active());

    const opened = hostedAssetsOpenStoreRaw(&roc_host, testStoreOpenArgs(&roc_host, relative_root, false, 0, ""));
    try std.testing.expectEqual(STORE_ERR_NONE, opened.err);
    try std.testing.expectEqual(@as(usize, 1), store_heap.active());
    // This is the one transferred reference. Its final release retires, then
    // closes, exactly one directory resource.
    const base: *isize = @ptrFromInt(@intFromPtr(opened.store) - @sizeOf(isize));
    base.* = 0;
    try std.testing.expectEqual(host_resource.DeallocRoute.deallocated, store_heap.routeDealloc(base));
    try std.testing.expectEqual(@as(usize, 1), store_heap.retiredCount());
    try std.testing.expectEqual(@as(usize, 1), store_heap.drainRetired(1));
    try std.testing.expectEqual(@as(usize, 0), store_heap.active());

    // A full heap must reject a newly opened root without retaining that extra
    // OS directory handle. The observable heap count stays at capacity.
    var held: [16]*u64 = undefined;
    for (&held) |*slot| {
        const dir = try tmp.parent_dir.openDir(std.testing.io, &tmp.sub_path, .{});
        slot.* = store_heap.insert(0, .{ .root = dir }).?;
    }
    const limited = hostedAssetsOpenStoreRaw(&roc_host, testStoreOpenArgs(&roc_host, relative_root, false, 0, ""));
    try std.testing.expectEqual(STORE_ERR_LIMIT, limited.err);
    try std.testing.expectEqual(@as(usize, 16), store_heap.active());
    store_heap.deinitAll();
    try std.testing.expectEqual(@as(usize, 0), store_heap.active());
}

test "opening a store and loading a texture from it wait rather than load" {
    // Both reach the filesystem, so both belong where waiting is defined: a
    // task, where they park it, or `init!`, where they block startup. Called
    // from `update!` they would put a disk read inside the frame, which is the
    // hole this guard closes.
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        last_phase_violation = null;
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        store_heap.deinitAll();
        texture_heap.deinitAll();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logo.png", .data = "not decoded in headless tests" });
    var root_path: [256]u8 = undefined;
    const relative_root = try std.fmt.bufPrint(&root_path, testing_tmp_prefix ++ "{s}", .{tmp.sub_path});

    {
        const update = PhaseScope.enter(.update);
        defer update.leave();
        last_phase_violation = null;
        _ = hostedAssetsOpenStoreRaw(&roc_host, testStoreOpenArgs(&roc_host, relative_root, false, 0, ""));
        const violation = last_phase_violation orelse return error.OperationWasNotRejected;
        try std.testing.expectEqualStrings("Assets.Store.open!", violation.operation);
        try std.testing.expect(violation.allowed.eql(during_wait));
        try std.testing.expectEqual(Phase.update, violation.actual);
    }

    // A task is the other half of the waiting set, and the one an app reaches
    // for once startup is over: the same call there succeeds.
    const task = PhaseScope.enter(.task);
    defer task.leave();
    last_phase_violation = null;
    const opened = hostedAssetsOpenStoreRaw(&roc_host, testStoreOpenArgs(&roc_host, relative_root, false, 0, ""));
    try std.testing.expectEqual(STORE_ERR_NONE, opened.err);
    try std.testing.expect(last_phase_violation == null);

    {
        const update = PhaseScope.enter(.update);
        defer update.leave();
        last_phase_violation = null;
        _ = hostedTextureLoadStoreRaw(&roc_host, .{
            .store = allocateTestResourceStub(&roc_host),
            .path = abi.RocStr.fromSlice("logo.png", &roc_host),
        });
        const violation = last_phase_violation orelse return error.OperationWasNotRejected;
        try std.testing.expectEqualStrings("Assets.load_texture!", violation.operation);
        try std.testing.expect(violation.allowed.eql(during_wait));
        try std.testing.expectEqual(Phase.update, violation.actual);
    }

    last_phase_violation = null;
    const loaded = hostedTextureLoadStoreRaw(&roc_host, .{
        .store = opened.store,
        .path = abi.RocStr.fromSlice("logo.png", &roc_host),
    });
    try std.testing.expectEqual(STORE_ERR_NONE, loaded.err);
    try std.testing.expect(last_phase_violation == null);
    loaded.texture.decref(&roc_host);
}

fn byteListRefcount(list: abi.RocListWith(u8, false)) *isize {
    return @ptrFromInt(@intFromPtr(list.elements_ptr.?) - @sizeOf(isize));
}

test "embedded texture and font bytes are consumed exactly once" {
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    const startup = PhaseScope.enter(.startup);
    defer startup.leave();
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        texture_heap.deinitAll();
        font_heap.deinitAll();
    }

    const texture_bytes = abi.RocListWith(u8, false).fromSlice("not decoded in headless tests", &roc_host);
    texture_bytes.incref(1); // caller keeps one reference while host consumes one
    const texture_rc = byteListRefcount(texture_bytes);
    try std.testing.expectEqual(@as(isize, 2), texture_rc.*);
    const texture = hostedTextureLoadBytesRaw(&roc_host, .{ .bytes = texture_bytes, .format = 0 });
    try std.testing.expectEqual(RESOURCE_ERR_NONE, texture.err);
    try std.testing.expectEqual(@as(isize, 1), texture_rc.*);
    texture.texture.decref(&roc_host);
    texture_bytes.decref(&roc_host);

    const bad_texture_bytes = abi.RocListWith(u8, false).fromSlice("bad format", &roc_host);
    bad_texture_bytes.incref(1);
    const bad_texture_rc = byteListRefcount(bad_texture_bytes);
    try std.testing.expectEqual(RESOURCE_ERR_FAILED, hostedTextureLoadBytesRaw(&roc_host, .{ .bytes = bad_texture_bytes, .format = 99 }).err);
    try std.testing.expectEqual(@as(isize, 1), bad_texture_rc.*);
    bad_texture_bytes.decref(&roc_host);

    const font_bytes = abi.RocListWith(u8, false).fromSlice("not decoded in headless tests", &roc_host);
    font_bytes.incref(1);
    const font_rc = byteListRefcount(font_bytes);
    const font = hostedTextLoadFontBytesRaw(&roc_host, .{ .bytes = font_bytes, .format = 0, .size = 16 });
    try std.testing.expectEqual(RESOURCE_ERR_NONE, font.err);
    try std.testing.expectEqual(@as(isize, 1), font_rc.*);
    releaseResourceBox(&roc_host, font.font);
    font_bytes.decref(&roc_host);

    const bad_font_bytes = abi.RocListWith(u8, false).fromSlice("bad format", &roc_host);
    bad_font_bytes.incref(1);
    const bad_font_rc = byteListRefcount(bad_font_bytes);
    try std.testing.expectEqual(RESOURCE_ERR_FAILED, hostedTextLoadFontBytesRaw(&roc_host, .{ .bytes = bad_font_bytes, .format = 99, .size = 16 }).err);
    try std.testing.expectEqual(@as(isize, 1), bad_font_rc.*);
    bad_font_bytes.decref(&roc_host);
}

/// `Assets.Store.open!`: open a store root and check its manifest.
///
/// Opening a directory and reading a manifest are both filesystem work, so
/// this waits: it parks a task and blocks `init!`. The validation that follows
/// is pure and runs on the frame thread once the read has come back.
fn hostedAssetsOpenStoreRaw(host: *RocHost, args: abi.HostABIAssets_open_storeArgs) callconv(.c) abi.HostABIAssets_open_storeRetRecord {
    enforcePhase("Assets.Store.open!", during_wait);
    const effect = EffectScope.begin("Assets.Store.open!", 0);
    defer effect.end();
    defer args.root.decref(host);
    defer args.asset_set.decref(host);
    defer args.content_hash.decref(host);
    const root_path = args.root.asSlice();
    const allocator = allocatorFromHost(host);
    switch (expectedManifestHash(args)) {
        .invalid => {
            reportStoreOpenFailure(STORE_ERR_INVALID_EXPECTED_CONTENT_HASH, root_path, null);
            return .{ .store = invalidResourceHandle(), .err = STORE_ERR_INVALID_EXPECTED_CONTENT_HASH };
        },
        else => {},
    }
    var root = switch (openStoreDirectoryWaiting(allocator, args.location_kind, root_path)) {
        .failed => |err| {
            const code: u8 = switch (err) {
                error.InvalidRootPath => STORE_ERR_INVALID_ROOT_PATH,
                else => storeOpenError(err),
            };
            reportStoreOpenFailure(code, root_path, null);
            return .{ .store = invalidResourceHandle(), .err = code };
        },
        .dir => |dir| dir,
    };
    var root_transferred = false;
    defer if (!root_transferred) root.close(mainThreadIo());
    const manifest_error = validateStoreManifest(allocator, &root, args);
    if (manifest_error != STORE_ERR_NONE) {
        reportStoreOpenFailure(manifest_error, root_path, &root);
        return .{ .store = invalidResourceHandle(), .err = manifest_error };
    }
    const stored = store_heap.insert(0, .{ .root = root }) orelse {
        reportStoreOpenFailure(STORE_ERR_LIMIT, root_path, &root);
        return .{ .store = invalidResourceHandle(), .err = STORE_ERR_LIMIT };
    };
    root_transferred = true;
    return .{ .store = stored, .err = STORE_ERR_NONE };
}

fn exportedAssetsOpenStoreRaw(args: abi.HostABIAssets_open_storeArgs) callconv(.c) abi.HostABIAssets_open_storeRetRecord {
    return hostedAssetsOpenStoreRaw(activeHost(), args);
}

const StoreRead = union(enum) { bytes: []u8, path_invalid, not_found, failed };

fn readStoreAsset(allocator: std.mem.Allocator, store: *StoreResource, path: []const u8) StoreRead {
    if (!isSafeStoreRelativePath(path)) return .path_invalid;
    return switch (readDirFileWaiting(allocator, store.root, path, MAX_ASSET_FILE_BYTES)) {
        .failed => |err| switch (err) {
            error.FileNotFound => .not_found,
            else => .failed,
        },
        .bytes => |bytes| .{ .bytes = bytes },
    };
}

/// `Assets.load_texture!`: read an image out of a store and upload it.
///
/// The read waits -- it parks a task and blocks `init!` -- and the decode and
/// the GPU upload happen on the frame thread afterwards, with the bytes back
/// in hand.
fn hostedTextureLoadStoreRaw(host: *RocHost, args: abi.HostABITexture_load_storeArgs) callconv(.c) abi.HostABITexture_load_storeRetRecord {
    enforcePhase("Assets.load_texture!", during_wait);
    const effect = EffectScope.begin("Assets.load_texture!", 0);
    defer effect.end();
    defer args.path.decref(host);
    defer releaseResourceBox(host, args.store);
    const store = store_heap.get(args.store.*) orelse return .{ .texture = invalidTexture(), .err = STORE_LOAD_ERR_READ };
    const allocator = allocatorFromHost(host);
    const source = readStoreAsset(allocator, store, args.path.asSlice());
    const bytes = switch (source) {
        .path_invalid => return .{ .texture = invalidTexture(), .err = STORE_LOAD_ERR_PATH },
        .not_found => return .{ .texture = invalidTexture(), .err = STORE_LOAD_ERR_NOT_FOUND },
        .failed => return .{ .texture = invalidTexture(), .err = STORE_LOAD_ERR_READ },
        .bytes => |value| value,
    };
    defer allocator.free(bytes);
    if (headlessMode()) {
        const texture = storeTexture(.{ .headless = .{ .width = @intFromFloat(HEADLESS_RESOURCE_SIZE), .height = @intFromFloat(HEADLESS_RESOURCE_SIZE) } }) orelse
            return .{ .texture = invalidTexture(), .err = STORE_LOAD_ERR_LIMIT };
        return .{ .texture = .{ .handle = texture, .height = HEADLESS_RESOURCE_SIZE, .width = HEADLESS_RESOURCE_SIZE }, .err = STORE_ERR_NONE };
    }
    const file_type = imageFileTypeFromPath(args.path.asSlice()) orelse return .{ .texture = invalidTexture(), .err = STORE_LOAD_ERR_DECODE };
    const texture = raylib.loadTextureFromMemory(file_type, bytes) orelse return .{ .texture = invalidTexture(), .err = STORE_LOAD_ERR_DECODE };
    const stored = storeTexture(.{ .native = texture }) orelse
        return .{ .texture = invalidTexture(), .err = STORE_LOAD_ERR_LIMIT };
    return .{ .texture = .{ .handle = stored, .height = raylib.textureHeight(texture), .width = raylib.textureWidth(texture) }, .err = STORE_ERR_NONE };
}

fn imageFileTypeFromPath(path: []const u8) ?[*:0]const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return imageFileType(0);
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) return imageFileType(1);
    if (std.ascii.eqlIgnoreCase(extension, ".bmp")) return imageFileType(2);
    if (std.ascii.eqlIgnoreCase(extension, ".tga")) return imageFileType(3);
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return imageFileType(4);
    if (std.ascii.eqlIgnoreCase(extension, ".qoi")) return imageFileType(5);
    return null;
}

fn exportedTextureLoadStoreRaw(args: abi.HostABITexture_load_storeArgs) callconv(.c) abi.HostABITexture_load_storeRetRecord {
    return hostedTextureLoadStoreRaw(activeHost(), args);
}

fn hostedTextureLoadBytesRaw(host: *RocHost, args: abi.HostABITexture_load_bytesArgs) callconv(.c) abi.HostABITexture_load_bytesRetRecord {
    enforcePhase("Assets.texture_from_bytes!", during_load);
    const effect = EffectScope.begin("Assets.texture_from_bytes!", args.bytes.items().len);
    defer effect.end();
    defer args.bytes.decref(host);
    const bytes = args.bytes.items();
    if (bytes.len == 0 or imageFileType(args.format) == null) return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_FAILED };
    if (headlessMode()) {
        const texture = storeTexture(.{ .headless = .{ .width = @intFromFloat(HEADLESS_RESOURCE_SIZE), .height = @intFromFloat(HEADLESS_RESOURCE_SIZE) } }) orelse
            return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_LIMIT };
        return .{ .texture = .{ .handle = texture, .height = HEADLESS_RESOURCE_SIZE, .width = HEADLESS_RESOURCE_SIZE }, .err = RESOURCE_ERR_NONE };
    }
    const texture = raylib.loadTextureFromMemory(imageFileType(args.format).?, bytes) orelse return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_FAILED };
    const stored = storeTexture(.{ .native = texture }) orelse
        return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_LIMIT };
    return .{ .texture = .{ .handle = stored, .height = raylib.textureHeight(texture), .width = raylib.textureWidth(texture) }, .err = RESOURCE_ERR_NONE };
}

fn exportedTextureLoadBytesRaw(args: abi.HostABITexture_load_bytesArgs) callconv(.c) abi.HostABITexture_load_bytesRetRecord {
    return hostedTextureLoadBytesRaw(activeHost(), args);
}

fn hostedTextureGenerateColorRaw(args: abi.HostABITexture_generate_colorArgs) callconv(.c) abi.HostABITexture_generate_colorRetRecord {
    enforcePhase("Assets.generate_color_texture!", during_load);
    const effect = EffectScope.begin("Assets.generate_color_texture!", 0);
    defer effect.end();
    if (args.width <= 0 or args.height <= 0) return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_FAILED };
    if (headlessMode()) {
        const texture = storeTexture(.{ .headless = .{ .width = args.width, .height = args.height } }) orelse
            return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_LIMIT };
        return .{ .texture = .{ .handle = texture, .height = @floatFromInt(args.height), .width = @floatFromInt(args.width) }, .err = RESOURCE_ERR_NONE };
    }
    const texture = raylib.generateColorTexture(args.width, args.height, args.color) orelse return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_FAILED };
    const stored = storeTexture(.{ .native = texture }) orelse
        return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_LIMIT };
    return .{ .texture = .{ .handle = stored, .height = raylib.textureHeight(texture), .width = raylib.textureWidth(texture) }, .err = RESOURCE_ERR_NONE };
}

fn hostedTextureGenerateCheckedRaw(args: abi.HostABITexture_generate_checkedArgs) callconv(.c) abi.HostABITexture_generate_checkedRetRecord {
    enforcePhase("Assets.generate_checked_texture!", during_load);
    const effect = EffectScope.begin("Assets.generate_checked_texture!", 0);
    defer effect.end();
    if (args.width <= 0 or args.height <= 0 or args.checks_x <= 0 or args.checks_y <= 0) return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_FAILED };
    if (active_headless) {
        const texture = storeTexture(.{ .headless = .{ .width = args.width, .height = args.height } }) orelse
            return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_LIMIT };
        return .{ .texture = .{ .handle = texture, .height = @floatFromInt(args.height), .width = @floatFromInt(args.width) }, .err = RESOURCE_ERR_NONE };
    }
    const texture = raylib.generateCheckedTexture(args) orelse return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_FAILED };
    const stored = storeTexture(.{ .native = texture }) orelse
        return .{ .texture = invalidTexture(), .err = RESOURCE_ERR_LIMIT };
    return .{ .texture = .{ .handle = stored, .height = raylib.textureHeight(texture), .width = raylib.textureWidth(texture) }, .err = RESOURCE_ERR_NONE };
}

fn hostedTextureUpdateRaw(host: *RocHost, args: abi.HostABITexture_updateArgs) callconv(.c) u8 {
    enforcePhase("Assets.update_texture!", during_update);
    var effect = EffectScope.begin("Assets.update_texture!", drawByteCount(abi.ColorRgba, args.pixels.items().len));
    defer effect.end();
    defer args.pixels.decref(host);
    defer args.texture.decref(host);
    const token = args.texture.handle.*;
    if (render_texture_heap.get(token) != null) return TEXTURE_UPDATE_NOT_MUTABLE;
    const resource = texture_heap.get(token) orelse return TEXTURE_UPDATE_NOT_MUTABLE;
    const expected: usize = switch (resource.*) {
        .headless => |texture| texturePixelCount(texture.width, texture.height) orelse return TEXTURE_UPDATE_PIXEL_COUNT,
        .native => |texture| texturePixelCount(texture.width, texture.height) orelse return TEXTURE_UPDATE_PIXEL_COUNT,
    };
    if (args.pixels.len() != expected) return TEXTURE_UPDATE_PIXEL_COUNT;
    effect.setDrawMetrics(@intCast(args.pixels.len()), drawByteCount(abi.ColorRgba, args.pixels.items().len));
    switch (resource.*) {
        .headless => {},
        .native => |texture| if (!builtin.is_test) raylib.updateTexture(texture, args.pixels.items()),
    }
    return TEXTURE_UPDATE_OK;
}

/// Upload one rectangle of a texture.
///
/// The reason this exists rather than being a convenience: without it, changing
/// one pixel of an atlas means re-uploading the atlas. The call carries its
/// complete payload, so a structurally valid upload is performed rather than
/// silently refused for transient host capacity.
fn hostedTextureUpdateRegionRaw(host: *RocHost, args: abi.HostABITexture_update_regionArgs) callconv(.c) u8 {
    enforcePhase("Assets.update_texture_region!", during_update);
    var effect = EffectScope.begin("Assets.update_texture_region!", drawByteCount(abi.ColorRgba, args.pixels.items().len));
    defer effect.end();
    defer args.pixels.decref(host);
    defer args.texture.decref(host);

    if (args.width <= 0 or args.height <= 0 or args.x < 0 or args.y < 0) return TEXTURE_UPDATE_OUT_OF_BOUNDS;

    const token = args.texture.handle.*;
    if (render_texture_heap.get(token) != null) return TEXTURE_UPDATE_NOT_MUTABLE;
    const resource = texture_heap.get(token) orelse return TEXTURE_UPDATE_NOT_MUTABLE;

    const Size = struct { width: i64, height: i64 };
    const size: Size = switch (resource.*) {
        .headless => |texture| .{ .width = texture.width, .height = texture.height },
        .native => |texture| .{ .width = texture.width, .height = texture.height },
    };
    const right = @as(i64, args.x) + @as(i64, args.width);
    const bottom = @as(i64, args.y) + @as(i64, args.height);
    if (right > size.width or bottom > size.height) return TEXTURE_UPDATE_OUT_OF_BOUNDS;

    const covered = texturePixelCount(args.width, args.height) orelse
        return TEXTURE_UPDATE_PIXEL_COUNT;
    if (args.pixels.len() != covered) return TEXTURE_UPDATE_PIXEL_COUNT;
    effect.setDrawMetrics(@intCast(covered), drawByteCount(abi.ColorRgba, args.pixels.items().len));
    switch (resource.*) {
        .headless => {},
        .native => |texture| if (!builtin.is_test) raylib.updateTextureRegion(
            texture,
            .{ .x = args.x, .y = args.y, .width = args.width, .height = args.height },
            args.pixels.items(),
        ),
    }
    return TEXTURE_UPDATE_OK;
}

fn exportedTextureUpdateRaw(args: abi.HostABITexture_updateArgs) callconv(.c) u8 {
    return hostedTextureUpdateRaw(activeHost(), args);
}

fn exportedTextureUpdateRegionRaw(args: abi.HostABITexture_update_regionArgs) callconv(.c) u8 {
    return hostedTextureUpdateRegionRaw(activeHost(), args);
}

fn hostedTextureSetFilterRaw(texture_owner: abi.Texture, code: u8) callconv(.c) void {
    enforcePhase("Assets.set_texture_filter!", during_update);
    const effect = EffectScope.begin("Assets.set_texture_filter!", 0);
    defer effect.end();
    defer texture_owner.decref(activeHost());
    if (builtin.is_test) return;
    const texture = nativeTextureForToken(texture_owner.handle.*) orelse return;
    raylib.setTextureFilter(texture, code);
}

fn hostedTextureSetWrapRaw(texture_owner: abi.Texture, code: u8) callconv(.c) void {
    enforcePhase("Assets.set_texture_wrap!", during_update);
    const effect = EffectScope.begin("Assets.set_texture_wrap!", 0);
    defer effect.end();
    defer texture_owner.decref(activeHost());
    if (builtin.is_test) return;
    const texture = nativeTextureForToken(texture_owner.handle.*) orelse return;
    raylib.setTextureWrap(texture, code);
}

fn storeRenderTexture(resource: RenderTextureResource) ?*u64 {
    return render_texture_heap.insert(0, resource) orelse {
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

fn hostedTextureLoadRenderTargetRaw(args: abi.HostABITexture_load_render_targetArgs) callconv(.c) abi.HostABITexture_load_render_targetRetRecord {
    enforcePhase("Draw.RenderTexture.load!", during_load);
    const effect = EffectScope.begin("Draw.RenderTexture.load!", 0);
    defer effect.end();
    if (args.width <= 0 or args.height <= 0) return .{ .target = .{ .handle = &invalid_texture_box.payload, .height = 0, .width = 0 }, .err = RESOURCE_ERR_FAILED };
    if (headlessMode()) {
        const target = storeRenderTexture(.headless) orelse
            return .{ .target = .{ .handle = &invalid_texture_box.payload, .height = 0, .width = 0 }, .err = RESOURCE_ERR_LIMIT };
        return .{ .target = .{ .handle = target, .height = @floatFromInt(args.height), .width = @floatFromInt(args.width) }, .err = RESOURCE_ERR_NONE };
    }
    const target = raylib.loadRenderTexture(args.width, args.height) orelse
        return .{ .target = .{ .handle = &invalid_texture_box.payload, .height = 0, .width = 0 }, .err = RESOURCE_ERR_FAILED };
    const stored = storeRenderTexture(.{ .native = target }) orelse
        return .{ .target = .{ .handle = &invalid_texture_box.payload, .height = 0, .width = 0 }, .err = RESOURCE_ERR_LIMIT };
    return .{ .target = .{ .handle = stored, .height = @floatFromInt(args.height), .width = @floatFromInt(args.width) }, .err = RESOURCE_ERR_NONE };
}

fn hostedDrawLoadShaderSourceRaw(host: *RocHost, args: abi.HostABIDraw_load_shader_sourceArgs) callconv(.c) abi.HostABIDraw_load_shader_sourceRetRecord {
    enforcePhase("Draw.Shader.from_source!", during_load);
    const effect = EffectScope.begin("Draw.Shader.from_source!", args.fragment_source.asSlice().len);
    defer effect.end();
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

fn exportedDrawLoadShaderSourceRaw(args: abi.HostABIDraw_load_shader_sourceArgs) callconv(.c) abi.HostABIDraw_load_shader_sourceRetRecord {
    return hostedDrawLoadShaderSourceRaw(activeHost(), args);
}

/// `Draw.Shader.from_store!`: read one or two shader sources and compile them.
///
/// Reading the sources waits -- it parks a task and blocks `init!` -- and the
/// compile runs on the frame thread once both reads have answered.
fn hostedDrawLoadStoreShaderRaw(host: *RocHost, args: abi.HostABIDraw_load_store_shaderArgs) callconv(.c) abi.HostABIDraw_load_store_shaderRetRecord {
    enforcePhase("Draw.Shader.from_store!", during_wait);
    const effect = EffectScope.begin("Draw.Shader.from_store!", 0);
    defer effect.end();
    defer args.vertex_path.decref(host);
    defer args.fragment_path.decref(host);
    defer releaseResourceBox(host, args.store);
    const vertex_path = args.vertex_path.asSlice();
    const fragment_path = args.fragment_path.asSlice();
    if (vertex_path.len == 0 and fragment_path.len == 0) return .{ .shader = invalidResourceHandle(), .err = STORE_LOAD_ERR_PATH };
    const store = store_heap.get(args.store.*) orelse return .{ .shader = invalidResourceHandle(), .err = STORE_LOAD_ERR_READ };
    const allocator = allocatorFromHost(host);

    const vertex_read = if (vertex_path.len == 0) null else readStoreAsset(allocator, store, vertex_path);
    const vertex_bytes = if (vertex_read) |result| switch (result) {
        .path_invalid => return .{ .shader = invalidResourceHandle(), .err = STORE_LOAD_ERR_PATH },
        .not_found => return .{ .shader = invalidResourceHandle(), .err = STORE_LOAD_ERR_NOT_FOUND },
        .failed => return .{ .shader = invalidResourceHandle(), .err = STORE_LOAD_ERR_READ },
        .bytes => |bytes| bytes,
    } else null;
    defer if (vertex_bytes) |bytes| allocator.free(bytes);

    const fragment_read = if (fragment_path.len == 0) null else readStoreAsset(allocator, store, fragment_path);
    const fragment_bytes = if (fragment_read) |result| switch (result) {
        .path_invalid => return .{ .shader = invalidResourceHandle(), .err = STORE_LOAD_ERR_PATH },
        .not_found => return .{ .shader = invalidResourceHandle(), .err = STORE_LOAD_ERR_NOT_FOUND },
        .failed => return .{ .shader = invalidResourceHandle(), .err = STORE_LOAD_ERR_READ },
        .bytes => |bytes| bytes,
    } else null;
    defer if (fragment_bytes) |bytes| allocator.free(bytes);

    if (headlessMode()) {
        const shader = storeShader(.headless) orelse return .{ .shader = invalidResourceHandle(), .err = STORE_LOAD_ERR_LIMIT };
        return .{ .shader = shader, .err = STORE_ERR_NONE };
    }
    var vertex_stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var fragment_stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var vertex = if (vertex_bytes) |bytes| OptionalTempCString.init(allocator, &vertex_stack, bytes) catch return .{ .shader = invalidResourceHandle(), .err = STORE_LOAD_ERR_READ } else OptionalTempCString{ .value = null };
    defer vertex.deinit();
    var fragment = if (fragment_bytes) |bytes| OptionalTempCString.init(allocator, &fragment_stack, bytes) catch return .{ .shader = invalidResourceHandle(), .err = STORE_LOAD_ERR_READ } else OptionalTempCString{ .value = null };
    defer fragment.deinit();
    const shader = raylib.loadShaderFromMemory(vertex.ptr(), fragment.ptr()) orelse return .{ .shader = invalidResourceHandle(), .err = STORE_LOAD_ERR_DECODE };
    const stored = storeShader(.{ .native = shader }) orelse return .{ .shader = invalidResourceHandle(), .err = STORE_LOAD_ERR_LIMIT };
    return .{ .shader = stored, .err = STORE_ERR_NONE };
}

fn exportedDrawLoadStoreShaderRaw(args: abi.HostABIDraw_load_store_shaderArgs) callconv(.c) abi.HostABIDraw_load_store_shaderRetRecord {
    return hostedDrawLoadStoreShaderRaw(activeHost(), args);
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

fn hostedDrawBeginRenderTextureRaw(args: abi.HostABIDraw_begin_render_textureArgs) callconv(.c) u8 {
    enforcePhase("Draw.with_render_texture!", during_render);
    const effect = EffectScope.begin("Draw.with_render_texture!", 0);
    defer effect.end();
    const host = activeHost();
    const owner = args.handle;
    if (render_texture_lease_count == SCOPE_STACK_LIMIT) {
        releaseResourceBox(host, owner);
        return SCOPE_LIMIT;
    }
    const resource = render_texture_heap.get(owner.*) orelse {
        releaseResourceBox(host, owner);
        return SCOPE_UNAVAILABLE;
    };
    switch (resource.*) {
        .headless => headless_render_texture_depth +|= 1,
        .native => |target| if (!builtin.is_test) raylib.beginTextureMode(target),
    }
    render_texture_leases[render_texture_lease_count] = owner;
    render_target_sizes[render_texture_lease_count] = .{ .height = args.height, .width = args.width };
    render_texture_lease_count += 1;
    return SCOPE_OK;
}

fn hostedDrawEndRenderTextureRaw() callconv(.c) void {
    enforcePhase("Draw.with_render_texture!", during_render);
    const effect = EffectScope.begin("Draw.with_render_texture!", 0);
    defer effect.end();
    if (render_texture_lease_count == 0) return;
    if (headlessMode()) headless_render_texture_depth -|= 1 else raylib.endTextureMode();
    render_texture_lease_count -= 1;
    const owner = render_texture_leases[render_texture_lease_count].?;
    render_texture_leases[render_texture_lease_count] = null;
    render_target_sizes[render_texture_lease_count] = .{ .height = 0, .width = 0 };
    if (!headlessMode() and render_texture_lease_count > 0) {
        const outer = render_texture_leases[render_texture_lease_count - 1].?;
        if (render_texture_heap.get(outer.*)) |resource| raylib.beginTextureMode(resource.native);
    }
    releaseResourceBox(activeHost(), owner);
}

/// Report the size of the surface the frame is drawing to right now.
///
/// Inside `Draw.with_render_texture!` that is the innermost open target, so the
/// answer changes on the way in and reverts on the way out; with no target open
/// it is the window's logical drawing size. The window is asked here rather
/// than read off the input, so a `Window.suggest_size` applied during apply
/// phase is visible to the `render!` of the same cycle -- which is what
/// `Window.suggest_size` promises, and what a size carried in the model could not
/// deliver.
fn hostedDrawFrameSizeRaw() callconv(.c) abi.HostABIDraw_frame_size {
    enforcePhase("Draw.Frame.size!", during_render);
    const effect = EffectScope.begin("Draw.Frame.size!", 0);
    defer effect.end();
    if (render_texture_lease_count > 0) return render_target_sizes[render_texture_lease_count - 1];
    const window = windowState();
    return .{ .height = @floatFromInt(window.size.height), .width = @floatFromInt(window.size.width) };
}

fn hostedDrawBeginShaderRaw(args: abi.HostABIDraw_begin_shaderArgs) callconv(.c) u8 {
    enforcePhase("Draw.with_shader!", during_render);
    const effect = EffectScope.begin("Draw.with_shader!", 0);
    defer effect.end();
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
    enforcePhase("Draw.with_shader!", during_render);
    const effect = EffectScope.begin("Draw.with_shader!", 0);
    defer effect.end();
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

fn hostedDrawBeginBlendRaw(args: abi.HostABIDraw_begin_blendArgs) callconv(.c) u8 {
    enforcePhase("Draw.with_blend_mode!", during_render);
    const effect = EffectScope.begin("Draw.with_blend_mode!", 0);
    defer effect.end();
    if (blend_scope_count == SCOPE_STACK_LIMIT) return SCOPE_LIMIT;
    if (args.arg0 > 5) return SCOPE_UNAVAILABLE;
    if (!headlessMode()) raylib.beginBlendMode(args.arg0);
    blend_scopes[blend_scope_count] = args.arg0;
    blend_scope_count += 1;
    return SCOPE_OK;
}

fn hostedDrawEndBlendRaw() callconv(.c) void {
    enforcePhase("Draw.with_blend_mode!", during_render);
    const effect = EffectScope.begin("Draw.with_blend_mode!", 0);
    defer effect.end();
    if (blend_scope_count == 0) return;
    if (!headlessMode()) raylib.endBlendMode();
    blend_scope_count -= 1;
    if (!headlessMode() and blend_scope_count > 0) raylib.beginBlendMode(blend_scopes[blend_scope_count - 1]);
}

fn hostedDrawShaderLocationRaw(host: *RocHost, args: abi.HostABIDraw_shader_locationArgs) callconv(.c) i32 {
    enforcePhase("Draw.Shader.uniform_*!", during_load);
    const effect = EffectScope.begin("Draw.Shader.uniform_*!", args.name.asSlice().len);
    defer effect.end();
    defer args.name.decref(host);
    defer releaseResourceBox(host, args.shader);
    const resource = shader_heap.get(args.shader.*) orelse return -1;
    const name_slice = args.name.asSlice();
    if (name_slice.len == 0) return -1;
    switch (resource.*) {
        .headless => return 0,
        .native => |shader| {
            if (builtin.is_test) return 0;
            var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
            var name = makeTempCString(allocatorFromHost(host), &stack, name_slice) catch return -1;
            defer name.deinit();
            return raylib.shaderLocation(shader, name.ptr);
        },
    }
}

fn exportedDrawShaderLocationRaw(args: abi.HostABIDraw_shader_locationArgs) callconv(.c) i32 {
    return hostedDrawShaderLocationRaw(activeHost(), args);
}

fn hostedDrawSetShaderFloatRaw(args: abi.HostABIDraw_set_shader_floatArgs) callconv(.c) void {
    enforcePhase("Draw.F32Uniform.set!", during_render);
    var effect = EffectScope.begin("Draw.F32Uniform.set!", 0);
    defer effect.end();
    effect.setDrawMetrics(1, @sizeOf(f32));
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderFloat(resource.native, args.uniform.location, args.value);
}

fn hostedDrawSetShaderIntRaw(args: abi.HostABIDraw_set_shader_intArgs) callconv(.c) void {
    enforcePhase("Draw.I32Uniform.set!", during_render);
    var effect = EffectScope.begin("Draw.I32Uniform.set!", 0);
    defer effect.end();
    effect.setDrawMetrics(1, @sizeOf(i32));
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderInt(resource.native, args.uniform.location, args.value);
}

fn hostedDrawSetShaderVec2Raw(args: abi.HostABIDraw_set_shader_vec2Args) callconv(.c) void {
    enforcePhase("Draw.Vec2Uniform.set!", during_render);
    var effect = EffectScope.begin("Draw.Vec2Uniform.set!", 0);
    defer effect.end();
    effect.setDrawMetrics(1, 2 * @sizeOf(f32));
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderVec2(resource.native, args.uniform.location, .{ args.value.x, args.value.y });
}

fn hostedDrawSetShaderVec3Raw(args: abi.HostABIDraw_set_shader_vec3Args) callconv(.c) void {
    enforcePhase("Draw.Vec3Uniform.set!", during_render);
    var effect = EffectScope.begin("Draw.Vec3Uniform.set!", 0);
    defer effect.end();
    effect.setDrawMetrics(1, 3 * @sizeOf(f32));
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderVec3(resource.native, args.uniform.location, .{ args.value.x, args.value.y, args.value.z });
}

fn hostedDrawSetShaderVec4Raw(args: abi.HostABIDraw_set_shader_vec4Args) callconv(.c) void {
    enforcePhase("Draw.Vec4Uniform.set!", during_render);
    var effect = EffectScope.begin("Draw.Vec4Uniform.set!", 0);
    defer effect.end();
    effect.setDrawMetrics(1, 4 * @sizeOf(f32));
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderVec4(resource.native, args.uniform.location, .{ args.value.x, args.value.y, args.value.z, args.value.w });
}

fn hostedDrawSetShaderTextureRaw(args: abi.HostABIDraw_set_shader_textureArgs) callconv(.c) void {
    enforcePhase("Draw.TextureUniform.set!", during_render);
    const effect = EffectScope.begin("Draw.TextureUniform.set!", 0);
    defer effect.end();
    defer args.uniform.decref(activeHost());
    defer args.texture.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    const texture = nativeTextureForToken(args.texture.handle.*) orelse return;
    raylib.setShaderTexture(resource.native, args.uniform.location, texture);
}

/// Forward Roc scissor bounds to the raylib backend.
fn hostedDrawBeginScissorRaw(args: abi.HostABIDraw_begin_scissorArgs) callconv(.c) u8 {
    enforcePhase("Draw.with_scissor!", during_render);
    const effect = EffectScope.begin("Draw.with_scissor!", 0);
    defer effect.end();
    if (scissor_scope_count == SCOPE_STACK_LIMIT) return SCOPE_LIMIT;
    if (!headlessMode()) raylib.beginScissor(args.x, args.y, args.width, args.height);
    scissor_scopes[scissor_scope_count] = args;
    scissor_scope_count += 1;
    return SCOPE_OK;
}

/// End the scissor region opened by the Roc renderer.
fn hostedDrawEndScissorRaw() callconv(.c) void {
    enforcePhase("Draw.with_scissor!", during_render);
    const effect = EffectScope.begin("Draw.with_scissor!", 0);
    defer effect.end();
    if (scissor_scope_count == 0) return;
    if (!headlessMode()) raylib.endScissor();
    scissor_scope_count -= 1;
    if (!headlessMode() and scissor_scope_count > 0) {
        const outer = scissor_scopes[scissor_scope_count - 1];
        raylib.beginScissor(outer.x, outer.y, outer.width, outer.height);
    }
}

fn hostedDrawBeginCamera(args: abi.HostABIDraw_begin_cameraArgs) callconv(.c) u8 {
    enforcePhase("Draw.with_camera!", during_render);
    const effect = EffectScope.begin("Draw.with_camera!", 0);
    defer effect.end();
    if (camera_scope_count == SCOPE_STACK_LIMIT) return SCOPE_LIMIT;
    if (!headlessMode()) raylib.beginMode2D(args);
    camera_scopes[camera_scope_count] = args;
    camera_scope_count += 1;
    return SCOPE_OK;
}

fn hostedDrawCircleRaw(args: abi.HostABIDraw_circleArgs) callconv(.c) void {
    enforcePhase("Draw.circle!", during_render);
    const effect = EffectScope.begin("Draw.circle!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.drawCircle(args);
}

fn hostedDrawCircleGradient(args: abi.HostABIDraw_circle_gradientArgs) callconv(.c) void {
    enforcePhase("Draw.circle_gradient!", during_render);
    const effect = EffectScope.begin("Draw.circle_gradient!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.drawCircleGradient(args);
}

fn hostedDrawCircleLinesRaw(args: abi.HostABIDraw_circle_linesArgs) callconv(.c) void {
    enforcePhase("Draw.circle_lines!", during_render);
    const effect = EffectScope.begin("Draw.circle_lines!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.drawCircleLines(args);
}

fn hostedDrawClear(color: Color) callconv(.c) void {
    enforcePhase("Draw.clear!", during_render);
    const effect = EffectScope.begin("Draw.clear!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.clearBackground(color);
}

fn hostedDrawEndCamera() callconv(.c) void {
    enforcePhase("Draw.with_camera!", during_render);
    const effect = EffectScope.begin("Draw.with_camera!", 0);
    defer effect.end();
    if (camera_scope_count == 0) return;
    if (!headlessMode()) raylib.endMode2D();
    camera_scope_count -= 1;
    if (!headlessMode() and camera_scope_count > 0) raylib.beginMode2D(camera_scopes[camera_scope_count - 1]);
}

fn hostedDrawFps(args: abi.HostABIDraw_fpsArgs) callconv(.c) void {
    enforcePhase("Draw.fps!", during_render);
    const effect = EffectScope.begin("Draw.fps!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.drawFps(args);
}

fn hostedDrawLineRaw(args: abi.HostABIDraw_lineArgs) callconv(.c) void {
    enforcePhase("Draw.line!", during_render);
    const effect = EffectScope.begin("Draw.line!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.drawLine(args);
}

fn hostedDrawPolygonRaw(host: *RocHost, args: abi.HostABIDraw_polygonArgs) callconv(.c) void {
    enforcePhase("Draw.polygon!", during_render);
    const effect = EffectScope.begin("Draw.polygon!", 0);
    defer effect.end();
    defer args.points.decref(host);
    if (active_headless) return;
    raylib.drawPolygon(args.points.items(), args.color);
}

fn exportedDrawPolygonRaw(args: abi.HostABIDraw_polygonArgs) callconv(.c) void {
    hostedDrawPolygonRaw(activeHost(), args);
}

fn hostedDrawPolygonLinesRaw(host: *RocHost, args: abi.HostABIDraw_polygon_linesArgs) callconv(.c) void {
    enforcePhase("Draw.polygon_lines!", during_render);
    const effect = EffectScope.begin("Draw.polygon_lines!", 0);
    defer effect.end();
    defer args.points.decref(host);
    if (active_headless) return;
    raylib.drawPolygonLines(args.points.items(), args.thickness, args.color);
}

fn exportedDrawPolygonLinesRaw(args: abi.HostABIDraw_polygon_linesArgs) callconv(.c) void {
    hostedDrawPolygonLinesRaw(activeHost(), args);
}

fn hostedDrawRectangleRaw(args: abi.HostABIDraw_rectangleArgs) callconv(.c) void {
    enforcePhase("Draw.rectangle!", during_render);
    const effect = EffectScope.begin("Draw.rectangle!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.drawRectangle(args);
}

fn hostedDrawRectangleLinesRaw(args: abi.HostABIDraw_rectangle_linesArgs) callconv(.c) void {
    enforcePhase("Draw.rectangle_lines!", during_render);
    const effect = EffectScope.begin("Draw.rectangle_lines!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.drawRectangleLines(args);
}

fn hostedDrawRectangleGradientH(args: abi.HostABIDraw_rectangle_gradient_hArgs) callconv(.c) void {
    enforcePhase("Draw.rectangle_gradient_h!", during_render);
    const effect = EffectScope.begin("Draw.rectangle_gradient_h!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.drawRectangleGradientH(args);
}

fn hostedDrawRectangleGradientV(args: abi.HostABIDraw_rectangle_gradient_vArgs) callconv(.c) void {
    enforcePhase("Draw.rectangle_gradient_v!", during_render);
    const effect = EffectScope.begin("Draw.rectangle_gradient_v!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.drawRectangleGradientV(args);
}

fn hostedDrawRoundedRectangleRaw(args: abi.HostABIDraw_rounded_rectangleArgs) callconv(.c) void {
    enforcePhase("Draw.rounded_rectangle!", during_render);
    const effect = EffectScope.begin("Draw.rounded_rectangle!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.drawRoundedRectangle(args);
}

fn hostedDrawRoundedRectangleLinesRaw(args: abi.HostABIDraw_rounded_rectangle_linesArgs) callconv(.c) void {
    enforcePhase("Draw.rounded_rectangle_lines!", during_render);
    const effect = EffectScope.begin("Draw.rounded_rectangle_lines!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.drawRoundedRectangleLines(args);
}

fn hostedDrawTriangleRaw(args: abi.HostABIDraw_triangleArgs) callconv(.c) void {
    enforcePhase("Draw.triangle!", during_render);
    const effect = EffectScope.begin("Draw.triangle!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.drawTriangle(args);
}

fn hostedDrawTriangleLinesRaw(args: abi.HostABIDraw_triangle_linesArgs) callconv(.c) void {
    enforcePhase("Draw.triangle_lines!", during_render);
    const effect = EffectScope.begin("Draw.triangle_lines!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.drawTriangleLines(args);
}

fn hostedTextLoadFontBytesRaw(host: *RocHost, args: abi.HostABIText_load_font_bytesArgs) callconv(.c) abi.HostABIText_load_font_bytesRetRecord {
    enforcePhase("Draw.font_from_bytes!", during_load);
    const effect = EffectScope.begin("Draw.font_from_bytes!", args.bytes.items().len);
    defer effect.end();
    defer args.bytes.decref(host);
    const bytes = args.bytes.items();
    const file_type = fontFileType(args.format) orelse return .{ .font = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    if (bytes.len == 0 or args.size <= 0) return .{ .font = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    if (headlessMode()) {
        const font = storeFont(.headless) orelse return .{ .font = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .font = font, .err = RESOURCE_ERR_NONE };
    }
    const font = raylib.loadFontFromMemory(file_type, bytes, args.size) orelse return .{ .font = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeFont(.{ .native = font }) orelse return .{ .font = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .font = stored, .err = RESOURCE_ERR_NONE };
}

fn exportedTextLoadFontBytesRaw(args: abi.HostABIText_load_font_bytesArgs) callconv(.c) abi.HostABIText_load_font_bytesRetRecord {
    return hostedTextLoadFontBytesRaw(activeHost(), args);
}

/// `Draw.load_store_font!`: read a font file out of a store and rasterize it.
///
/// The read waits -- it parks a task and blocks `init!` -- and the rasterizing
/// happens on the frame thread with the bytes back in hand.
fn hostedTextLoadStoreFontRaw(host: *RocHost, args: abi.HostABIText_load_store_fontArgs) callconv(.c) abi.HostABIText_load_store_fontRetRecord {
    enforcePhase("Draw.load_store_font!", during_wait);
    const effect = EffectScope.begin("Draw.load_store_font!", args.path.asSlice().len);
    defer effect.end();
    defer args.path.decref(host);
    defer releaseResourceBox(host, args.store);
    if (args.size <= 0) return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_DECODE };
    const store = store_heap.get(args.store.*) orelse return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_READ };
    const allocator = allocatorFromHost(host);
    const source = readStoreAsset(allocator, store, args.path.asSlice());
    const bytes = switch (source) {
        .path_invalid => return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_PATH },
        .not_found => return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_NOT_FOUND },
        .failed => return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_READ },
        .bytes => |value| value,
    };
    defer allocator.free(bytes);
    if (headlessMode()) {
        const font = storeFont(.headless) orelse return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_LIMIT };
        return .{ .font = font, .err = STORE_ERR_NONE };
    }
    const file_type = fontFileTypeFromPath(args.path.asSlice()) orelse return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_DECODE };
    const font = raylib.loadFontFromMemory(file_type, bytes, args.size) orelse return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_DECODE };
    const stored = storeFont(.{ .native = font }) orelse return .{ .font = invalidResourceHandle(), .err = STORE_LOAD_ERR_LIMIT };
    return .{ .font = stored, .err = STORE_ERR_NONE };
}

fn fontFileTypeFromPath(path: []const u8) ?[*:0]const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".ttf")) return fontFileType(0);
    if (std.ascii.eqlIgnoreCase(extension, ".otf")) return fontFileType(1);
    return null;
}

fn exportedTextLoadStoreFontRaw(args: abi.HostABIText_load_store_fontArgs) callconv(.c) abi.HostABIText_load_store_fontRetRecord {
    return hostedTextLoadStoreFontRaw(activeHost(), args);
}

test "the store-backed font and shader loaders wait rather than load" {
    // Both read files out of a store, so both belong where waiting is defined.
    // The rasterizing and the shader compile that follow are frame-thread work
    // on bytes already in hand, which is why only the read moved.
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        last_phase_violation = null;
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        store_heap.deinitAll();
        font_heap.deinitAll();
        shader_heap.deinitAll();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "body.ttf", .data = "not rasterized in headless tests" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blur.fs", .data = "not compiled in headless tests" });
    var root_path: [256]u8 = undefined;
    const relative_root = try std.fmt.bufPrint(&root_path, testing_tmp_prefix ++ "{s}", .{tmp.sub_path});

    const startup = PhaseScope.enter(.startup);
    last_phase_violation = null;
    const opened = hostedAssetsOpenStoreRaw(&roc_host, testStoreOpenArgs(&roc_host, relative_root, false, 0, ""));
    try std.testing.expectEqual(STORE_ERR_NONE, opened.err);
    startup.leave();

    {
        const update = PhaseScope.enter(.update);
        defer update.leave();
        last_phase_violation = null;
        _ = hostedTextLoadStoreFontRaw(&roc_host, .{
            .store = allocateTestResourceStub(&roc_host),
            .path = abi.RocStr.fromSlice("body.ttf", &roc_host),
            .size = 16,
        });
        const font_violation = last_phase_violation orelse return error.OperationWasNotRejected;
        try std.testing.expectEqualStrings("Draw.load_store_font!", font_violation.operation);
        try std.testing.expect(font_violation.allowed.eql(during_wait));
        try std.testing.expectEqual(Phase.update, font_violation.actual);

        last_phase_violation = null;
        _ = hostedDrawLoadStoreShaderRaw(&roc_host, .{
            .store = allocateTestResourceStub(&roc_host),
            .vertex_path = abi.RocStr.empty(),
            .fragment_path = abi.RocStr.fromSlice("blur.fs", &roc_host),
        });
        const shader_violation = last_phase_violation orelse return error.OperationWasNotRejected;
        try std.testing.expectEqualStrings("Draw.Shader.from_store!", shader_violation.operation);
        try std.testing.expect(shader_violation.allowed.eql(during_wait));
        try std.testing.expectEqual(Phase.update, shader_violation.actual);
    }

    // On a task, where the read parks rather than holding the frame, the same
    // two calls answer with resources.
    const task = PhaseScope.enter(.task);
    defer task.leave();
    last_phase_violation = null;
    const font = hostedTextLoadStoreFontRaw(&roc_host, .{
        .store = retainTestResourceBox(opened.store),
        .path = abi.RocStr.fromSlice("body.ttf", &roc_host),
        .size = 16,
    });
    try std.testing.expectEqual(STORE_ERR_NONE, font.err);
    releaseResourceBox(&roc_host, font.font);

    const shader = hostedDrawLoadStoreShaderRaw(&roc_host, .{
        .store = opened.store,
        .vertex_path = abi.RocStr.empty(),
        .fragment_path = abi.RocStr.fromSlice("blur.fs", &roc_host),
    });
    try std.testing.expectEqual(STORE_ERR_NONE, shader.err);
    releaseResourceBox(&roc_host, shader.shader);
    try std.testing.expect(last_phase_violation == null);
}

fn fontForHandle(handle: *u64) raylib.Font {
    if (builtin.is_test) return undefined;
    if (handle.* == 0) return raylib.defaultFont();
    const resource = font_heap.get(handle.*) orelse return raylib.defaultFont();
    return switch (resource.*) {
        .headless => raylib.defaultFont(),
        .native => |font| font,
    };
}

fn hostedTextDefaultFontRaw() callconv(.c) *u64 {
    enforcePhase("Draw.default_font!", during_load);
    const effect = EffectScope.begin("Draw.default_font!", 0);
    defer effect.end();
    return defaultFontHandle();
}

fn headlessFontMetrics(host: *RocHost) abi.HostABIText_font_metricsRetRecord {
    return .{
        .glyphs = abi.RocListWith(FontMetric, false).fromSlice(&HEADLESS_GLYPHS, host),
        .base_size = HEADLESS_FONT_BASE_SIZE,
        .fallback_index = 0,
        .line_spacing = RAYLIB_DEFAULT_TEXT_LINE_SPACING,
    };
}

fn glyphMetricLessThan(_: void, left: FontMetric, right: FontMetric) bool {
    return left.codepoint < right.codepoint;
}

/// Copy the scalar portion of a raylib font into ordinary Roc memory.
///
/// The source font remains entirely owned by FontHeap. The returned list has
/// primitive elements, so ordinary Roc ARC alone owns and drops this snapshot.
fn snapshotRaylibFontMetrics(host: *RocHost, font: raylib.Font) abi.HostABIText_font_metricsRetRecord {
    const count = raylib.fontGlyphCount(font);
    if (count == 0) return headlessFontMetrics(host);

    const glyphs = abi.RocListWith(FontMetric, false).allocate(count, host);
    const elements = glyphs.elements_ptr.?[0..count];
    var fallback_codepoint: u32 = 0;
    for (elements, 0..) |*element, index| {
        const metric = raylib.fontGlyphMetric(font, index);
        element.* = .{
            .advance_x = metric.advance_x,
            .codepoint = metric.codepoint,
            .height = metric.height,
            .offset_x = metric.offset_x,
            .offset_y = metric.offset_y,
            .width = metric.width,
        };
        if (index == 0 or metric.codepoint == '?') fallback_codepoint = metric.codepoint;
    }
    std.sort.pdq(FontMetric, elements, {}, glyphMetricLessThan);
    var fallback_index: u64 = 0;
    for (elements, 0..) |metric, index| {
        if (metric.codepoint == fallback_codepoint) {
            fallback_index = @intCast(index);
            break;
        }
    }
    return .{
        .glyphs = glyphs,
        .base_size = raylib.fontBaseSize(font),
        .fallback_index = fallback_index,
        .line_spacing = RAYLIB_DEFAULT_TEXT_LINE_SPACING,
    };
}

fn hostedTextFontMetricsRaw(host: *RocHost, font: *u64) callconv(.c) abi.HostABIText_font_metricsRetRecord {
    enforcePhase("Draw font metric snapshot", during_load);
    const effect = EffectScope.begin("Draw font metric snapshot", 0);
    defer effect.end();
    defer releaseResourceBox(host, font);
    if (headlessMode()) return headlessFontMetrics(host);
    return snapshotRaylibFontMetrics(host, fontForHandle(font));
}

fn exportedTextFontMetricsRaw(font: *u64) callconv(.c) abi.HostABIText_font_metricsRetRecord {
    return hostedTextFontMetricsRaw(activeHost(), font);
}

test "font metric snapshots release the source Font and retain only scalar Roc data" {
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());

    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    active_headless = true;
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_roc_host = null;
    }

    const source = storeFont(.headless).?;
    const snapshot = hostedTextFontMetricsRaw(&roc_host, source);
    defer snapshot.glyphs.decref(&roc_host);

    try std.testing.expectEqual(@as(f32, 2), snapshot.base_size);
    try std.testing.expectEqual(RAYLIB_DEFAULT_TEXT_LINE_SPACING, snapshot.line_spacing);
    try std.testing.expectEqual(@as(u64, 0), snapshot.fallback_index);
    try std.testing.expectEqual(@as(usize, HEADLESS_GLYPHS.len), snapshot.glyphs.len());
    try std.testing.expect(snapshot.glyphs.hasOneRef());

    // The host call consumed the only loaded-font reference. The snapshot list
    // itself is independent ordinary Roc ARC data.
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());
    try std.testing.expectEqualSlices(FontMetric, &HEADLESS_GLYPHS, snapshot.glyphs.items());
}

fn hostedTextPrepareRaw(host: *RocHost, args: abi.HostABIText_prepareArgs) callconv(.c) abi.HostABIText_prepareRetRecord {
    enforcePhase("Text.prepare!", during_load);
    const effect = EffectScope.begin("Text.prepare!", args.text.asSlice().len);
    defer effect.end();
    defer args.text.decref(host);
    prepared_text_prepare_calls += 1;

    const font: ?raylib.Font = if (args.font.* == 0)
        if (builtin.is_test) null else raylib.defaultFont()
    else if (font_heap.get(args.font.*)) |font_resource|
        switch (font_resource.*) {
            .headless => null,
            .native => |loaded| loaded,
        }
    else {
        releaseResourceBox(host, args.font);
        return .{ .prepared = invalidResourceHandle(), .height = 0, .width = 0, .err = RESOURCE_ERR_FAILED };
    };

    const text_slice = args.text.asSlice();
    const text_len = std.mem.indexOfScalar(u8, text_slice, 0) orelse text_slice.len;
    const allocator = allocatorFromHost(host);
    const allocation = allocator.alloc(u8, text_len + 1) catch {
        releaseResourceBox(host, args.font);
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
        break :blk TextMeasurement{ .height = size.y, .width = size.x };
    };

    const prepared = storePreparedText(.{
        .allocator = allocator,
        .text = text,
        .font = font,
        .font_owner = args.font,
        .size = args.size,
        .spacing = args.spacing,
    }) orelse return .{ .prepared = invalidResourceHandle(), .height = 0, .width = 0, .err = RESOURCE_ERR_LIMIT };

    return .{ .prepared = prepared, .height = measured.height, .width = measured.width, .err = RESOURCE_ERR_NONE };
}

fn exportedTextPrepareRaw(args: abi.HostABIText_prepareArgs) callconv(.c) abi.HostABIText_prepareRetRecord {
    return hostedTextPrepareRaw(activeHost(), args);
}

fn hostedDrawPreparedTextRaw(host: *RocHost, args: abi.HostABIDraw_draw_prepared_textArgs) callconv(.c) void {
    enforcePhase("Text.Prepared.draw!", during_render);
    const effect = EffectScope.begin("Text.Prepared.draw!", 0);
    defer effect.end();
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

fn exportedDrawPreparedTextRaw(args: abi.HostABIDraw_draw_prepared_textArgs) callconv(.c) void {
    hostedDrawPreparedTextRaw(activeHost(), args);
}

fn hostedDrawTextRaw(host: *RocHost, args: abi.HostABIDraw_textArgs) callconv(.c) void {
    enforcePhase("Draw.text!", during_render);
    const effect = EffectScope.begin("Draw.text!", 0);
    defer effect.end();
    defer args.text.decref(host);
    defer releaseResourceBox(host, args.font);
    if (headlessMode()) return;

    const text_slice = args.text.asSlice();
    var stack: [CSTRING_STACK_CAPACITY:0]u8 = undefined;
    var text = makeTempCString(allocatorFromHost(host), &stack, text_slice) catch return;
    defer text.deinit();

    raylib.drawTextZ(
        text.ptr,
        fontForHandle(args.font),
        .{ .x = args.pos.x, .y = args.pos.y },
        args.size,
        args.spacing,
        args.color,
    );
}

fn exportedDrawTextRaw(args: abi.HostABIDraw_textArgs) callconv(.c) void {
    hostedDrawTextRaw(activeHost(), args);
}

fn hostedDrawTextureRaw(args: abi.HostABIDraw_draw_textureArgs) callconv(.c) void {
    enforcePhase("Draw.texture!", during_render);
    const effect = EffectScope.begin("Draw.texture!", 0);
    defer effect.end();
    defer args.texture.decref(activeHost());
    if (headlessMode()) return;
    const texture = nativeTextureForToken(args.texture.handle.*) orelse return;
    raylib.drawTexture(texture, args);
}

/// Draw a whole instance batch for one texture from a single hosted call.
///
/// Invalid or released handles behave exactly as `hostedDrawTextureRaw` does:
/// the batch is dropped silently after its references are released. An empty
/// list never reaches here, because Roc returns before crossing.
fn hostedDrawTextureInstancesRaw(host: *RocHost, args: abi.HostABIDraw_draw_texture_instancesArgs) callconv(.c) void {
    enforcePhase("Draw.texture_instances!", during_render);
    var effect = EffectScope.begin("Draw.texture_instances!", 0);
    effect.setDrawMetrics(
        @intCast(args.instances.len()),
        drawByteCount(abi.HostABIDraw_draw_texture_instancesArg0Instances, args.instances.items().len),
    );
    defer effect.end();
    defer args.decref(host);
    if (headlessMode()) {
        // Headless still resolves the handle so a released texture is rejected
        // the same way it would be with a live GL context.
        if (texture_heap.get(args.texture.handle.*) != null or
            render_texture_heap.get(args.texture.handle.*) != null)
        {
            headless_texture_instance_batches += 1;
            headless_texture_instances += args.instances.len();
        }
        return;
    }
    const texture = nativeTextureForToken(args.texture.handle.*) orelse return;
    raylib.drawTextureInstances(texture, args.instances.items());
}

fn exportedDrawTextureInstancesRaw(args: abi.HostABIDraw_draw_texture_instancesArgs) callconv(.c) void {
    hostedDrawTextureInstancesRaw(activeHost(), args);
}

fn hostedDrawTextureQuadRaw(args: abi.HostABIDraw_draw_texture_quadArgs) callconv(.c) void {
    enforcePhase("Draw.projective_texture!", during_render);
    const effect = EffectScope.begin("Draw.projective_texture!", 0);
    defer effect.end();
    defer args.texture.decref(activeHost());
    if (headlessMode()) return;
    const texture = nativeTextureForToken(args.texture.handle.*) orelse return;
    raylib.drawTextureQuad(texture, args);
}

/// Global flag for deferred exit request (exit after current frame completes)
var exit_requested: ?i64 = null;

/// Complete argv as seen by the Roc application. `platform_main` owns the
/// backing allocation and installs it before the configuration callback runs.
/// Host switches have already been removed, but argv[0] is deliberately kept.
var active_app_args: []const [*:0]u8 = &.{};

fn hostedArgs(roc_host: *RocHost) callconv(.c) abi.RocList(abi.RocStr) {
    enforcePhase("App.Startup.args!", during_load);
    const effect = EffectScope.begin("App.Startup.args!", 0);
    defer effect.end();

    const result = abi.RocList(abi.RocStr).allocate(active_app_args.len, roc_host);
    if (result.elements_ptr) |items| {
        for (active_app_args, 0..) |arg, index| {
            const bytes = std.mem.span(arg);
            // Roc `Str` values must be UTF-8. Native argv is not guaranteed to
            // be, so preserve valid input and represent an invalid argument by
            // the standard replacement character rather than constructing an
            // invalid Roc string.
            items[index] = abi.RocStr.fromSlice(
                if (std.unicode.utf8ValidateSlice(bytes)) bytes else "\xEF\xBF\xBD",
                roc_host,
            );
        }
    }
    return result;
}

fn exportedArgs() callconv(.c) abi.RocList(abi.RocStr) {
    return hostedArgs(activeHost());
}

fn hostedAppReadEnvWindows(roc_host: *RocHost, key_arg: abi.RocStr) callconv(.c) AppReadEnvResult {
    enforcePhase("App.Startup.read_env!", during_startup);
    const effect = EffectScope.begin("App.Startup.read_env!", key_arg.asSlice().len);
    defer effect.end();
    // Windows doesn't link libc, so env var reading is not yet supported
    var result: AppReadEnvResult = undefined;
    result.tag = .Err;

    key_arg.decref(roc_host);
    return result;
}

fn exportedAppReadEnvWindows(key_arg: abi.RocStr) callconv(.c) AppReadEnvResult {
    return hostedAppReadEnvWindows(activeHost(), key_arg);
}

fn hostedAppReadEnvPosix(roc_host: *RocHost, key_arg: abi.RocStr) callconv(.c) AppReadEnvResult {
    enforcePhase("App.Startup.read_env!", during_startup);
    const effect = EffectScope.begin("App.Startup.read_env!", key_arg.asSlice().len);
    defer effect.end();
    var result: AppReadEnvResult = undefined;
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

fn exportedAppReadEnvPosix(key_arg: abi.RocStr) callconv(.c) AppReadEnvResult {
    return hostedAppReadEnvPosix(activeHost(), key_arg);
}

fn hostedAppReadFile(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) AppReadFileResult {
    enforcePhase("App.Startup.read_file!", during_startup);
    const effect = EffectScope.begin("App.Startup.read_file!", path_arg.asSlice().len);
    defer effect.end();
    defer path_arg.decref(roc_host);

    const allocator = allocatorFromHost(roc_host);
    const path = path_arg.asSlice();
    const bytes = std.Io.Dir.cwd().readFileAlloc(mainThreadIo(), path, allocator, .limited(MAX_FILE_READ_BYTES)) catch |err| {
        var result = emptyAppReadFileResult();
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

fn exportedAppReadFile(path_arg: abi.RocStr) callconv(.c) AppReadFileResult {
    return hostedAppReadFile(activeHost(), path_arg);
}

/// Read one TMX or TSX file on the waiting path.
///
/// The loader calls this once for the map and once more for every external
/// tileset the map references, so a map spread across several files parks the
/// task once per file and parses in between, on the frame thread, with each
/// file's bytes in hand.
fn readTilemapFileWaiting(_: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) tmx_loader.LoadError![]u8 {
    var err: u8 = READ_ERR_FAILED;
    const bytes = readFileWaiting(allocator, path, tmx_loader.max_file_bytes, &err) orelse
        return if (err == READ_ERR_NOT_FOUND) error.NotFound else error.ReadFailed;
    return bytes;
}

/// `Tilemap.load_tmx!`: read a Tiled map and parse it into flat records.
///
/// Every read waits -- parking a task, blocking `init!` -- and the XML parse
/// and the conversion into Roc values run on the frame thread between them.
fn hostedTilemapLoadTmxRaw(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) TilemapLoadTmxRawResult {
    enforcePhase("Tilemap.load_tmx!", during_wait);
    const effect = EffectScope.begin("Tilemap.load_tmx!", path_arg.asSlice().len);
    defer effect.end();
    defer path_arg.decref(roc_host);

    const path = path_arg.asSlice();
    const reader = tmx_loader.FileReader{ .read = readTilemapFileWaiting };
    var map = tmx_loader.load(allocatorFromHost(roc_host), reader, path) catch |err| {
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

fn releaseTilemapDrawArgs(host: *RocHost, args: abi.HostABITilemap_drawArgs) void {
    args.gids.decref(host);
    args.layers.decref(host);
    if (args.tilesets.hasOneRef()) {
        for (args.tilesets.allocationItems()) |tileset| tileset.decref(host);
    }
    args.tilesets.decref(host);
}

fn tilemapTextureToken(tileset: abi.HostABITilemap_drawArg0Tilesets) u64 {
    return tileset.texture.handle.*;
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

fn hostedTilemapDrawRaw(host: *RocHost, args: abi.HostABITilemap_drawArgs) callconv(.c) void {
    enforcePhase("Tilemap.draw_layers!", during_render);
    const effect = EffectScope.begin("Tilemap.draw_layers!", 0);
    defer effect.end();
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

fn exportedTilemapDrawRaw(args: abi.HostABITilemap_drawArgs) callconv(.c) void {
    hostedTilemapDrawRaw(activeHost(), args);
}

fn hostedExit(code: i32) callconv(.c) void {
    enforcePhase("App.Startup.exit!", during_update);
    const effect = EffectScope.begin("App.Startup.exit!", 0);
    defer effect.end();
    exit_requested = @as(i64, code);
}

/// Suggest a new logical window size.
///
/// Native window managers may adjust or ignore the hint. A later input's
/// window snapshot, and the active frame size during presentation, report the
/// geometry the backend actually established. The headless semantic backend
/// honors the hint deterministically.
fn hostedSuggestWindowSize(args: abi.HostABIWindow_suggest_sizeArgs) callconv(.c) u8 {
    enforcePhase("Window.suggest_size!", during_update);
    const effect = EffectScope.begin("Window.suggest_size!", 0);
    defer effect.end();
    // `headlessMode()` rather than `active_headless`: it folds to true at
    // comptime under `zig test`, which keeps the raylib call out of the test
    // binary's link so the phase guard here is testable at all.
    if (headlessMode()) {
        headless_screen_width = positiveI32(args.width, headless_screen_width);
        headless_screen_height = positiveI32(args.height, headless_screen_height);
    } else {
        raylib.suggestWindowSize(args.width, args.height);
    }
    return TRY_TAG_OK;
}

fn hostedSetTargetFps(fps: i32) callconv(.c) void {
    enforcePhase("Window.set_target_fps!", during_update);
    const effect = EffectScope.begin("Window.set_target_fps!", 0);
    defer effect.end();
    if (headlessMode()) return;
    raylib.setTargetFps(fps);
}

fn hostedSuggestWindowMinSize(args: abi.HostABIWindow_suggest_min_sizeArgs) callconv(.c) void {
    enforcePhase("Window.suggest_min_size!", during_update);
    const effect = EffectScope.begin("Window.suggest_min_size!", 0);
    defer effect.end();
    if (headlessMode()) return;
    raylib.suggestWindowMinSize(nonNegativeCInt(args.width), nonNegativeCInt(args.height));
}

/// `Window.suggest_position!`: move the window's top-left corner.
///
/// Nothing is validated here. Every position is meaningful to some multi-monitor
/// desktop -- negative coordinates are ordinary on a display left of the primary
/// one -- and the window manager is the only thing that knows which are not.
fn hostedSuggestWindowPosition(args: abi.HostABIWindow_suggest_positionArgs) callconv(.c) void {
    enforcePhase("Window.suggest_position!", during_update);
    const effect = EffectScope.begin("Window.suggest_position!", 0);
    defer effect.end();
    if (headlessMode()) return;
    raylib.suggestWindowPosition(args.x, args.y);
}

/// `Window.suggest_monitor!`: move the window to a monitor by index.
///
/// An index outside the connected set is ignored rather than reported: which
/// monitors exist can change between the `Window.monitors!` that produced the
/// index and this call, so a stale index is a race the app cannot prevent, not
/// a fault it can act on.
fn hostedSuggestWindowMonitor(monitor: i32) callconv(.c) void {
    enforcePhase("Window.suggest_monitor!", during_update);
    const effect = EffectScope.begin("Window.suggest_monitor!", 0);
    defer effect.end();
    if (headlessMode()) return;
    raylib.suggestWindowMonitor(monitor);
}

/// A scale factor the app can safely divide by.
///
/// The windowing backend answers `0` for a window it has not finished creating,
/// and a fresh window on a display that has just been unplugged can answer with
/// a non-finite factor. Both would silently corrupt every size derived from
/// them, so they become `1`, the scale of an ordinary display.
fn usableScaleFactor(value: f32) f32 {
    if (!std.math.isFinite(value) or value <= 0) return DEFAULT_WINDOW_SCALE;
    return value;
}

/// A monitor coordinate as an integer, saturating rather than trapping.
///
/// The backend states monitor positions as floats even though they are whole
/// virtual-desktop pixels. A direct conversion is undefined for a value outside
/// `i32`, and the host must not be the thing that stops working because a
/// display driver answered strangely. The comparison widens to `f64` because
/// `i32`'s bounds are exactly representable there and not in `f32`.
fn monitorCoordinate(value: f32) i32 {
    if (std.math.isNan(value)) return 0;
    const widened: f64 = value;
    if (widened <= @as(f64, std.math.minInt(i32))) return std.math.minInt(i32);
    if (widened >= @as(f64, std.math.maxInt(i32))) return std.math.maxInt(i32);
    return @intFromFloat(widened);
}

/// `Window.scale!`: how many framebuffer pixels one logical unit is.
///
/// The backend already holds both factors, so this copies two floats and
/// allocates nothing -- which is why it is legal during `render!` too, where a
/// shader or a capture wants the pixel resolution of the surface it is on.
fn hostedWindowScaleDpi() callconv(.c) abi.HostABIWindow_scale_dpiRetRecord {
    enforcePhase("Window.scale!", constant_time_anywhere);
    const effect = EffectScope.begin("Window.scale!", 0);
    defer effect.end();
    if (headlessMode()) return .{ .x = DEFAULT_WINDOW_SCALE, .y = DEFAULT_WINDOW_SCALE };
    const scale = raylib.getWindowScaleDpi();
    return .{ .x = usableScaleFactor(scale.x), .y = usableScaleFactor(scale.y) };
}

/// The one virtual monitor a headless run reports.
///
/// Sized from the configured window, so `--host-headless` output stays a
/// function of the app's own configuration rather than of the CI machine.
fn headlessMonitor(roc_host: *RocHost) abi.HostABIWindow_monitors {
    return .{
        .index = 0,
        .name = abi.RocStr.fromSlice(HEADLESS_MONITOR_NAME, roc_host),
        .width = headless_screen_width,
        .height = headless_screen_height,
        .x = 0,
        .y = 0,
        .refresh_hz = HEADLESS_MONITOR_REFRESH_HZ,
    };
}

/// One monitor as the windowing backend currently describes it.
///
/// The name pointer belongs to the backend: it is null for an index the backend
/// does not know, must never be freed, and is invalidated by the next backend
/// call -- so it is copied into a Roc `Str` here. Native monitor names are not
/// guaranteed to be UTF-8, and a Roc `Str` must be, so an invalid one becomes
/// the replacement character rather than an invalid string, exactly as argv
/// does.
fn nativeMonitor(roc_host: *RocHost, index: i32) abi.HostABIWindow_monitors {
    const monitor = nonNegativeCInt(index);
    const position = raylib.getMonitorPosition(monitor);
    const name = if (raylib.getMonitorName(monitor)) |pointer| std.mem.span(pointer) else "";
    return .{
        .index = index,
        .name = abi.RocStr.fromSlice(
            if (std.unicode.utf8ValidateSlice(name)) name else "\xEF\xBF\xBD",
            roc_host,
        ),
        .width = @intCast(raylib.getMonitorWidth(monitor)),
        .height = @intCast(raylib.getMonitorHeight(monitor)),
        .x = monitorCoordinate(position.x),
        .y = monitorCoordinate(position.y),
        .refresh_hz = @intCast(raylib.getMonitorRefreshRate(monitor)),
    };
}

/// `Window.monitors!`: every display the windowing backend can see.
///
/// The bound is the operating system's own monitor count: the backend is asked
/// how many there are, exactly that many entries are built, and the host retains
/// none of them -- the list belongs to Roc as soon as it is returned. Reading
/// them copies a name per monitor, so this is an ordinary state-changing-phase
/// effect rather than a `render!` query.
fn hostedMonitors(roc_host: *RocHost) callconv(.c) abi.RocList(abi.HostABIWindow_monitors) {
    enforcePhase("Window.monitors!", during_update);
    const effect = EffectScope.begin("Window.monitors!", 0);
    defer effect.end();

    const count: usize = if (headlessMode()) 1 else @intCast(@max(raylib.getMonitorCount(), 0));
    if (count == 0) return abi.RocList(abi.HostABIWindow_monitors).empty();

    const list = abi.RocList(abi.HostABIWindow_monitors).allocate(count, roc_host);
    if (list.elements_ptr) |entries| {
        for (entries[0..count], 0..) |*entry, index| {
            entry.* = if (headlessMode())
                headlessMonitor(roc_host)
            else
                nativeMonitor(roc_host, @intCast(index));
        }
    }
    return list;
}

fn exportedMonitors() callconv(.c) abi.RocList(abi.HostABIWindow_monitors) {
    return hostedMonitors(activeHost());
}

fn hostedSetExitKey(key_code: i32) callconv(.c) void {
    enforcePhase("Keys.set_exit_key!", during_update);
    const effect = EffectScope.begin("Keys.set_exit_key!", 0);
    defer effect.end();
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

/// `Capture.start!`: begin a recording.
///
/// Refusals are latched in the session for the next `input.capture`. The return
/// code preserves the hosted ABI and supports direct tests.
fn hostedCaptureStartRecording(roc_host: *RocHost, args: abi.HostABICapture_start_recordingArgs) callconv(.c) u8 {
    enforcePhase("Capture.start!", during_update);
    const effect = EffectScope.begin("Capture.start!", 0);
    defer effect.end();
    defer args.path.decref(roc_host);
    const result = startCaptureRecording(.{
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
    if (result != capture.err_none) capture_session.refuse(result);
    return result;
}

fn exportedCaptureStartRecording(args: abi.HostABICapture_start_recordingArgs) callconv(.c) u8 {
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
        capture_session.abandon();
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
            capture_session.abandon();
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

fn hostedCaptureSetVirtualMouse(args: abi.HostABICapture_set_virtual_mouseArgs) callconv(.c) void {
    enforcePhase("Mouse.set_source!", during_update);
    const effect = EffectScope.begin("Mouse.set_source!", 0);
    defer effect.end();
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
    // The sum is the field above; the event list gets the notch as well.
    if (args.wheel != 0) raylib.recordVirtualWheel(0, args.wheel);
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

/// Install the set of keys a scripted keyboard holds down, or release it.
///
/// A code the host has no slot for is dropped: `Keys.Key` admits a validated
/// raw code, and the packed state list is one byte per raylib key code, so a
/// code past the end names a key this backend cannot report either way.
fn applyVirtualKeys(active: bool, codes: []const u64) void {
    virtual_key_down = @splat(false);
    virtual_keys_active = active;
    if (!active) return;
    for (codes) |code| {
        if (code < ffi.KEY_COUNT) virtual_key_down[@intCast(code)] = true;
    }
}

/// Queue scripted codepoints as the next input's text.
///
/// The excess past the interval's capacity is discarded and reported as an
/// overflow, exactly as the hardware channel reports its own.
fn applyVirtualText(codepoints: []const u32) void {
    const kept = @min(codepoints.len, virtual_text.len);
    @memcpy(virtual_text[0..kept], codepoints[0..kept]);
    virtual_text_len = kept;
    virtual_text_overflowed = codepoints.len > kept;
    // Every codepoint goes to the event list in script order, the one past
    // the text cap included: the list has its own, larger bound.
    for (codepoints) |codepoint| raylib.recordVirtualText(codepoint);
}

/// Take the queued scripted text, or null when the frame's text is hardware's.
///
/// Taking rather than reading: text arrives on one frame and not the next, so
/// a script that queued nothing this frame hands the channel back rather than
/// repeating what it said last time.
fn takeVirtualText() ?raylib.TextInput {
    if (virtual_text_len == 0) return null;
    const queued = virtual_text[0..virtual_text_len];
    const overflowed = virtual_text_overflowed;
    virtual_text_len = 0;
    virtual_text_overflowed = false;
    return .{ .codepoints = queued, .overflowed = overflowed };
}

/// Forget every scripted input, so one app lifetime cannot inherit another's.
fn resetVirtualInput() void {
    virtual_mouse_active = false;
    virtual_mouse_has_last = false;
    virtual_mouse_buttons = @splat(false);
    virtual_mouse_wheel = 0;
    virtual_mouse_x = 0;
    virtual_mouse_y = 0;
    virtual_keys_active = false;
    virtual_key_down = @splat(false);
    virtual_text_len = 0;
    virtual_text_overflowed = false;
    raylib.clearKeyState();
    raylib.clearMouseButtonState();
    raylib.clearInputEvents();
}

fn hostedCaptureSetVirtualKeys(host: *RocHost, args: abi.HostABICapture_set_virtual_keysArgs) callconv(.c) void {
    enforcePhase("Keys.set_source!", during_update);
    const effect = EffectScope.begin("Keys.set_source!", args.keys.items().len * @sizeOf(u64));
    defer effect.end();
    defer args.keys.decref(host);
    applyVirtualKeys(args.active, args.keys.items());
}

fn exportedCaptureSetVirtualKeys(args: abi.HostABICapture_set_virtual_keysArgs) callconv(.c) void {
    hostedCaptureSetVirtualKeys(activeHost(), args);
}

fn hostedCaptureSetVirtualText(host: *RocHost, text: abi.RocListWith(u32, false)) callconv(.c) void {
    enforcePhase("Keys.set_text!", during_update);
    const effect = EffectScope.begin("Keys.set_text!", text.items().len * @sizeOf(u32));
    defer effect.end();
    defer text.decref(host);
    applyVirtualText(text.items());
}

fn exportedCaptureSetVirtualText(text: abi.RocListWith(u32, false)) callconv(.c) void {
    hostedCaptureSetVirtualText(activeHost(), text);
}

fn hostedCaptureStopRecording() callconv(.c) abi.HostABICapture_stop_recordingRetRecord {
    enforcePhase("Capture.stop!", during_update);
    const effect = EffectScope.begin("Capture.stop!", 0);
    defer effect.end();
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

/// The recording state sampled into every input.
///
/// Starting and stopping are effects called from `update!`, and a recording
/// can also end on its own -- at its frame cap, or on an encoder failure -- so
/// the input is where an app learns what happened without asking every frame.
/// It is five scalars, so it rides along on the input record rather than
/// costing a host call on every frame regardless of whether anything is
/// recording.
fn captureStateForStep() CaptureFromHost {
    return .{
        .status = capture_session.status,
        .err = capture_session.failure,
        .frames = capture_session.captured_frames,
        .dropped = capture_session.dropped_frames,
        .bytes = capture_recording_bytes,
    };
}

/// `Window.read_clipboard!`: the clipboard as text, or why not.
///
/// The windowing backend only answers on the thread that owns the window, and
/// the read is a pointer copy rather than I/O, so there is nothing to move off
/// the frame thread and nothing to wait for -- this is a state read, legal
/// wherever host state is read, and it never parks.
///
/// The clipboard is arbitrary content from outside the app: another process
/// decides how big it is, and turning it into a `Str` is a copy and a UTF-8
/// scan on this thread. Cap it where a text read is capped, and for the same
/// reason.
fn hostedReadClipboard(roc_host: *RocHost) callconv(.c) abi.HostABIWindow_read_clipboardRetRecord {
    enforcePhase("Window.read_clipboard!", during_update);
    const effect = EffectScope.begin("Window.read_clipboard!", 0);
    defer effect.end();

    if (headlessMode()) {
        if (!headless_clipboard_set) return .{ .err = READ_ERR_UNAVAILABLE, .contents = abi.RocStr.empty() };
        return .{
            .err = 0,
            .contents = abi.RocStr.fromSlice(headless_clipboard[0..headless_clipboard_len], roc_host),
        };
    }

    // The pointer belongs to the windowing backend: it is null when the
    // clipboard is empty or holds non-text content, must never be freed, and is
    // invalidated by the next clipboard call -- so copy it out now.
    const text = raylib.getClipboardText() orelse
        return .{ .err = READ_ERR_UNAVAILABLE, .contents = abi.RocStr.empty() };
    const contents = std.mem.span(text);
    if (contents.len > MAX_INLINE_READ_BYTES) {
        return .{ .err = READ_ERR_TOO_LARGE, .contents = abi.RocStr.empty() };
    }
    return .{ .err = 0, .contents = abi.RocStr.fromSlice(contents, roc_host) };
}

fn exportedReadClipboard() callconv(.c) abi.HostABIWindow_read_clipboardRetRecord {
    return hostedReadClipboard(activeHost());
}

fn hostedSetClipboardText(roc_host: *RocHost, text_arg: abi.RocStr) callconv(.c) void {
    enforcePhase("Window.set_clipboard_text!", during_update);
    const effect = EffectScope.begin("Window.set_clipboard_text!", text_arg.asSlice().len);
    defer effect.end();
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
    enforcePhase("Mouse.set_cursor_mode!", during_update);
    const effect = EffectScope.begin("Mouse.set_cursor_mode!", 0);
    defer effect.end();
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
    enforcePhase("Mouse.set_cursor!", during_update);
    const effect = EffectScope.begin("Mouse.set_cursor!", 0);
    defer effect.end();
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
    try std.testing.expectEqual(READ_ERR_UNAVAILABLE, hostedReadClipboard(&roc_host).err);

    hostedSetClipboardText(&roc_host, abi.RocStr.fromSlice("copied", &roc_host));
    const stored = hostedReadClipboard(&roc_host);
    defer stored.contents.decref(&roc_host);
    try std.testing.expectEqual(@as(u8, 0), stored.err);
    try std.testing.expectEqualStrings("copied", stored.contents.asSlice());

    // A write that cannot fit leaves the previous contents intact, and still
    // releases the Roc string it was handed.
    const oversized = abi.RocStr.fromSlice(&([_]u8{'x'} ** (HEADLESS_CLIPBOARD_CAPACITY + 1)), &roc_host);
    hostedSetClipboardText(&roc_host, oversized);
    const unchanged = hostedReadClipboard(&roc_host);
    defer unchanged.contents.decref(&roc_host);
    try std.testing.expectEqualStrings("copied", unchanged.contents.asSlice());
}

/// `App.Startup.entropy!`: one draw from the operating system's entropy.
///
/// The only thing in this host that makes a run differ from the last one by
/// itself. It answers with real entropy in headless runs too: an app that must
/// reproduce says so by writing a constant seed, and a host that quietly
/// handed out the same number every run would take that choice away instead of
/// making it. Obtaining it does not block, so this needs none of the parking
/// machinery a waiting effect has.
fn hostedEntropy() callconv(.c) u64 {
    enforcePhase("App.Startup.entropy!", during_startup);
    const effect = EffectScope.begin("App.Startup.entropy!", 0);
    defer effect.end();
    var bytes: [8]u8 = undefined;
    std.Io.random(waitingIo(), &bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

fn hostedRandomI32(min: i32, max: i32) callconv(.c) i32 {
    enforcePhase("App.Startup.random_i32!", during_startup);
    const effect = EffectScope.begin("App.Startup.random_i32!", 0);
    defer effect.end();
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

fn hostedAudioGenTone(args: abi.HostABIAudio_gen_toneArgs) callconv(.c) abi.HostABIAudio_gen_toneRetRecord {
    enforcePhase("Audio.gen_tone!", during_load);
    const effect = EffectScope.begin("Audio.gen_tone!", 0);
    defer effect.end();
    if (headlessMode()) {
        const sound = storeSound(.headless) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .sound = sound, .err = RESOURCE_ERR_NONE };
    }
    const sound = raylib.genTone(args.freq, args.ms) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeSound(.{ .native = sound }) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .sound = stored, .err = RESOURCE_ERR_NONE };
}

fn hostedAudioGenSound(args: abi.HostABIAudio_gen_soundArgs) callconv(.c) abi.HostABIAudio_gen_soundRetRecord {
    enforcePhase("Audio.gen_sound!", during_load);
    const effect = EffectScope.begin("Audio.gen_sound!", 0);
    defer effect.end();
    if (headlessMode()) {
        const sound = storeSound(.headless) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .sound = sound, .err = RESOURCE_ERR_NONE };
    }
    const sound = raylib.genSound(args) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeSound(.{ .native = sound }) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .sound = stored, .err = RESOURCE_ERR_NONE };
}

/// The extension raylib's in-memory audio decoders dispatch on.
///
/// The format is taken from the path rather than sniffed, which is how every
/// other loader in this host decides, and an extension raylib was not built
/// with fails here rather than inside a decoder that would not recognise the
/// bytes. Module music -- `.xm` and `.mod` -- streams but does not decode into
/// a `Sound`, so it is a music-only spelling.
fn audioFileTypeFromPath(path: []const u8, module_music: bool) ?[*:0]const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".wav")) return ".wav";
    if (std.ascii.eqlIgnoreCase(extension, ".ogg")) return ".ogg";
    if (std.ascii.eqlIgnoreCase(extension, ".mp3")) return ".mp3";
    if (std.ascii.eqlIgnoreCase(extension, ".qoa")) return ".qoa";
    if (std.ascii.eqlIgnoreCase(extension, ".flac")) return ".flac";
    if (module_music) {
        if (std.ascii.eqlIgnoreCase(extension, ".xm")) return ".xm";
        if (std.ascii.eqlIgnoreCase(extension, ".mod")) return ".mod";
    }
    return null;
}

/// `Audio.load_sound!`: read an audio file and decode it onto the device.
///
/// The read waits -- it parks a task and blocks `init!` -- and the decode and
/// the upload run on the frame thread once the bytes are back. Nothing of the
/// file survives the call: `LoadSoundFromWave` copies the samples it needs.
fn hostedAudioLoadSound(host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.HostABIAudio_load_soundRetRecord {
    enforcePhase("Audio.load_sound!", during_wait);
    const effect = EffectScope.begin("Audio.load_sound!", path_arg.asSlice().len);
    defer effect.end();
    defer path_arg.decref(host);

    const path_slice = path_arg.asSlice();
    const allocator = allocatorFromHost(host);
    var read_err: u8 = READ_ERR_FAILED;
    const bytes = readFileWaiting(allocator, path_slice, MAX_AUDIO_FILE_BYTES + 1, &read_err) orelse
        return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    defer allocator.free(bytes);

    if (headlessMode()) {
        const sound = storeSound(.headless) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .sound = sound, .err = RESOURCE_ERR_NONE };
    }

    const file_type = audioFileTypeFromPath(path_slice, false) orelse
        return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const sound = raylib.loadSoundFromMemory(file_type, bytes) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeSound(.{ .native = sound }) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .sound = stored, .err = RESOURCE_ERR_NONE };
}

fn exportedAudioLoadSound(path_arg: abi.RocStr) callconv(.c) abi.HostABIAudio_load_soundRetRecord {
    return hostedAudioLoadSound(activeHost(), path_arg);
}

/// `Audio.load_music!`: read an audio file and open a stream over it.
///
/// The read waits the same way `load_sound!` does, but the bytes are not
/// released afterwards: raylib's memory decoders read out of that buffer for
/// as long as the stream plays, so the slot takes ownership of it and frees it
/// only once the stream has been unloaded.
fn hostedAudioLoadMusic(host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.HostABIAudio_load_musicRetRecord {
    enforcePhase("Audio.load_music!", during_wait);
    const effect = EffectScope.begin("Audio.load_music!", path_arg.asSlice().len);
    defer effect.end();
    defer path_arg.decref(host);

    const path_slice = path_arg.asSlice();
    const allocator = allocatorFromHost(host);
    var read_err: u8 = READ_ERR_FAILED;
    const bytes = readFileWaiting(allocator, path_slice, MAX_AUDIO_FILE_BYTES + 1, &read_err) orelse
        return .{ .music = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    var bytes_transferred = false;
    defer if (!bytes_transferred) allocator.free(bytes);

    if (headlessMode()) {
        const music = storeMusic(.headless) orelse return .{ .music = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .music = music, .err = RESOURCE_ERR_NONE };
    }

    const file_type = audioFileTypeFromPath(path_slice, true) orelse
        return .{ .music = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const music = raylib.loadMusicFromMemory(file_type, bytes) orelse return .{ .music = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeMusic(.{ .native = .{ .stream = music, .encoded = bytes, .allocator = allocator } }) orelse {
        raylib.unloadMusic(music);
        return .{ .music = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    };
    bytes_transferred = true;
    return .{ .music = stored, .err = RESOURCE_ERR_NONE };
}

fn exportedAudioLoadMusic(path_arg: abi.RocStr) callconv(.c) abi.HostABIAudio_load_musicRetRecord {
    return hostedAudioLoadMusic(activeHost(), path_arg);
}

test "the audio file loaders wait rather than load" {
    // A sound and a music stream both start with a file read, which is what
    // moved: `update!` can no longer reach one, and the decode that follows is
    // still frame-thread work on bytes already in hand.
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        last_phase_violation = null;
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        sound_heap.deinitAll();
        music_heap.deinitAll();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blip.wav", .data = "not decoded in headless tests" });
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, testing_tmp_prefix ++ "{s}/blip.wav", .{tmp.sub_path});

    {
        const update = PhaseScope.enter(.update);
        defer update.leave();
        last_phase_violation = null;
        _ = hostedAudioLoadSound(&roc_host, abi.RocStr.fromSlice(path, &roc_host));
        const violation = last_phase_violation orelse return error.OperationWasNotRejected;
        try std.testing.expectEqualStrings("Audio.load_sound!", violation.operation);
        try std.testing.expect(violation.allowed.eql(during_wait));
        try std.testing.expectEqual(Phase.update, violation.actual);

        last_phase_violation = null;
        _ = hostedAudioLoadMusic(&roc_host, abi.RocStr.fromSlice(path, &roc_host));
        const music_violation = last_phase_violation orelse return error.OperationWasNotRejected;
        try std.testing.expectEqualStrings("Audio.load_music!", music_violation.operation);
        try std.testing.expect(music_violation.allowed.eql(during_wait));
    }

    // `init!` blocks for the read and a task parks for it; both answer.
    const startup = PhaseScope.enter(.startup);
    last_phase_violation = null;
    const sound = hostedAudioLoadSound(&roc_host, abi.RocStr.fromSlice(path, &roc_host));
    try std.testing.expectEqual(RESOURCE_ERR_NONE, sound.err);
    startup.leave();

    const task = PhaseScope.enter(.task);
    defer task.leave();
    const music = hostedAudioLoadMusic(&roc_host, abi.RocStr.fromSlice(path, &roc_host));
    try std.testing.expectEqual(RESOURCE_ERR_NONE, music.err);
    try std.testing.expect(last_phase_violation == null);

    // A path with nothing behind it is a load failure rather than a resource.
    const missing = hostedAudioLoadSound(&roc_host, abi.RocStr.fromSlice(testing_tmp_prefix ++ "no-such-sound.wav", &roc_host));
    try std.testing.expectEqual(RESOURCE_ERR_FAILED, missing.err);

    releaseResourceBox(&roc_host, sound.sound);
    releaseResourceBox(&roc_host, music.music);
}

test "an extension raylib cannot decode is refused, and module music is music only" {
    try std.testing.expect(audioFileTypeFromPath("track.ogg", false) != null);
    try std.testing.expect(audioFileTypeFromPath("track.OGG", false) != null);
    try std.testing.expect(audioFileTypeFromPath("track.aiff", true) == null);
    try std.testing.expect(audioFileTypeFromPath("track", true) == null);
    // `.xm` and `.mod` stream but never decode into a `Sound`.
    try std.testing.expect(audioFileTypeFromPath("theme.xm", true) != null);
    try std.testing.expect(audioFileTypeFromPath("theme.xm", false) == null);
}

// The audio entry points below guard their `.native` arm with `builtin.is_test`
// rather than returning early, the way the scoped drawing operations do. The
// guard exists only to keep raylib's audio symbols out of the test link -- a
// unit test never reaches a `.native` resource, since everything it stores is
// `.headless` -- and keeping it inside the arm leaves the handle lookup itself
// running, which is the part worth testing: an unresolvable token has to reach
// the `orelse return` and still release the reference it was handed.
fn hostedAudioPlay(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.play!", during_update);
    const effect = EffectScope.begin("Audio.Sound.play!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.playSound(sound),
    }
}

fn hostedAudioStop(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.stop!", during_update);
    const effect = EffectScope.begin("Audio.Sound.stop!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.stopSound(sound),
    }
}

fn hostedAudioPause(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.pause!", during_update);
    const effect = EffectScope.begin("Audio.Sound.pause!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.pauseSound(sound),
    }
}

fn hostedAudioResume(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.resume!", during_update);
    const effect = EffectScope.begin("Audio.Sound.resume!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.resumeSound(sound),
    }
}

fn hostedAudioIsPlaying(handle: *u64) callconv(.c) bool {
    enforcePhase("Audio.Sound.is_playing!", constant_time_anywhere);
    const effect = EffectScope.begin("Audio.Sound.is_playing!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return false;
    return switch (resource.*) {
        .headless => false,
        .native => |sound| if (builtin.is_test) false else raylib.isSoundPlaying(sound),
    };
}

fn hostedAudioSetVolume(handle: *u64, volume: f32) callconv(.c) void {
    enforcePhase("Audio.Sound.set_volume!", during_update);
    const effect = EffectScope.begin("Audio.Sound.set_volume!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.setSoundVolume(sound, volume),
    }
}

fn hostedAudioSetPitch(handle: *u64, pitch: f32) callconv(.c) void {
    enforcePhase("Audio.Sound.set_pitch!", during_update);
    const effect = EffectScope.begin("Audio.Sound.set_pitch!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.setSoundPitch(sound, pitch),
    }
}

fn hostedAudioSetPan(handle: *u64, pan: f32) callconv(.c) void {
    enforcePhase("Audio.Sound.set_pan!", during_update);
    const effect = EffectScope.begin("Audio.Sound.set_pan!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.setSoundPan(sound, pan),
    }
}

fn hostedAudioPlayMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.play!", during_update);
    const effect = EffectScope.begin("Audio.Music.play!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.playMusic(music.stream),
    }
}

fn hostedAudioStopMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.stop!", during_update);
    const effect = EffectScope.begin("Audio.Music.stop!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.stopMusic(music.stream),
    }
}

fn hostedAudioPauseMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.pause!", during_update);
    const effect = EffectScope.begin("Audio.Music.pause!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.pauseMusic(music.stream),
    }
}

fn hostedAudioResumeMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.resume!", during_update);
    const effect = EffectScope.begin("Audio.Music.resume!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.resumeMusic(music.stream),
    }
}

fn hostedAudioSetMusicVolume(handle: *u64, volume: f32) callconv(.c) void {
    enforcePhase("Audio.Music.set_volume!", during_update);
    const effect = EffectScope.begin("Audio.Music.set_volume!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.setMusicVolume(music.stream, volume),
    }
}

fn hostedAudioSetMusicPitch(handle: *u64, pitch: f32) callconv(.c) void {
    enforcePhase("Audio.Music.set_pitch!", during_update);
    const effect = EffectScope.begin("Audio.Music.set_pitch!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.setMusicPitch(music.stream, pitch),
    }
}

fn hostedAudioSetMusicPan(handle: *u64, pan: f32) callconv(.c) void {
    enforcePhase("Audio.Music.set_pan!", during_update);
    const effect = EffectScope.begin("Audio.Music.set_pan!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.setMusicPan(music.stream, pan),
    }
}

fn hostedAudioSetMusicLooping(handle: *u64, looping: bool) callconv(.c) void {
    enforcePhase("Audio.Music.set_looping!", during_update);
    const effect = EffectScope.begin("Audio.Music.set_looping!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |*music| raylib.setMusicLooping(&music.stream, looping),
    }
}

fn hostedAudioIsMusicPlaying(handle: *u64) callconv(.c) bool {
    enforcePhase("Audio.Music.is_playing!", constant_time_anywhere);
    const effect = EffectScope.begin("Audio.Music.is_playing!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return false;
    return switch (resource.*) {
        .headless => false,
        .native => |music| if (builtin.is_test) false else raylib.isMusicPlaying(music.stream),
    };
}

fn hostedAudioSeekMusic(handle: *u64, seconds: f32) callconv(.c) void {
    enforcePhase("Audio.Music.seek!", during_update);
    const effect = EffectScope.begin("Audio.Music.seek!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.seekMusic(music.stream, seconds),
    }
}

fn hostedAudioMusicLength(handle: *u64) callconv(.c) f32 {
    enforcePhase("Audio.Music.length!", constant_time_anywhere);
    const effect = EffectScope.begin("Audio.Music.length!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return 0;
    return switch (resource.*) {
        .headless => 0,
        .native => |music| if (builtin.is_test) 0 else raylib.musicLength(music.stream),
    };
}

fn hostedAudioMusicTimePlayed(handle: *u64) callconv(.c) f32 {
    enforcePhase("Audio.Music.time_played!", constant_time_anywhere);
    const effect = EffectScope.begin("Audio.Music.time_played!", 0);
    defer effect.end();
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return 0;
    return switch (resource.*) {
        .headless => 0,
        .native => |music| if (builtin.is_test) 0 else raylib.musicTimePlayed(music.stream),
    };
}

fn hostedAudioSetMasterVolume(volume: f32) callconv(.c) void {
    enforcePhase("Audio.set_master_volume!", during_update);
    const effect = EffectScope.begin("Audio.set_master_volume!", 0);
    defer effect.end();
    if (active_headless) return;
    raylib.setMasterVolume(volume);
}

fn updateMusicResource(resource: *MusicResource) void {
    switch (resource.*) {
        .headless => {},
        .native => |*music| raylib.updateMusicStream(&music.stream),
    }
}

fn updateMusicStreams() void {
    music_heap.forEach(updateMusicResource);
}

fn deinitResources() void {
    // Frees this app lifetime's last framebuffer snapshot, if it kept one.
    releaseScreenSnapshot();
    screen_snapshot_requested = false;

    // The final model has been dropped, so everything it held is retired.
    // Release the configured startup-font cache now that no startup call can
    // ask for another alias. The built-in font uses static token zero and owns
    // no heap slot.
    releaseStartupFontHandle(activeHost());
    // Destroy it all before the assertions below, which are about whether Roc
    // *released* its handles rather than about when the host got round to the
    // driver calls. Shutdown drains the complete retirement queue.
    drainRetiredResourcesUpTo(std.math.maxInt(usize));

    // Roc should have released every handle by the time the final model is
    // dropped. Keep a shutdown drain for optimized builds, but catch lifecycle
    // regressions in the debug host used by the test suite.
    std.debug.assert(render_texture_lease_count == 0);
    std.debug.assert(shader_lease_count == 0);
    std.debug.assert(blend_scope_count == 0);
    std.debug.assert(camera_scope_count == 0);
    std.debug.assert(scissor_scope_count == 0);
    // App shutdown clears delivery promises, through `clearAfterWorkStops`,
    // before resource teardown. A non-zero value here would make the next app
    // lifetime under-admit reads.
    std.debug.assert(file_bytes_delivery_reservations.count == 0);
    std.debug.assert(cmd_effect.admittedCount() == 0);
    std.debug.assert(texture_heap.active() == 0);
    std.debug.assert(render_texture_heap.active() == 0);
    std.debug.assert(shader_heap.active() == 0);
    std.debug.assert(prepared_text_heap.active() == 0);
    std.debug.assert(font_heap.active() == 0);
    std.debug.assert(music_heap.active() == 0);
    std.debug.assert(sound_heap.active() == 0);
    std.debug.assert(file_bytes_heap.active() == 0);
    std.debug.assert(store_heap.active() == 0);
    std.debug.assert(udp_socket_heap.active() == 0);
    udp_socket_heap.deinitAll();
    std.debug.assert(sqlite_effect.stmt_heap.active() == 0);
    std.debug.assert(sqlite_effect.db_heap.active() == 0);
    sqlite_effect.stmt_heap.deinitAll();
    sqlite_effect.db_heap.deinitAll();
    sqlite_effect.shutdown();
    file_bytes_heap.deinitAll();
    store_heap.deinitAll();
    shader_heap.deinitAll();
    prepared_text_heap.deinitAll();
    render_texture_heap.deinitAll();
    texture_heap.deinitAll();
    font_heap.deinitAll();
    startup_font_handle = null;
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

        @export(&hostedSqliteOpen, .{ .name = "roc_sqlite_open" });
        @export(&hostedSqliteClose, .{ .name = "roc_sqlite_close" });
        @export(&hostedSqlitePrepare, .{ .name = "roc_sqlite_prepare" });
        @export(&hostedSqliteRunStmt, .{ .name = "roc_sqlite_run_stmt" });
        @export(&hostedSqliteRunOnce, .{ .name = "roc_sqlite_run_once" });
        @export(&hostedSqliteExecScript, .{ .name = "roc_sqlite_exec_script" });
        @export(&hostedTraceMark, .{ .name = "roc_trace_mark" });
        @export(&hostedTraceBegin, .{ .name = "roc_trace_begin" });
        @export(&hostedTraceEnd, .{ .name = "roc_trace_end" });
        @export(&hostedTraceSampleI64, .{ .name = "roc_trace_sample_i64" });
        @export(&hostedTraceSampleF64, .{ .name = "roc_trace_sample_f64" });

        @export(&exportedAssetsOpenStoreRaw, .{ .name = "roc_assets_open_store_raw" });
        @export(&exportedTextureLoadStoreRaw, .{ .name = "roc_texture_load_store_raw" });
        @export(&exportedTextureLoadBytesRaw, .{ .name = "roc_texture_load_bytes_raw" });
        @export(&hostedTextureGenerateColorRaw, .{ .name = "roc_texture_generate_color_raw" });
        @export(&hostedTextureGenerateCheckedRaw, .{ .name = "roc_texture_generate_checked_raw" });
        @export(&exportedTextureUpdateRaw, .{ .name = "roc_texture_update_raw" });
        @export(&exportedTextureUpdateRegionRaw, .{ .name = "roc_texture_update_region_raw" });
        @export(&hostedTextureSetFilterRaw, .{ .name = "roc_texture_set_filter_raw" });
        @export(&hostedTextureSetWrapRaw, .{ .name = "roc_texture_set_wrap_raw" });
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
        @export(&exportedDrawTextureInstancesRaw, .{ .name = "roc_draw_draw_texture_instances_raw" });
        @export(&hostedDrawTextureQuadRaw, .{ .name = "roc_draw_draw_texture_quad_raw" });
        @export(&hostedDrawEndCamera, .{ .name = "roc_draw_end_camera" });
        @export(&hostedDrawEndBlendRaw, .{ .name = "roc_draw_end_blend_raw" });
        @export(&hostedDrawEndRenderTextureRaw, .{ .name = "roc_draw_end_render_texture_raw" });
        @export(&hostedDrawEndScissorRaw, .{ .name = "roc_draw_end_scissor_raw" });
        @export(&hostedDrawEndShaderRaw, .{ .name = "roc_draw_end_shader_raw" });
        @export(&hostedDrawFps, .{ .name = "roc_draw_fps" });
        @export(&hostedTextDefaultFontRaw, .{ .name = "roc_text_default_font_raw" });
        @export(&exportedTextStartupDefaultFontRaw, .{ .name = "roc_text_startup_default_font_raw" });
        @export(&exportedTextFontMetricsRaw, .{ .name = "roc_text_font_metrics_raw" });
        @export(&hostedDrawFrameSizeRaw, .{ .name = "roc_draw_frame_size" });
        @export(&hostedDrawLineRaw, .{ .name = "roc_draw_line_raw" });
        @export(&exportedTextLoadFontBytesRaw, .{ .name = "roc_text_load_font_bytes_raw" });
        @export(&exportedTextLoadStoreFontRaw, .{ .name = "roc_text_load_store_font_raw" });
        @export(&hostedTextureLoadRenderTargetRaw, .{ .name = "roc_texture_load_render_target_raw" });
        @export(&exportedDrawLoadShaderSourceRaw, .{ .name = "roc_draw_load_shader_source_raw" });
        @export(&exportedDrawLoadStoreShaderRaw, .{ .name = "roc_draw_load_store_shader_raw" });
        @export(&exportedTextPrepareRaw, .{ .name = "roc_text_prepare_raw" });
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
        @export(&exportedDrawTextRaw, .{ .name = "roc_draw_text_raw" });
        @export(&hostedDrawTriangleLinesRaw, .{ .name = "roc_draw_triangle_lines_raw" });
        @export(&hostedDrawTriangleRaw, .{ .name = "roc_draw_triangle_raw" });
        @export(&exportedArgs, .{ .name = "roc_app_args" });
        @export(&hostedEntropy, .{ .name = "roc_random_entropy" });
        @export(&hostedExit, .{ .name = "roc_app_exit" });
        @export(&hostedTaskSleep, .{ .name = "roc_task_sleep" });
        @export(&exportedFilesReadText, .{ .name = "roc_files_read_text" });
        @export(&exportedFilesReadBytes, .{ .name = "roc_files_read_bytes" });
        @export(&exportedFilesList, .{ .name = "roc_files_list" });
        @export(&exportedFilesMetadata, .{ .name = "roc_files_metadata" });
        @export(&exportedFilesWriteText, .{ .name = "roc_files_write_text" });
        @export(&exportedFilesWriteBytes, .{ .name = "roc_files_write_bytes" });
        @export(&hostedTaskSpawn, .{ .name = "roc_task_spawn" });
        @export(&exportedReadClipboard, .{ .name = "roc_window_read_clipboard" });
        @export(&hostedRandomI32, .{ .name = "roc_random_i32" });
        @export(if (builtin.os.tag == .windows) &exportedAppReadEnvWindows else &exportedAppReadEnvPosix, .{ .name = "roc_app_read_env" });
        @export(&exportedAppReadFile, .{ .name = "roc_app_read_file_raw" });
        @export(&exportedSetClipboardText, .{ .name = "roc_window_set_clipboard_text" });
        @export(&hostedSetExitKey, .{ .name = "roc_keys_set_exit_key" });
        @export(&exportedCaptureStartRecording, .{ .name = "roc_capture_start_recording" });
        @export(&hostedCaptureSetVirtualMouse, .{ .name = "roc_capture_set_virtual_mouse" });
        @export(&exportedCaptureSetVirtualKeys, .{ .name = "roc_capture_set_virtual_keys" });
        @export(&exportedCaptureSetVirtualText, .{ .name = "roc_capture_set_virtual_text" });
        @export(&hostedCaptureStopRecording, .{ .name = "roc_capture_stop_recording" });
        @export(&exportedCaptureScreenshot, .{ .name = "roc_capture_screenshot" });
        @export(&exportedCaptureScreenshotTexture, .{ .name = "roc_capture_screenshot_texture" });
        @export(&exportedCapturePixelAt, .{ .name = "roc_capture_pixel_at" });
        @export(&exportedCaptureReadRegion, .{ .name = "roc_capture_read_region" });
        @export(&hostedSuggestWindowSize, .{ .name = "roc_window_suggest_size" });
        @export(&hostedSetTargetFps, .{ .name = "roc_window_set_target_fps" });
        @export(&hostedSuggestWindowMinSize, .{ .name = "roc_window_suggest_min_size" });
        @export(&hostedSuggestWindowPosition, .{ .name = "roc_window_suggest_position" });
        @export(&hostedSuggestWindowMonitor, .{ .name = "roc_window_suggest_monitor" });
        @export(&hostedWindowScaleDpi, .{ .name = "roc_window_scale_dpi" });
        @export(&exportedMonitors, .{ .name = "roc_window_monitors" });
        @export(&hostedMouseSetCursorModeRaw, .{ .name = "roc_mouse_set_cursor_mode_raw" });
        @export(&hostedMouseSetCursorRaw, .{ .name = "roc_mouse_set_cursor_raw" });
        @export(&exportedTilemapDrawRaw, .{ .name = "roc_tilemap_draw_raw" });
        @export(&exportedTilemapLoadTmxRaw, .{ .name = "roc_tilemap_load_tmx_raw" });
        @export(&hostedHttpSend, .{ .name = "roc_http_send" });
        @export(&hostedTimeNow, .{ .name = "roc_time_now" });
        @export(&exportedStdioWriteText, .{ .name = "roc_stdio_write_text" });
        @export(&exportedStdioWriteLine, .{ .name = "roc_stdio_write_line" });
        @export(&exportedStdioWriteBytes, .{ .name = "roc_stdio_write_bytes" });
        @export(&exportedUdpBind, .{ .name = "roc_udp_bind" });
        @export(&exportedUdpSend, .{ .name = "roc_udp_send" });
        @export(&exportedUdpReceive, .{ .name = "roc_udp_receive" });
        @export(&exportedCmdRun, .{ .name = "roc_cmd_run" });
    }
}

const RuntimeOptions = struct {
    const StatsDetail = enum { summary, standard, full };

    headless: bool = false,
    headless_frames: u64 = DEFAULT_HEADLESS_FRAMES,
    /// Cycles a windowed run is allowed before it exits by itself, or null for
    /// an ordinary run that ends when the window or the app says so. Test
    /// harness only: it bounds an unattended run, it is not an app-facing
    /// lifecycle.
    frames: ?u64 = null,
    /// Force the window hidden regardless of what `App.Config` asked for. The
    /// window, GL context, audio device and capture paths are all still real.
    hidden: bool = false,
    /// Scripted keyboard, in the `--host-keys` syntax below, or null to leave
    /// the keyboard to hardware (and to the app's own `Keys.set_source!`).
    key_script: ?[]const u8 = null,
    /// Scripted typed text, in the `--host-text` syntax below.
    text_script: ?[]const u8 = null,
    debug_allocator: bool = false,
    record_stats: bool = false,
    stats_output: ?[]const u8 = null,
    stats_detail: StatsDetail = .standard,
    stats_buffer_mib: u64 = DEFAULT_STATS_BUFFER_MIB,
    stats_max_mib: u64 = DEFAULT_STATS_MAX_MIB,
    help: bool = false,
    app_args: []const [*:0]u8 = &.{},
    app_args_allocation: ?[][*:0]u8 = null,

    fn deinit(self: RuntimeOptions, allocator: std.mem.Allocator) void {
        if (self.app_args_allocation) |allocation| allocator.free(allocation);
    }
};

const InputState = struct {
    roc_host: *RocHost,
    keys: ffi.Keys,
    mouse_buttons: ffi.MouseButtons,
    gamepad_available: ffi.GamepadAvailability,
    gamepad_buttons: ffi.GamepadButtons,
    gamepad_axes: ffi.GamepadAxes,
    text_input: ffi.TextInput,
    /// This cycle's ordered events, taken once alongside the packed bits and
    /// borrowed from the backend's scratch until `hostState` copies them out.
    events: raylib.InputEvents = .{ .events = &.{}, .overflowed = false },

    fn init(roc_host: *RocHost) InputState {
        return .{
            .roc_host = roc_host,
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
        mouse_x: f32,
        mouse_y: f32,
        mouse_delta: raylib.Vec2,
        mouse_wheel: raylib.Vec2,
        text_input: raylib.TextInput,
    ) InputSnapshot {
        self.text_input.update(text_input.codepoints);
        self.retainForRoc();
        // Fresh each cycle and transferred whole, like the dropped files:
        // Roc releases it with the input.
        const events = inputEventsSnapshot(self.roc_host, self.events);
        self.events = .{ .events = &.{}, .overflowed = false };
        return .{
            .keys = self.keys.list,
            .text_input = self.text_input.list,
            .text_input_overflow = text_input.overflowed,
            .events = events.list,
            .events_overflow = events.overflowed,
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

    /// Sample input for a windowed cycle. `text_source` says whether this
    /// cycle's text is scripted, which decides whose text events are taken.
    fn updateFromRaylib(self: *InputState, text_source: raylib.InputSource) void {
        // A scripted keyboard goes through the same derivation as hardware,
        // so pressed/released this interval behave identically for the app.
        if (virtual_keys_active) {
            raylib.updateKeyboardStateFrom(&virtual_key_down);
        } else {
            raylib.updateKeyboardState();
        }
        self.keys.update(raylib.getKeyState());

        // A scripted pointer goes through the same derivation as hardware,
        // so pressed/released this interval behave identically for the app.
        if (virtual_mouse_active) {
            raylib.updateMouseButtonStateFrom(&virtual_mouse_buttons, .{ .x = virtual_mouse_x, .y = virtual_mouse_y });
        } else {
            raylib.updateMouseButtonState();
        }
        self.mouse_buttons.update(raylib.getMouseButtonState());

        raylib.updateGamepadState();
        self.gamepad_available.update(raylib.getGamepadAvailability());
        self.gamepad_buttons.update(raylib.getGamepadButtonState());
        self.gamepad_axes.update(raylib.getGamepadAxes());

        // After both derivations, so a transition they logged is in this
        // cycle's list next to the bit it set.
        self.events = raylib.takeInputEvents(.{
            .keyboard = if (virtual_keys_active) .virtual else .hardware,
            .mouse = if (virtual_mouse_active) .virtual else .hardware,
            .text = text_source,
        });
    }

    /// Sample input for a headless cycle, where there is no hardware to ask.
    ///
    /// Only scripted input exists here, and it runs through the same edge
    /// detectors a windowed run uses, so a headless test sees the pressed and
    /// released bits real devices would have produced. With nothing scripted
    /// both arrays are all false, which is what no keyboard and no mouse look
    /// like -- so an app that scripts neither sees what it always saw.
    fn updateHeadless(self: *InputState, text_source: raylib.InputSource) void {
        raylib.updateKeyboardStateFrom(&virtual_key_down);
        self.keys.update(raylib.getKeyState());
        raylib.updateMouseButtonStateFrom(&virtual_mouse_buttons, .{ .x = virtual_mouse_x, .y = virtual_mouse_y });
        self.mouse_buttons.update(raylib.getMouseButtonState());
        self.events = raylib.takeInputEvents(.{ .keyboard = .virtual, .mouse = .virtual, .text = text_source });
    }
};

/// One cycle's ordered input events on their way to `update!`.
///
/// `list` is owned; handing it to Roc transfers it, exactly as a cycle's
/// dropped files are transferred.
const InputEventsList = struct {
    list: abi.RocListWith(InputEventRecord, false),
    overflowed: bool,
};

/// Copy this cycle's events into a Roc list, in delivery order.
///
/// The backend's scratch is overwritten by the next recorded event, so the
/// records are copied out here rather than borrowed. The count is already
/// bounded by `raylib.INPUT_EVENT_CAPACITY`; `overflowed` is the backend's
/// word that something past it was discarded, carried through unchanged so
/// an app that got a full list can tell whether it was the whole interval.
fn inputEventsSnapshot(roc_host: *RocHost, events: raylib.InputEvents) InputEventsList {
    if (events.events.len == 0) return .{ .list = abi.RocListWith(InputEventRecord, false).empty(), .overflowed = events.overflowed };

    var buffer: [raylib.INPUT_EVENT_CAPACITY]InputEventRecord = undefined;
    for (events.events, buffer[0..events.events.len]) |record, *slot| {
        slot.* = .{ .kind = record.kind, .code = record.code, .x = record.x, .y = record.y };
    }
    return .{
        .list = abi.RocListWith(InputEventRecord, false).fromSlice(buffer[0..events.events.len], roc_host),
        .overflowed = events.overflowed,
    };
}

test "a quiet cycle delivers no events and reports no overflow" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    const sampled = inputEventsSnapshot(&roc_host, .{ .events = &.{}, .overflowed = false });
    defer sampled.list.deinit(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), sampled.list.len());
    try std.testing.expect(!sampled.overflowed);
}

test "events are copied out in order and the list is released with the input" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    const records = [_]raylib.InputEventRecord{
        .{ .kind = 0, .code = 65, .x = 0, .y = 0 },
        .{ .kind = 2, .code = 0, .x = 12.5, .y = 34 },
        .{ .kind = 5, .code = 0x20ac, .x = 0, .y = 0 },
    };
    const sampled = inputEventsSnapshot(&roc_host, .{ .events = &records, .overflowed = false });
    try std.testing.expectEqual(@as(usize, 3), sampled.list.len());
    const items = sampled.list.items();
    try std.testing.expectEqual(@as(u8, 0), items[0].kind);
    try std.testing.expectEqual(@as(u32, 65), items[0].code);
    try std.testing.expectEqual(@as(f32, 12.5), items[1].x);
    try std.testing.expectEqual(@as(f32, 34), items[1].y);
    try std.testing.expectEqual(@as(u32, 0x20ac), items[2].code);
    // The testing allocator is what checks the release: an unbalanced
    // refcount is a leak or a double free here, not a no-op.
    sampled.list.deinit(&roc_host);

    // Overflow travels with the interval that overflowed.
    const full = inputEventsSnapshot(&roc_host, .{ .events = &records, .overflowed = true });
    defer full.list.deinit(&roc_host);
    try std.testing.expect(full.overflowed);
    try std.testing.expectEqual(@as(usize, 3), full.list.len());
}

test "a scripted cycle's events reach the snapshot list in delivery order" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    var input = InputState.init(&roc_host);
    defer input.deinit();
    defer resetVirtualInput();

    // Tap Escape, then type "hi", then hold S from this cycle: the script
    // order is the delivery order.
    const options = RuntimeOptions{ .key_script = "3:ESCAPE~+S", .text_script = "3:hi" };
    applyInputScripts(options, 3);
    const scripted_text = takeVirtualText().?;
    input.updateHeadless(.virtual);
    const snapshot = input.hostState(0, 0, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 }, scripted_text);
    defer snapshot.decref(&roc_host);

    try std.testing.expect(!snapshot.events_overflow);
    try std.testing.expectEqual(@as(usize, 5), snapshot.events.len());
    const items = snapshot.events.items();
    try std.testing.expectEqual(@as(u8, 0), items[0].kind); // KeyPressed(Escape)
    try std.testing.expectEqual(@as(u32, 256), items[0].code);
    try std.testing.expectEqual(@as(u8, 1), items[1].kind); // KeyReleased(Escape)
    try std.testing.expectEqual(@as(u8, 5), items[2].kind); // Text('h')
    try std.testing.expectEqual(@as(u32, 'h'), items[2].code);
    try std.testing.expectEqual(@as(u32, 'i'), items[3].code);
    try std.testing.expectEqual(@as(u8, 0), items[4].kind); // KeyPressed(S): the held set changed
    try std.testing.expectEqual(@as(u32, 'S'), items[4].code);
    // And the bits agree with the list.
    try std.testing.expectEqual(ffi.INPUT_PRESSED | ffi.INPUT_RELEASED, input.keys.list.items()[256]);
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_PRESSED, input.keys.list.items()['S']);
}

/// One cycle's file drops on their way to `update!`.
///
/// `files` owns its strings; handing it to Roc transfers them, exactly as a
/// cycle's task results are transferred.
const DroppedFiles = struct {
    files: abi.RocList(DroppedFile),
    overflowed: bool,
};

/// Copy this cycle's dropped paths into Roc values, latching the pointer.
///
/// The window system owns the path strings and frees them the moment the drop
/// is released, so each one is copied into a `RocStr` here rather than
/// borrowed. Every file in one drop gets the same position: the pointer was in
/// one place when the drop landed, and that is the position the app is told
/// about.
///
/// What is counted is paths, not bytes: at most `raylib.DROPPED_FILES_CAPACITY`
/// of them cross in a cycle. Past that the extra paths are discarded and
/// `overflowed` is set, so an app that received half a drop can say so rather
/// than believing it got all of it.
fn droppedFilesSnapshot(
    roc_host: *RocHost,
    paths: []const [*:0]const u8,
    position: DroppedPosition,
) DroppedFiles {
    const capacity = raylib.DROPPED_FILES_CAPACITY;
    const overflowed = paths.len > capacity;
    const delivered = @min(paths.len, capacity);
    if (delivered == 0) return .{ .files = abi.RocList(DroppedFile).empty(), .overflowed = overflowed };

    var buffer: [raylib.DROPPED_FILES_CAPACITY]DroppedFile = undefined;
    for (paths[0..delivered], buffer[0..delivered]) |path, *slot| {
        slot.* = .{
            .path = abi.RocStr.fromSlice(std.mem.span(path), roc_host),
            .position = position,
        };
    }
    return .{
        .files = abi.RocList(DroppedFile).fromSlice(buffer[0..delivered], roc_host),
        .overflowed = overflowed,
    };
}

test "an ordinary cycle drops nothing and reports no overflow" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    const sampled = droppedFilesSnapshot(&roc_host, &.{}, .{ .x = 0, .y = 0 });
    defer sampled.files.deinit(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), sampled.files.len());
    try std.testing.expect(!sampled.overflowed);
}

test "dropped paths are copied out and the field clears on the next cycle" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    // The second path is long enough to be a heap RocStr rather than a small
    // one, so the copy is a real allocation the testing allocator checks.
    const long_path = "/home/example/pictures/a-rather-long-name-for-a-dropped-image.png";
    const paths = [_][*:0]const u8{ "/home/example/one.png", long_path };
    const sampled = droppedFilesSnapshot(&roc_host, &paths, .{ .x = 12.5, .y = 34 });
    try std.testing.expectEqual(@as(usize, 2), sampled.files.len());
    try std.testing.expect(!sampled.overflowed);
    const items = sampled.files.items();
    try std.testing.expectEqualStrings("/home/example/one.png", items[0].path.asSlice());
    try std.testing.expectEqualStrings(long_path, items[1].path.asSlice());
    try std.testing.expectEqual(@as(f32, 12.5), items[1].position.x);
    try std.testing.expectEqual(@as(f32, 34), items[1].position.y);
    sampled.files.deinit(&roc_host);

    // The list is built from this cycle's paths and nothing else, so the next
    // cycle clears it rather than repeating the drop `update!` already saw.
    const next = droppedFilesSnapshot(&roc_host, &.{}, .{ .x = 12.5, .y = 34 });
    defer next.files.deinit(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), next.files.len());
    try std.testing.expect(!next.overflowed);
}

test "a drop past the per-cycle cap is reported rather than silently truncated" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    var paths: [raylib.DROPPED_FILES_CAPACITY + 3][*:0]const u8 = undefined;
    for (&paths) |*slot| slot.* = "/home/example/drop.png";

    const sampled = droppedFilesSnapshot(&roc_host, &paths, .{ .x = 0, .y = 0 });
    defer sampled.files.deinit(&roc_host);
    try std.testing.expectEqual(raylib.DROPPED_FILES_CAPACITY, sampled.files.len());
    try std.testing.expect(sampled.overflowed);

    // Exactly at the cap is not an overflow: the app was given the whole drop.
    const exact = droppedFilesSnapshot(&roc_host, paths[0..raylib.DROPPED_FILES_CAPACITY], .{ .x = 0, .y = 0 });
    defer exact.files.deinit(&roc_host);
    try std.testing.expectEqual(raylib.DROPPED_FILES_CAPACITY, exact.files.len());
    try std.testing.expect(!exact.overflowed);
}

/// Sample the window for one cycle: logical drawing size, focus, minimization.
///
/// A headless run never opens a window, so every field is a fixed constant
/// rather than a raylib query -- `--host-headless` output has to be reproducible run
/// to run, and asking a window that does not exist would not be.
fn windowState() WindowSnapshot {
    // `headlessMode()`, not `active_headless`: unit tests reach this through
    // `Draw.Frame.size!`, and the test binary does not link raylib.
    if (headlessMode()) {
        return .{
            .size = .{ .width = headless_screen_width, .height = headless_screen_height },
            .focused = HEADLESS_WINDOW_FOCUSED,
            .minimized = HEADLESS_WINDOW_MINIMIZED,
        };
    }
    return .{
        .size = .{ .width = raylib.getScreenWidth(), .height = raylib.getScreenHeight() },
        .focused = raylib.isWindowFocused(),
        .minimized = raylib.isWindowMinimized(),
    };
}

fn printUsage() void {
    std.debug.print(
        \\usage: app [--host-headless] [--host-headless-frames=N] [--host-frames=N]
        \\           [--host-hidden] [--host-keys=SCRIPT] [--host-text=SCRIPT]
        \\           [--host-debug-allocator] [--host-stats-record]
        \\           [--host-stats-output=PATH]
        \\           [--host-stats-detail=summary|standard|full]
        \\           [--host-stats-buffer-mib=N] [--host-stats-max-mib=N]
        \\           [app arguments...]
        \\
        \\  --host-frames=N   exit after N cycles of a real windowed run
        \\  --host-hidden     open the real window hidden (needs a display server)
        \\  --host-keys=SCRIPT  hold keys on given cycles, e.g. "3:S,4:LEFT+X,10:32";
        \\                      a ~ suffix taps the key inside that cycle instead
        \\                      of holding it, e.g. "3:ESCAPE~"
        \\  --host-text=SCRIPT  deliver typed text on given cycles, e.g. "2:ab,3:c"
        \\  --host-stats-record  record host statistics to an .rrstats database
        \\  --host-stats-output=PATH  choose the recording path (also enables recording)
        \\  --host-stats-detail=LEVEL  summary, standard (default), or full
        \\  --host-stats-buffer-mib=N  bounded recorder memory (default 32 MiB)
        \\  --host-stats-max-mib=N  maximum recording size (default 4096 MiB)
        \\
    , .{});
}

const DEFAULT_STATS_BUFFER_MIB: u64 = 32;
const DEFAULT_STATS_MAX_MIB: u64 = 4096;
/// Keep launch configuration from reserving an operator-sized address space by
/// mistake. The recorder will allocate this pool in full before `init!`.
const MAX_STATS_BUFFER_MIB: u64 = 4096;

fn parsePositiveMib(flag: []const u8, value: []const u8, maximum: ?u64) !u64 {
    const mib = std.fmt.parseUnsigned(u64, value, 10) catch {
        std.debug.print("invalid {s} value: {s}\n", .{ flag, value });
        return error.InvalidArgument;
    };
    if (mib == 0 or (maximum != null and mib > maximum.?)) {
        if (maximum) |limit| {
            std.debug.print("{s} must be between 1 and {d}\n", .{ flag, limit });
        } else {
            std.debug.print("{s} must be greater than zero\n", .{flag});
        }
        return error.InvalidArgument;
    }
    _ = std.math.mul(u64, mib, 1024 * 1024) catch {
        std.debug.print("{s} is too large\n", .{flag});
        return error.InvalidArgument;
    };
    return mib;
}

/// The most keys one scripted cycle may hold down at once.
const KEY_SCRIPT_CAPACITY = 8;

const ScriptError = error{InvalidScript};

/// Decode one `--host-keys` token into a raylib key code.
///
/// A single printable character stands for the key that types it in the
/// ASCII-aligned part of raylib's keymap (`S`, `7`, ` `), a decimal number is a
/// raw key code, and a bare name covers the few keys with no character
/// (`LEFT`, `RIGHT`, `UP`, `DOWN`, `SPACE`, `ENTER`, `ESCAPE`, `TAB`).
fn parseScriptedKey(token: []const u8) ScriptError!u64 {
    if (token.len == 0) return error.InvalidScript;
    if (token.len == 1) {
        const c = std.ascii.toUpper(token[0]);
        if (c < 32 or c > 126) return error.InvalidScript;
        return c;
    }
    const named = .{
        .{ "SPACE", 32 },
        .{ "ENTER", 257 },
        .{ "TAB", 258 },
        .{ "ESCAPE", 256 },
        .{ "BACKSPACE", 259 },
        .{ "RIGHT", 262 },
        .{ "LEFT", 263 },
        .{ "DOWN", 264 },
        .{ "UP", 265 },
    };
    inline for (named) |entry| {
        if (std.ascii.eqlIgnoreCase(token, entry[0])) return entry[1];
    }
    return std.fmt.parseUnsigned(u64, token, 10) catch error.InvalidScript;
}

/// The segment of a script that applies to `cycle`, or null when none does.
///
/// A script is `cycle:payload` segments separated by commas. Only the cycles a
/// script names are scripted; every other cycle is handed back to hardware, so
/// a held-then-released key is expressible.
fn scriptSegment(spec: []const u8, cycle: u64) ScriptError!?[]const u8 {
    var segments = std.mem.splitScalar(u8, spec, ',');
    var found: ?[]const u8 = null;
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.InvalidScript;
        const colon = std.mem.indexOfScalar(u8, segment, ':') orelse return error.InvalidScript;
        const at = std.fmt.parseUnsigned(u64, segment[0..colon], 10) catch return error.InvalidScript;
        const payload = segment[colon + 1 ..];
        if (payload.len == 0) return error.InvalidScript;
        if (at == cycle) found = payload;
    }
    return found;
}

/// What a `--host-keys` script does on one cycle.
///
/// `held` keys are down for the whole cycle: pressed on the first cycle that
/// names them, released on the first that does not. `taps` are pressed and
/// released inside the cycle, so the input sees both edges and no hold -- the
/// hardware case of a key that went down and up between two polls, which is
/// what a level-per-cycle script could never express.
const ScriptedKeys = struct {
    held: []const u64,
    taps: []const u64,
};

/// Scratch for one cycle of a key script.
const ScriptedKeyBuffers = struct {
    held: [KEY_SCRIPT_CAPACITY]u64 = undefined,
    taps: [KEY_SCRIPT_CAPACITY]u64 = undefined,
};

/// The suffix that turns a held key into a tap: `S~`.
///
/// Chosen for being inert unquoted in every shell the sweep runs under: cmd
/// does nothing with a `~`, PowerShell expands one only as a whole token, and
/// bash and zsh tilde-expand only a word that starts with it. `^` was the
/// first choice and is cmd's escape character, so `3:A^+B^` reached the host
/// as `3:A+B` on Windows -- a held pair instead of two taps -- silently.
const TAP_SUFFIX = '~';

/// The keys a `--host-keys` script holds and taps on `cycle`, or null when it
/// scripts nothing there.
fn scriptedKeysAtCycle(spec: []const u8, cycle: u64, out: *ScriptedKeyBuffers) ScriptError!?ScriptedKeys {
    const payload = (try scriptSegment(spec, cycle)) orelse return null;
    var tokens = std.mem.splitScalar(u8, payload, '+');
    var held: usize = 0;
    var taps: usize = 0;
    while (tokens.next()) |token| {
        // A bare suffix taps nothing; it is a typo, not a key.
        if (token.len == 1 and token[0] == TAP_SUFFIX) return error.InvalidScript;
        if (token.len > 1 and token[token.len - 1] == TAP_SUFFIX) {
            if (taps == out.taps.len) return error.InvalidScript;
            out.taps[taps] = try parseScriptedKey(token[0 .. token.len - 1]);
            taps += 1;
        } else {
            if (held == out.held.len) return error.InvalidScript;
            out.held[held] = try parseScriptedKey(token);
            held += 1;
        }
    }
    return .{ .held = out.held[0..held], .taps = out.taps[0..taps] };
}

/// Validate a whole script without running it, so a typo fails at startup
/// rather than silently scripting nothing.
fn validateScript(spec: []const u8, keys: bool) ScriptError!void {
    var segments = std.mem.splitScalar(u8, spec, ',');
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.InvalidScript;
        const colon = std.mem.indexOfScalar(u8, segment, ':') orelse return error.InvalidScript;
        const at = std.fmt.parseUnsigned(u64, segment[0..colon], 10) catch return error.InvalidScript;
        if (segment[colon + 1 ..].len == 0) return error.InvalidScript;
        if (keys) {
            var scratch = ScriptedKeyBuffers{};
            _ = try scriptedKeysAtCycle(spec, at, &scratch);
        }
    }
}

/// Apply this cycle's scripted keyboard and typed text, if any are scripted.
///
/// Called immediately before the cycle samples input, so a scripted key goes
/// through exactly the same derivation as a hardware one: held keys as the
/// level, taps as edges recorded inside the interval.
fn applyInputScripts(options: RuntimeOptions, cycle: u64) void {
    if (options.key_script) |spec| {
        var buffers = ScriptedKeyBuffers{};
        const scripted = scriptedKeysAtCycle(spec, cycle, &buffers) catch null;
        if (scripted) |keys| {
            applyVirtualKeys(true, keys.held);
            for (keys.taps) |code| {
                raylib.recordVirtualKeyEdge(code, .press);
                raylib.recordVirtualKeyEdge(code, .release);
            }
        } else {
            applyVirtualKeys(false, &.{});
        }
    }
    if (options.text_script) |spec| {
        const typed = scriptSegment(spec, cycle) catch null;
        if (typed) |text| {
            var codepoints: [raylib.TEXT_INPUT_CAPACITY]u32 = undefined;
            const kept = @min(text.len, codepoints.len);
            for (text[0..kept], 0..) |byte, i| codepoints[i] = byte;
            applyVirtualText(codepoints[0..kept]);
        }
    }
}

test "a key script holds only the cycles it names" {
    var buffers = ScriptedKeyBuffers{};
    const spec = "3:S,4:LEFT+x,10:32";

    try std.testing.expect((try scriptedKeysAtCycle(spec, 0, &buffers)) == null);
    try std.testing.expectEqualSlices(u64, &.{'S'}, (try scriptedKeysAtCycle(spec, 3, &buffers)).?.held);
    try std.testing.expectEqualSlices(u64, &.{ 263, 'X' }, (try scriptedKeysAtCycle(spec, 4, &buffers)).?.held);
    try std.testing.expectEqualSlices(u64, &.{32}, (try scriptedKeysAtCycle(spec, 10, &buffers)).?.held);
    try std.testing.expect((try scriptedKeysAtCycle(spec, 5, &buffers)) == null);
    for (0..11) |cycle| {
        if (try scriptedKeysAtCycle(spec, cycle, &buffers)) |keys| {
            try std.testing.expectEqual(@as(usize, 0), keys.taps.len);
        }
    }
}

test "a ~ suffix scripts a tap rather than a hold" {
    var buffers = ScriptedKeyBuffers{};
    const spec = "3:ESCAPE~,4:S~+a+SPACE~";

    const escape = (try scriptedKeysAtCycle(spec, 3, &buffers)).?;
    try std.testing.expectEqual(@as(usize, 0), escape.held.len);
    try std.testing.expectEqualSlices(u64, &.{256}, escape.taps);

    const mixed = (try scriptedKeysAtCycle(spec, 4, &buffers)).?;
    try std.testing.expectEqualSlices(u64, &.{'A'}, mixed.held);
    try std.testing.expectEqualSlices(u64, &.{ 'S', 32 }, mixed.taps);

    // A bare ~ is a tap of nothing, which is a typo rather than a key.
    try std.testing.expectError(error.InvalidScript, scriptedKeysAtCycle("1:~", 1, &buffers));
    try std.testing.expectError(error.InvalidScript, validateScript("1:S+~", true));
    try validateScript(spec, true);
}

test "a malformed script is rejected rather than scripting nothing" {
    var buffers = ScriptedKeyBuffers{};
    try std.testing.expectError(error.InvalidScript, scriptedKeysAtCycle("3", 3, &buffers));
    try std.testing.expectError(error.InvalidScript, scriptedKeysAtCycle("3:", 3, &buffers));
    try std.testing.expectError(error.InvalidScript, scriptedKeysAtCycle("x:S", 3, &buffers));
    try std.testing.expectError(error.InvalidScript, scriptedKeysAtCycle("3:NOPE", 3, &buffers));
    try std.testing.expectError(error.InvalidScript, scriptedKeysAtCycle("3:NOPE~", 3, &buffers));
    try std.testing.expectError(error.InvalidScript, validateScript("3:S,", true));
    try validateScript("1:ab,2:c", false);
}

test "a scripted tap lands inside one cycle as a press and a release" {
    defer resetVirtualInput();
    const escape = 256;
    const options = RuntimeOptions{ .key_script = "2:S,3:ESCAPE~,4:S" };

    // Cycle 1 is not scripted: hardware, with nothing recorded.
    applyInputScripts(options, 1);
    try std.testing.expect(!virtual_keys_active);

    // Cycle 2 holds S, which is a press on the level.
    applyInputScripts(options, 2);
    raylib.updateKeyboardStateFrom(&virtual_key_down);
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_PRESSED, raylib.getKeyState()['S']);

    // Cycle 3 taps Escape: both edges, never held, and S is released by the
    // level in the same cycle. That is what an app quitting on
    // `key_pressed(KeyEscape)` sees when the key went down and up between two
    // polls.
    applyInputScripts(options, 3);
    try std.testing.expect(virtual_keys_active);
    raylib.updateKeyboardStateFrom(&virtual_key_down);
    try std.testing.expectEqual(ffi.INPUT_PRESSED | ffi.INPUT_RELEASED, raylib.getKeyState()[escape]);
    try std.testing.expectEqual(ffi.INPUT_RELEASED, raylib.getKeyState()['S']);

    // The tap was consumed with its cycle.
    applyInputScripts(options, 4);
    raylib.updateKeyboardStateFrom(&virtual_key_down);
    try std.testing.expectEqual(@as(u8, 0), raylib.getKeyState()[escape]);
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_PRESSED, raylib.getKeyState()['S']);
}

fn parseRuntimeOptions(allocator: std.mem.Allocator, argc: usize, argv: [*][*:0]u8) !RuntimeOptions {
    var options = RuntimeOptions{};
    const app_args = try allocator.alloc([*:0]u8, argc);
    errdefer allocator.free(app_args);

    var app_arg_count: usize = 0;
    if (argc > 0) {
        app_args[app_arg_count] = argv[0];
        app_arg_count += 1;
    }

    var i: usize = 1;
    while (i < argc) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--host-headless")) {
            options.headless = true;
        } else if (std.mem.startsWith(u8, arg, "--host-headless-frames=")) {
            options.headless = true;
            const value = arg["--host-headless-frames=".len..];
            const frames = std.fmt.parseUnsigned(u64, value, 10) catch {
                std.debug.print("invalid --host-headless-frames value: {s}\n", .{value});
                return error.InvalidArgument;
            };
            if (frames == 0) {
                std.debug.print("--host-headless-frames must be greater than zero\n", .{});
                return error.InvalidArgument;
            }
            options.headless_frames = frames;
        } else if (std.mem.startsWith(u8, arg, "--host-frames=")) {
            const value = arg["--host-frames=".len..];
            const frames = std.fmt.parseUnsigned(u64, value, 10) catch {
                std.debug.print("invalid --host-frames value: {s}\n", .{value});
                return error.InvalidArgument;
            };
            if (frames == 0) {
                std.debug.print("--host-frames must be greater than zero\n", .{});
                return error.InvalidArgument;
            }
            options.frames = frames;
        } else if (std.mem.eql(u8, arg, "--host-hidden")) {
            options.hidden = true;
        } else if (std.mem.startsWith(u8, arg, "--host-keys=")) {
            const value = arg["--host-keys=".len..];
            validateScript(value, true) catch {
                std.debug.print("invalid --host-keys script: {s}\n", .{value});
                return error.InvalidArgument;
            };
            options.key_script = value;
        } else if (std.mem.startsWith(u8, arg, "--host-text=")) {
            const value = arg["--host-text=".len..];
            validateScript(value, false) catch {
                std.debug.print("invalid --host-text script: {s}\n", .{value});
                return error.InvalidArgument;
            };
            options.text_script = value;
        } else if (std.mem.eql(u8, arg, "--host-debug-allocator")) {
            options.debug_allocator = true;
        } else if (std.mem.eql(u8, arg, "--host-stats-record")) {
            options.record_stats = true;
        } else if (std.mem.startsWith(u8, arg, "--host-stats-output=")) {
            const value = arg["--host-stats-output=".len..];
            if (value.len == 0) {
                std.debug.print("--host-stats-output requires a path\n", .{});
                return error.InvalidArgument;
            }
            options.stats_output = value;
            options.record_stats = true;
        } else if (std.mem.startsWith(u8, arg, "--host-stats-detail=")) {
            const value = arg["--host-stats-detail=".len..];
            options.stats_detail = if (std.mem.eql(u8, value, "summary"))
                .summary
            else if (std.mem.eql(u8, value, "standard"))
                .standard
            else if (std.mem.eql(u8, value, "full"))
                .full
            else {
                std.debug.print("invalid --host-stats-detail value: {s}\n", .{value});
                return error.InvalidArgument;
            };
        } else if (std.mem.startsWith(u8, arg, "--host-stats-buffer-mib=")) {
            options.stats_buffer_mib = try parsePositiveMib(
                "--host-stats-buffer-mib",
                arg["--host-stats-buffer-mib=".len..],
                MAX_STATS_BUFFER_MIB,
            );
        } else if (std.mem.startsWith(u8, arg, "--host-stats-max-mib=")) {
            options.stats_max_mib = try parsePositiveMib(
                "--host-stats-max-mib",
                arg["--host-stats-max-mib=".len..],
                null,
            );
        } else if (std.mem.eql(u8, arg, "--host-help")) {
            options.help = true;
        } else if (std.mem.startsWith(u8, arg, "--host-")) {
            std.debug.print("unknown host argument: {s}\n", .{arg});
            return error.InvalidArgument;
        } else {
            app_args[app_arg_count] = argv[i];
            app_arg_count += 1;
        }
    }
    options.app_args = app_args[0..app_arg_count];
    options.app_args_allocation = app_args;
    return options;
}

test "runtime options reserve host switches and preserve complete app argv" {
    var argv = [_][*:0]u8{
        @constCast("breakout"),
        @constCast("--record-demo"),
        @constCast("--host-headless"),
        @constCast("--host-headless-frames=7"),
        @constCast("--headless"),
    };
    const options = try parseRuntimeOptions(std.testing.allocator, argv.len, &argv);
    defer options.deinit(std.testing.allocator);

    try std.testing.expect(options.headless);
    try std.testing.expectEqual(@as(u64, 7), options.headless_frames);
    try std.testing.expectEqual(@as(usize, 3), options.app_args.len);
    try std.testing.expectEqualStrings("breakout", std.mem.span(options.app_args[0]));
    try std.testing.expectEqualStrings("--record-demo", std.mem.span(options.app_args[1]));
    try std.testing.expectEqualStrings("--headless", std.mem.span(options.app_args[2]));
}

test "runtime options carry the windowed sweep switches" {
    var argv = [_][*:0]u8{
        @constCast("pong"),
        @constCast("--host-frames=30"),
        @constCast("--host-hidden"),
        @constCast("--host-keys=3:S"),
        @constCast("--host-text=4:ab"),
    };
    const options = try parseRuntimeOptions(std.testing.allocator, argv.len, &argv);
    defer options.deinit(std.testing.allocator);

    try std.testing.expect(!options.headless);
    try std.testing.expectEqual(@as(?u64, 30), options.frames);
    try std.testing.expect(options.hidden);
    try std.testing.expectEqualStrings("3:S", options.key_script.?);
    try std.testing.expectEqualStrings("4:ab", options.text_script.?);
    try std.testing.expectEqual(@as(usize, 1), options.app_args.len);
}

test "runtime options parse Observatory flags and defaults" {
    var defaults_argv = [_][*:0]u8{ @constCast("app"), @constCast("--host-stats-record") };
    const defaults = try parseRuntimeOptions(std.testing.allocator, defaults_argv.len, &defaults_argv);
    defer defaults.deinit(std.testing.allocator);
    try std.testing.expect(defaults.record_stats);
    try std.testing.expect(defaults.stats_output == null);
    try std.testing.expectEqual(RuntimeOptions.StatsDetail.standard, defaults.stats_detail);
    try std.testing.expectEqual(DEFAULT_STATS_BUFFER_MIB, defaults.stats_buffer_mib);
    try std.testing.expectEqual(DEFAULT_STATS_MAX_MIB, defaults.stats_max_mib);

    var argv = [_][*:0]u8{
        @constCast("app"),
        @constCast("--host-stats-output=captures/run.rrstats"),
        @constCast("--host-stats-detail=full"),
        @constCast("--host-stats-buffer-mib=64"),
        @constCast("--host-stats-max-mib=512"),
        @constCast("app-argument"),
    };
    const options = try parseRuntimeOptions(std.testing.allocator, argv.len, &argv);
    defer options.deinit(std.testing.allocator);
    try std.testing.expect(options.record_stats);
    try std.testing.expectEqualStrings("captures/run.rrstats", options.stats_output.?);
    try std.testing.expectEqual(RuntimeOptions.StatsDetail.full, options.stats_detail);
    try std.testing.expectEqual(@as(u64, 64), options.stats_buffer_mib);
    try std.testing.expectEqual(@as(u64, 512), options.stats_max_mib);
    try std.testing.expectEqual(@as(usize, 2), options.app_args.len);
    try std.testing.expectEqualStrings("app-argument", std.mem.span(options.app_args[1]));
}

test "runtime options reject invalid Observatory configuration" {
    inline for (.{
        "--host-stats-output=",
        "--host-stats-detail=verbose",
        "--host-stats-buffer-mib=0",
        "--host-stats-buffer-mib=4097",
        "--host-stats-max-mib=0",
        "--host-stats-max-mib=nope",
    }) |bad_arg| {
        var argv = [_][*:0]u8{ @constCast("app"), @constCast(bad_arg) };
        try std.testing.expectError(error.InvalidArgument, parseRuntimeOptions(std.testing.allocator, argv.len, &argv));
    }
}

test "runtime options reject malformed reserved host switches" {
    var argv = [_][*:0]u8{ @constCast("app"), @constCast("--host-unknown") };
    try std.testing.expectError(error.InvalidArgument, parseRuntimeOptions(std.testing.allocator, argv.len, &argv));

    var zero_windowed = [_][*:0]u8{ @constCast("app"), @constCast("--host-frames=0") };
    try std.testing.expectError(error.InvalidArgument, parseRuntimeOptions(std.testing.allocator, zero_windowed.len, &zero_windowed));

    var bad_keys = [_][*:0]u8{ @constCast("app"), @constCast("--host-keys=3") };
    try std.testing.expectError(error.InvalidArgument, parseRuntimeOptions(std.testing.allocator, bad_keys.len, &bad_keys));

    var zero_frames = [_][*:0]u8{ @constCast("app"), @constCast("--host-headless-frames=0") };
    try std.testing.expectError(error.InvalidArgument, parseRuntimeOptions(std.testing.allocator, zero_frames.len, &zero_frames));
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
/// result installs a new owned model reference. `update` runs once per frame,
/// so this applies once per call rather than once per frame.
fn takeModel(boxed_model: *RocBox) RocBox {
    const transferred = boxed_model.*;
    boxed_model.* = null;
    return transferred;
}

/// Render-specific name for the model ownership-transfer helper.
const takeModelForRender = takeModel;

/// Callback cardinality for one fresh input.
///
/// Every host cycle transitions exactly once. Presentation is an independent
/// backend scheduling choice and is therefore either omitted or invoked once.
const CycleCallbackSchedule = struct {
    updates: u8 = 1,
    presentations: u8,

    fn forInput(presentation_scheduled: bool) CycleCallbackSchedule {
        return .{ .presentations = if (presentation_scheduled) 1 else 0 };
    }
};

/// Advance the model once for one fresh input.
///
/// Presentation is scheduled independently afterward, so an omitted frame
/// never causes the host to repeat or skip this transition.
fn updateOnce(boxed_model: *RocBox, input: InputFromHost) UpdateResult {
    // `update!` calls host effects directly, and spawns tasks through the
    // `Task.spawn!` effect, all inside this scope.
    const phase = PhaseScope.enter(.update);
    defer phase.leave();
    // Off unless ROC_RAY_ALLOC_STATS asked for metering; one branch per frame.
    const metered = allocMeterMark();
    defer allocMeterRecordUpdate(metered);
    return update_for_host(takeModel(boxed_model), input);
}

/// Apply the startup capture configuration once the window exists.
///
/// A recording declared in `App.Config` goes through the same validation as
/// `Capture.start!`, so a bad path or an over-budget request is reported the
/// same way rather than being trusted because it came from config.
fn configureCapture(app_config: AppConfig) void {
    capture_session.reset();
    resetVirtualInput();

    capture_screenshot_pending = false;
    // The snapshot is freed before the budget is zeroed: a reset that only
    // forgot the reservation would leave the buffer behind for the next app
    // lifetime to read as if it were its own frame.
    releaseScreenSnapshot();
    screen_snapshot_requested = false;
    still_budget.reset();
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
    if (capture_session.status == capture.status_idle or
        capture_session.status == capture.status_finished)
    {
        // A recording stopped through `Capture.stop` has already closed its
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

    // A frame that no `Screen` readback asked about drops the snapshot: the
    // per-frame readback exists only while an app is still reading pixels.
    const wants_snapshot = screen_snapshot_requested;
    screen_snapshot_requested = false;
    if (!wants_snapshot) releaseScreenSnapshot();

    if (!wants_screenshot and !wants_frame and !wants_snapshot) return;

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
    if (wants_frame and !wants_screenshot and !wants_snapshot) {
        if (captureScaledFrame()) |scaled| {
            var frame = scaled;
            defer frame.deinit();
            writeRecordingFrame(frame);
            finishRecordingAtFrameCap();
            return;
        }
    }

    var image = raylib.captureFramebuffer() orelse {
        // A snapshot that could not be taken must not leave the previous
        // frame's pixels behind for the app to read as if they were this one's.
        if (wants_snapshot) releaseScreenSnapshot();
        if (wants_frame) capture_session.fail(capture.err_out_of_memory);
        if (wants_screenshot) {
            if (screenshot_wait) |wait| {
                wait.err = capture.err_out_of_memory;
                wait.ready.set();
            }
        }
        return;
    };
    defer image.deinit();

    if (wants_snapshot) storeScreenSnapshot(image);

    if (wants_screenshot) {
        if (screenshot_wait) |wait| handOverScreenshot(wait, image);
    }

    if (!wants_frame) return;

    if (capture_session.width != image.width() or capture_session.height != image.height()) {
        image.resize(capture_session.width, capture_session.height);
    }

    writeRecordingFrame(image);
    finishRecordingAtFrameCap();
}

/// Copy the readback out for the task parked on `Capture.screenshot!`.
///
/// The pixels are copied rather than moved because the readback buffer belongs
/// to the graphics backend, which frees it on this thread as soon as the
/// drawing scope closes. A memcpy is the price of the encode happening
/// somewhere other than the frame thread.
fn handOverScreenshot(wait: *ScreenshotWait, image: raylib.CaptureImage) void {
    const source = image.pixels();
    const pixels = allocatorFromHost(activeHost()).alloc(u8, source.len) catch {
        wait.err = capture.err_out_of_memory;
        wait.ready.set();
        return;
    };
    @memcpy(pixels, source);
    wait.pixels = pixels;
    wait.width = image.width();
    wait.height = image.height();
    wait.ready.set();
}

/// Hand one captured frame, already at the recording's size, to its sink.
///
/// Recording frames still encode on this thread. Unlike a screenshot they are
/// part of a metered stream with its own dropped-frame accounting, and ordering
/// between frames is load-bearing for the GIF and WebM sinks.
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
/// How many retired resources may be destroyed at the end of one frame.
///
/// Each destruction is a driver or audio-device call, so a model that dropped
/// two hundred textures in one transition would otherwise stall the frame it
/// happened to be dropped in. Sixteen is comfortably more than an app churns
/// per frame in steady state, and the rest simply waits for the next one.
const MAX_RESOURCE_RETIREMENTS_PER_FRAME: usize = 16;

/// Destroy resources whose last Roc reference has gone, up to a budget.
///
/// Called at frame end so pure `update` only retires references; GPU and audio
/// destruction remains in the effectful host loop.
fn drainRetiredResources() void {
    drainRetiredResourcesUpTo(MAX_RESOURCE_RETIREMENTS_PER_FRAME);
}

/// Destroy up to `limit` retired resources across every heap.
fn drainRetiredResourcesUpTo(limit: usize) void {
    var budget = limit;
    budget -= udp_socket_heap.drainRetired(budget);
    // Statements before connections: a connection whose statements are gone
    // closes outright instead of becoming a zombie that lingers a frame.
    budget -= sqlite_effect.stmt_heap.drainRetired(budget);
    // One connection per drain. Closing may checkpoint a WAL file, which is
    // real disk work, and this runs on the frame thread; `Sqlite.Db.close!` is
    // how an app pays a large one on a task instead.
    budget -= sqlite_effect.db_heap.drainRetired(@min(budget, 1));
    budget -= store_heap.drainRetired(budget);
    budget -= file_bytes_heap.drainRetired(budget);
    budget -= prepared_text_heap.drainRetired(budget);
    budget -= shader_heap.drainRetired(budget);
    budget -= render_texture_heap.drainRetired(budget);
    budget -= texture_heap.drainRetired(budget);
    budget -= font_heap.drainRetired(budget);
    budget -= music_heap.drainRetired(budget);
    budget -= sound_heap.drainRetired(budget);
}

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

/// Call `render!` in the render phase.
///
/// Narrower than the drawing scope on purpose: capture services its requests
/// after `render!` returns and draws its own cursor overlay directly through
/// raylib, which is host business and not an app draw call.
fn callRender(boxed_model: RocBox) RocResult {
    const phase = PhaseScope.enter(.render);
    defer phase.leave();
    return render_for_host(boxed_model);
}

const BackendFrameTiming = struct {
    render_callback_started_ns: i96 = 0,
    render_callback_ns: u64 = 0,
    begin_drawing_ns: u64 = 0,
    host_submission_ns: u64 = 0,
    end_drawing_ns: u64 = 0,
};

var observatory_backend_timing: BackendFrameTiming = .{};

/// Run one Roc render call inside the host-owned raylib frame scope.
/// `defer` closes the frame for both `Ok` and `Err` results.
fn renderFrame(boxed_model: RocBox) RocResult {
    observatory_backend_timing = .{};
    if (active_headless) {
        const callback_start = observatoryMeasurementStart();
        observatory_backend_timing.render_callback_started_ns = callback_start;
        const result = callRender(boxed_model);
        observatory_backend_timing.render_callback_ns = observatoryMeasurementElapsed(callback_start);
        return result;
    }

    var started = observatoryMeasurementStart();
    raylib.beginDrawing();
    observatory_backend_timing.begin_drawing_ns = observatoryMeasurementElapsed(started);
    started = observatoryMeasurementStart();
    observatory_backend_timing.render_callback_started_ns = started;
    const result = callRender(boxed_model);
    observatory_backend_timing.render_callback_ns = observatoryMeasurementElapsed(started);
    started = observatoryMeasurementStart();
    serviceCaptureRequests();
    observatory_backend_timing.host_submission_ns = observatoryMeasurementElapsed(started);
    started = observatoryMeasurementStart();
    // raylib's EndDrawing performs submission, buffer swap, and any configured
    // frame wait as one opaque call. Timing it is honest; splitting it into
    // presentation and pacing would not be.
    raylib.endDrawing();
    observatory_backend_timing.end_drawing_ns = observatoryMeasurementElapsed(started);
    return result;
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

test "a virtual held key is pressed once and then merely down" {
    // raylib's KEY_SPACE. The packed state list is indexed by key code, so
    // this is both the code the app scripts and the slot it lands in.
    const space = 32;
    defer resetVirtualInput();

    applyVirtualKeys(true, &.{space});
    raylib.updateKeyboardStateFrom(&virtual_key_down);
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_PRESSED, raylib.getKeyState()[space]);

    // Held across a second frame: still down, but no longer a press. An app
    // acting on `key_pressed` must act exactly once.
    raylib.updateKeyboardStateFrom(&virtual_key_down);
    try std.testing.expectEqual(ffi.INPUT_HELD, raylib.getKeyState()[space]);

    applyVirtualKeys(true, &.{});
    raylib.updateKeyboardStateFrom(&virtual_key_down);
    try std.testing.expectEqual(ffi.INPUT_RELEASED, raylib.getKeyState()[space]);

    raylib.updateKeyboardStateFrom(&virtual_key_down);
    try std.testing.expectEqual(@as(u8, 0), raylib.getKeyState()[space]);
}

test "releasing the virtual keyboard drops every held key" {
    defer resetVirtualInput();

    applyVirtualKeys(true, &.{ 32, 65 });
    try std.testing.expect(virtual_keys_active);
    try std.testing.expect(virtual_key_down[32]);
    try std.testing.expect(virtual_key_down[65]);

    applyVirtualKeys(false, &.{});
    try std.testing.expect(!virtual_keys_active);
    try std.testing.expect(!virtual_key_down[32]);
    try std.testing.expect(!virtual_key_down[65]);
}

test "a key code past the packed state list is dropped rather than written" {
    defer resetVirtualInput();

    applyVirtualKeys(true, &.{ffi.KEY_COUNT + 10});
    for (virtual_key_down) |down| try std.testing.expect(!down);
}

test "scripted text is delivered once and its overflow is reported" {
    defer resetVirtualInput();

    applyVirtualText(&.{ 'h', 'i' });
    const short = takeVirtualText().?;
    try std.testing.expectEqualSlices(u32, &.{ 'h', 'i' }, short.codepoints);
    try std.testing.expect(!short.overflowed);
    // Gone on the next frame: real characters arrive once, not every frame
    // until something else is typed.
    try std.testing.expect(takeVirtualText() == null);

    var long: [raylib.TEXT_INPUT_CAPACITY + 4]u32 = @splat('x');
    long[0] = 'a';
    applyVirtualText(&long);
    const delivered = takeVirtualText().?;
    try std.testing.expectEqual(raylib.TEXT_INPUT_CAPACITY, delivered.codepoints.len);
    try std.testing.expectEqual(@as(u32, 'a'), delivered.codepoints[0]);
    try std.testing.expect(delivered.overflowed);

    // Exactly the capacity is not an overflow: everything typed arrived.
    applyVirtualText(long[0..raylib.TEXT_INPUT_CAPACITY]);
    try std.testing.expect(!takeVirtualText().?.overflowed);
}

test "taking a model for render clears the host-owned reference" {
    const model: *anyopaque = @ptrFromInt(@alignOf(usize));
    var boxed_model: RocBox = model;

    try std.testing.expectEqual(model, takeModelForRender(&boxed_model));
    try std.testing.expectEqual(null, boxed_model);
}

test "each update call takes the model afresh so one reference stays live" {
    // Every update call consumes its Box, so the host must take the model
    // afresh each time; reusing the slot would hand out a stale reference.
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

var test_callback_drops: usize = 0;

fn testCallbackCall(
    roc_host: *RocHost,
    callback_capture: ?[*]u8,
    arg: ?[*]const u8,
    result: ?[*]u8,
    reuse: ?[*]u8,
    context: *?*const anyopaque,
) callconv(.c) void {
    _ = roc_host;
    _ = callback_capture;
    _ = arg;
    _ = result;
    _ = reuse;
    context.* = null;
    unreachable;
}

fn testCallbackDrop(callback_capture: ?[*]u8, roc_host: *RocHost) callconv(.c) void {
    _ = callback_capture;
    _ = roc_host;
    test_callback_drops += 1;
}

fn testCallback(roc_host: *RocHost) abi.RocErasedCallable {
    return abi.rocErasedCallableAllocate(roc_host, &testCallbackCall, &testCallbackDrop, 0);
}

test "finished task messages become one Roc list, and an idle input allocates none" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    var idle = TaskResultStaging{};
    const empty = idle.take(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), empty.items().len);
    empty.decref(&roc_host);
    idle.release(&roc_host);

    var staging = TaskResultStaging{};
    staging.append(&roc_host, testCallback(&roc_host));
    staging.append(&roc_host, testCallback(&roc_host));
    try std.testing.expectEqual(@as(usize, 2), staging.count());

    // The list belongs to Roc after this, so the staging area must not free the
    // same thunks a second time -- and anything staged afterwards is a message
    // for the *next* input, not this one.
    const list = staging.take(&roc_host);
    try std.testing.expectEqual(@as(usize, 2), list.items().len);
    try std.testing.expectEqual(@as(usize, 0), staging.count());

    // Stands in for Roc consuming the input.
    test_callback_drops = 0;
    for (list.allocationItems()) |item| item.decref(&roc_host);
    list.decref(&roc_host);
    try std.testing.expectEqual(@as(usize, 2), test_callback_drops);

    staging.append(&roc_host, testCallback(&roc_host));
    try std.testing.expectEqual(@as(usize, 1), staging.count());
    staging.release(&roc_host);
}

test "task message staging pressure uses scalar occupancy and no platform cap" {
    const previous_cycle = observatory_cycle;
    defer observatory_cycle = previous_cycle;
    observatory_cycle = 19;
    const reserved = taskStagingQueueEvent(.reserve, 1, 4, 7, 100, 145);
    try std.testing.expectEqual(@as(u64, 19), reserved.cycle);
    try std.testing.expectEqual(@as(u8, 0), reserved.kind);
    try std.testing.expectEqual(@as(u64, 7), reserved.subject_id);
    try std.testing.expectEqual(@as(u64, 0), reserved.parent_id);
    try std.testing.expectEqual(@as(u64, 45), reserved.duration_ns);
    try std.testing.expectEqual(@as(u64, 4), reserved.value_a);
    try std.testing.expectEqual(@as(u64, 1), reserved.value_b);
    try std.testing.expectEqualStrings("task staged messages", reserved.name);

    const released = taskStagingQueueEvent(.release, 4, 0, 7, 100, 160);
    try std.testing.expectEqual(@as(u8, 1), released.kind);
    try std.testing.expectEqual(@as(u64, 4), released.value_b);
    try std.testing.expectEqual(@as(u64, 60), released.duration_ns);
}

test "a task message staged but never delivered is released at shutdown" {
    // The app exited on the frame a task finished on. Nothing carried the
    // message to Roc, so staging owns the only reference and has to drop it.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    var staging = TaskResultStaging{};
    staging.append(&roc_host, testCallback(&roc_host));
    test_callback_drops = 0;
    staging.release(&roc_host);
    try std.testing.expectEqual(@as(usize, 1), test_callback_drops);
    try std.testing.expectEqual(@as(usize, 0), staging.count());
}

/// A task body for the pump tests: an ordinary Zig thunk where the app would
/// have a Roc closure.
///
/// The pointer travels as the erased callable and comes back out of
/// `takeFinished` as the result, so these tests measure the scheduling and
/// nothing else -- no interpreter, no Roc values, no refcounts.
const TestTaskBody = struct {
    call: *const fn (*TestTaskBody) void,
    socket: *udp_effect.Socket,
    /// True once the coroutine has run at all, which is how a test tells
    /// "parked in the receive" from "never started".
    started: bool = false,
    err: u8 = 0,
    datagrams: usize = 0,
    bytes: [64]u8 = undefined,
    len: usize = 0,

    fn erased(self: *TestTaskBody) tasks_mod.TaskResult {
        return @ptrCast(self);
    }
};

/// Wait for one datagram, exactly as `hostedUdpReceive` does, and record it.
fn testTaskReceive(body: *TestTaskBody) void {
    body.started = true;
    var slices: std.ArrayList(udp_effect.Slice) = .empty;
    defer slices.deinit(std.testing.allocator);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.testing.allocator);

    switch (udp_effect.receive(body.socket, 2000, 8, &slices, &payload, std.testing.allocator)) {
        .ok => |batch| {
            body.datagrams = batch.slices.len;
            if (batch.slices.len == 0) return;
            const first = batch.slices[0];
            body.len = @min(first.len, body.bytes.len);
            @memcpy(body.bytes[0..body.len], batch.payload[first.start..][0..body.len]);
        },
        .err => |code| body.err = code,
    }
}

/// The task registry with the Roc entry points replaced by `TestTaskBody`.
const TestTaskHooks = struct {
    pub fn enterTaskPhase(_: u64) void {
        active_phase = .task;
    }
    pub fn leaveTaskPhase(_: u64) void {
        active_phase = .idle;
    }
    pub fn runTask(run: abi.RocErasedCallable) tasks_mod.TaskResult {
        const body: *TestTaskBody = @ptrCast(@alignCast(run.?));
        body.call(body);
        return run;
    }
    pub fn dropResult(result: tasks_mod.TaskResult) void {
        // The test owns the body; nothing here allocated it.
        _ = result;
    }
    pub fn host() *RocHost {
        // Only the queue drain asks, and no test below spawns past the cap.
        unreachable;
    }
};

const TestTasks = tasks_mod.Tasks(TestTaskHooks);

/// Two bound loopback sockets on ephemeral ports, for the pump tests.
const TestSocketPair = struct {
    sender: udp_effect.Socket,
    receiver: udp_effect.Socket,

    fn open() !TestSocketPair {
        const loopback = udp_effect.parseIp4("127.0.0.1").?;
        const sender = switch (udp_effect.bind(loopback, 0)) {
            .ok => |socket| socket,
            .err => |code| {
                std.debug.print("bind failed with code {d}\n", .{code});
                return error.BindFailed;
            },
        };
        var pair = TestSocketPair{ .sender = sender, .receiver = undefined };
        pair.receiver = switch (udp_effect.bind(loopback, 0)) {
            .ok => |socket| socket,
            .err => |code| {
                pair.sender.inner.close();
                std.debug.print("bind failed with code {d}\n", .{code});
                return error.BindFailed;
            },
        };
        return pair;
    }

    fn close(self: *TestSocketPair) void {
        self.sender.inner.close();
        self.receiver.inner.close();
    }

    /// Send one datagram and return once the kernel is holding it.
    ///
    /// The precondition the pump tests are about is "a datagram the kernel
    /// already has", not "a datagram handed to `sendto` a moment ago". The
    /// two coincide on Linux loopback and need not anywhere else: a stack
    /// that finishes delivery after `sendto` returns would leave the one
    /// pump under test polling an empty socket, and the test would be
    /// measuring the network stack rather than the scheduler. Waiting for
    /// readability is what makes the precondition established rather than
    /// assumed.
    fn ping(self: *TestSocketPair) !void {
        try std.testing.expectEqual(
            @as(u8, 0),
            udp_effect.send(&self.sender, self.receiver.local_ip, self.receiver.local_port, "ping"),
        );
        try self.waitReadable();
    }

    /// Block this thread until the receiver has a datagram to read.
    ///
    /// Deliberately `poll` rather than anything of zio's: the event loop is
    /// exactly what must not run here, because a pump is the only thing
    /// allowed to advance the task under test.
    fn waitReadable(self: *TestSocketPair) !void {
        var fds = [_]zio.os.net.pollfd{.{
            .fd = self.receiver.inner.handle,
            .events = zio.os.net.POLL.IN,
            .revents = 0,
        }};
        // A loopback datagram the kernel has already accepted, so anything
        // but "at once" means a broken machine. The deadline is here so a
        // broken one fails instead of hanging.
        const ready = zio.os.net.poll(&fds, 1000) catch |err| {
            std.debug.print("poll on the receiver failed: {s}\n", .{@errorName(err)});
            return error.PollFailed;
        };
        // Windows is the exception, and not a failure: a receive already
        // posted against the socket completes into its own buffer, so the
        // datagram can be gone from the socket before this thread ever sees
        // it readable. That is the precondition met and consumed, not
        // missed, and the assertions after the pump tell the two apart.
        if (ready == 0 and builtin.os.tag != .windows) return error.DatagramNeverArrived;
    }
};

test "one yield pump resumes a task whose datagram arrived since the last one" {
    // The regression this pins: a pump that only yields takes zio's fast path,
    // which spends a scheduling quantum without ever running the event loop
    // whenever nothing else is already runnable. The parked receive then sits
    // unpolled for as many frames as it takes the tick budget to run out, and
    // a datagram that was in the kernel the whole time is delivered several
    // cycles late. One pump per frame must be one poll per frame.
    var app_tasks = try TestTasks.init(std.testing.allocator, false);
    defer app_tasks.deinit();
    app_tasks.activate();

    var sockets = try TestSocketPair.open();
    defer sockets.close();

    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    var body = TestTaskBody{ .call = &testTaskReceive, .socket = &sockets.receiver };
    TestTasks.spawnCurrent(&roc_host, body.erased());

    // Frame one: the task starts and parks with nothing to receive.
    app_tasks.pump(1, .yield);
    try std.testing.expect(body.started);
    try std.testing.expectEqual(@as(usize, 1), app_tasks.liveCount());
    try std.testing.expectEqual(@as(usize, 0), app_tasks.finished.items.len);

    try sockets.ping();

    // Frame two, and the only pump under test. `ping` did not return until
    // the kernel had the datagram, so the pump starts with it there and the
    // task must resume and finish inside it. That the pump can only ever see
    // what the kernel already holds is the point: every turn it takes is a
    // non-blocking poll, because a frame must not wait on a peer.
    app_tasks.pump(2, .yield);

    const finished = app_tasks.takeFinished();
    defer app_tasks.releaseTaken(finished);
    try std.testing.expectEqual(@as(usize, 1), finished.len);
    try std.testing.expectEqual(@as(u8, 0), body.err);
    try std.testing.expectEqual(@as(usize, 1), body.datagrams);
    try std.testing.expectEqualStrings("ping", body.bytes[0..body.len]);
}

test "one yield pump finishes a task whose datagram was buffered before it parked" {
    // The same latency, reached the other way round: the datagram is already
    // in the kernel when the task first runs. Starting the coroutine, parking
    // it, polling, resuming it and finishing it all have to happen inside one
    // pump -- zio submits the receive to the event loop even when the bytes
    // are already there, so an unpolled pump leaves this parked too.
    var app_tasks = try TestTasks.init(std.testing.allocator, false);
    defer app_tasks.deinit();
    app_tasks.activate();

    var sockets = try TestSocketPair.open();
    defer sockets.close();

    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    try sockets.ping();

    var body = TestTaskBody{ .call = &testTaskReceive, .socket = &sockets.receiver };
    TestTasks.spawnCurrent(&roc_host, body.erased());

    app_tasks.pump(1, .yield);

    const finished = app_tasks.takeFinished();
    defer app_tasks.releaseTaken(finished);
    try std.testing.expectEqual(@as(usize, 1), finished.len);
    try std.testing.expectEqual(@as(u8, 0), body.err);
    try std.testing.expectEqual(@as(usize, 1), body.datagrams);
    try std.testing.expectEqualStrings("ping", body.bytes[0..body.len]);
}

test "a file that is not text is refused rather than made into a Str" {
    // `RocStr.fromSlice` only copies, so an invalid one would be built without
    // complaint and every later string operation on it would be undefined.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A lone continuation byte: short, well inside every limit, and not UTF-8.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "binary", .data = "\x80 not text" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "text", .data = "caf\u{e9}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty", .data = "" });

    var path_buffer: [capture.path_capacity]u8 = undefined;

    const binary = hostedFilesReadText(&roc_host, tmpPathString(&roc_host, &path_buffer, &tmp.sub_path, "binary"));
    try std.testing.expectEqual(READ_ERR_NOT_UTF8, binary.err);
    try std.testing.expectEqual(@as(usize, 0), binary.contents.asSlice().len);
    binary.contents.decref(&roc_host);

    const text = hostedFilesReadText(&roc_host, tmpPathString(&roc_host, &path_buffer, &tmp.sub_path, "text"));
    try std.testing.expectEqual(@as(u8, 0), text.err);
    try std.testing.expectEqualStrings("caf\u{e9}", text.contents.asSlice());
    text.contents.decref(&roc_host);

    // The empty file is text too, and the shortest way to get it wrong.
    const empty = hostedFilesReadText(&roc_host, tmpPathString(&roc_host, &path_buffer, &tmp.sub_path, "empty"));
    try std.testing.expectEqual(@as(u8, 0), empty.err);
    try std.testing.expectEqual(@as(usize, 0), empty.contents.asSlice().len);
    empty.contents.decref(&roc_host);
}

test "a read above the inline cap is refused rather than copied on the frame thread" {
    // Turning bytes into a `Str` copies the whole file on the frame thread.
    // Without the cap a 16 MiB text read costs a 16 MiB copy mid-frame, which
    // is most of what parking the read was supposed to buy. A file of exactly
    // the limit still succeeds; one byte more is `TooLarge`.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    const at_limit = try std.testing.allocator.alloc(u8, MAX_INLINE_READ_BYTES);
    defer std.testing.allocator.free(at_limit);
    @memset(at_limit, 'x');

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "at-limit", .data = at_limit });
    const over_limit = try std.testing.allocator.alloc(u8, MAX_INLINE_READ_BYTES + 1);
    defer std.testing.allocator.free(over_limit);
    @memset(over_limit, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "over", .data = over_limit });

    var path_buffer: [capture.path_capacity]u8 = undefined;

    const fits = hostedFilesReadText(&roc_host, tmpPathString(&roc_host, &path_buffer, &tmp.sub_path, "at-limit"));
    try std.testing.expectEqual(@as(u8, 0), fits.err);
    try std.testing.expectEqual(MAX_INLINE_READ_BYTES, fits.contents.asSlice().len);
    fits.contents.decref(&roc_host);

    const refused = hostedFilesReadText(&roc_host, tmpPathString(&roc_host, &path_buffer, &tmp.sub_path, "over"));
    try std.testing.expectEqual(READ_ERR_TOO_LARGE, refused.err);
    // Nothing was copied: the answer carries an empty string.
    try std.testing.expectEqual(@as(usize, 0), refused.contents.asSlice().len);
    refused.contents.decref(&roc_host);
}

/// A Roc-owned path string for a file `std.testing.tmpDir` created, resolved
/// the way the effects resolve one: against the test's working directory.
fn tmpPathString(roc_host: *RocHost, buffer: []u8, sub_path: []const u8, name: []const u8) abi.RocStr {
    const path = std.fmt.bufPrint(buffer, testing_tmp_prefix ++ "{s}/{s}", .{ sub_path, name }) catch unreachable;
    return abi.RocStr.fromSlice(path, roc_host);
}

/// Where `std.testing.tmpDir` puts its directory, relative to the test's cwd.
///
/// The effects resolve paths against `cwd`, so a test file has to be named the
/// way they will look for it.
const testing_tmp_prefix = ".zig-cache/tmp/";

/// An allocator that reports how many bytes it was asked for.
///
/// It wraps a real allocator rather than standing in for one: the memory is
/// genuinely allocated and genuinely freed, so `std.testing.allocator`
/// underneath still fails a leak, and the count is of work that actually
/// happened. Installed as the Roc environment's allocator, it measures exactly
/// the thing the byte-list path claims not to do.
const CountingAllocator = struct {
    inner: std.mem.Allocator,
    allocated_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.inner.rawAlloc(len, alignment, ret_addr);
        if (result != null) self.allocated_bytes += len;
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

/// A `RocHost` whose frees route through the resource heaps, as the real one's do.
///
/// Without this a test that drops a seamless byte list would hand its typed
/// heap box to the general allocator rather than retiring its native buffer,
/// the retirement path being tested would never run at all.
fn routingTestHost(env: *abi.RocEnv) RocHost {
    var roc_host = abi.makeRocHost(env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    return roc_host;
}

test "the socket ceiling is a refusal an app can bind its way back out of" {
    // The one bound an app can actually reach. `Udp.bind!` past the ceiling has
    // to report `ResourceLimit` *and* leave no descriptor behind, and releasing
    // a socket has to make the slot usable again -- otherwise a game that
    // rebinds when the player changes port dies after eight attempts.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    const startup = PhaseScope.enter(.startup);
    defer startup.leave();
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        udp_socket_heap.deinitAll();
    }

    const rt = zio.Runtime.init(std.testing.allocator, .{
        .executors = .exact(1),
        .enable_main_executor = true,
    }) catch return;
    defer rt.deinit();

    var handles: [MAX_LIVE_UDP_SOCKETS]*u64 = undefined;
    for (&handles) |*handle| {
        const bound = hostedUdpBind(&roc_host, .{ .ip = abi.RocStr.fromSlice("127.0.0.1", &roc_host), .port = 0 });
        try std.testing.expectEqual(@as(u8, 0), bound.err);
        handle.* = bound.handle;
    }
    try std.testing.expectEqual(MAX_LIVE_UDP_SOCKETS, udp_socket_heap.active());

    const refused = hostedUdpBind(&roc_host, .{ .ip = abi.RocStr.fromSlice("127.0.0.1", &roc_host), .port = 0 });
    try std.testing.expectEqual(udp_effect.ERR_RESOURCE_LIMIT, refused.err);
    try std.testing.expectEqual(MAX_LIVE_UDP_SOCKETS, udp_socket_heap.active());

    // Release one. The slot is retired rather than free, so the next bind is
    // what finishes the destruction -- which is exactly the case that would
    // fail if `insert` did not drain its own heap first.
    releaseResourceBox(&roc_host, handles[0]);
    const reused = hostedUdpBind(&roc_host, .{ .ip = abi.RocStr.fromSlice("127.0.0.1", &roc_host), .port = 0 });
    try std.testing.expectEqual(@as(u8, 0), reused.err);
    handles[0] = reused.handle;

    for (handles) |handle| releaseResourceBox(&roc_host, handle);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), udp_socket_heap.active());
}

test "a bad address is refused before any descriptor is opened" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    const startup = PhaseScope.enter(.startup);
    defer startup.leave();

    for ([_][]const u8{ "::1", "localhost", "999.0.0.1", "" }) |text| {
        const result = hostedUdpBind(&roc_host, .{ .ip = abi.RocStr.fromSlice(text, &roc_host), .port = 0 });
        try std.testing.expectEqual(udp_effect.ERR_INVALID_ADDRESS, result.err);
    }
    try std.testing.expectEqual(@as(usize, 0), udp_socket_heap.active());
}

test "completing a large read transfers the read's allocation without copying" {
    // The claim under test, stated as a measurement: finishing a read costs the
    // frame thread nothing proportional to the file. The result has only the
    // three-word List value, so the same number comes out for a 16 MiB file as
    // for a one-line one -- and, on the same instrument, the small-file path
    // costs the whole payload.
    const file_bytes: usize = 16 * 1024 * 1024;

    var counter = CountingAllocator{ .inner = std.testing.allocator };
    var roc_env = abi.RocEnv{ .allocator = counter.allocator(), .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        file_bytes_heap.deinitAll();
    }

    // Stands in for the buffer a parked read filled before it resumed. A
    // different allocator on purpose: the cost of installing it shows up in
    // `counter`, and filling it does not.
    const read_bytes = try std.testing.allocator.alloc(u8, file_bytes);
    @memset(read_bytes, 'z');
    const read_ptr = read_bytes.ptr;

    counter.allocated_bytes = 0;
    const large = installReadBytes(std.testing.allocator, read_bytes);
    const large_cost = counter.allocated_bytes;

    try std.testing.expectEqual(@as(u8, 0), large.err);
    try std.testing.expectEqual(@as(usize, file_bytes), large.bytes.len());

    // Installed, not copied: the List reads the read's own allocation at the
    // same address, and has a tagged typed-heap allocation owner.
    try std.testing.expectEqual(read_ptr, large.bytes.elements_ptr.?);
    try std.testing.expect(large.bytes.isSeamlessSlice());

    // The same delivery for a file four million times smaller costs the frame
    // thread exactly the same, which is the property being claimed.
    const small_bytes = try std.testing.allocator.dupe(u8, "four bytes worth, near enough");
    counter.allocated_bytes = 0;
    const small = installReadBytes(std.testing.allocator, small_bytes);
    try std.testing.expectEqual(large_cost, counter.allocated_bytes);

    // The control. `Files.read_text!` copies its whole payload through the Roc
    // allocator, so the number above is a result and not a broken meter.
    const inline_bytes = try std.testing.allocator.alloc(u8, MAX_INLINE_READ_BYTES);
    defer std.testing.allocator.free(inline_bytes);
    @memset(inline_bytes, 'a');
    counter.allocated_bytes = 0;
    const copied = abi.RocStr.fromSlice(inline_bytes, &roc_host);
    try std.testing.expect(counter.allocated_bytes >= MAX_INLINE_READ_BYTES);
    copied.decref(&roc_host);

    large.bytes.decref(&roc_host);
    small.bytes.decref(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
}

test "seamless byte lists retain their typed slot through List and Str ARC in every drop order" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        file_bytes_heap.deinitAll();
    }

    // Four independently-owned aliases exercise the two generated ARC paths:
    // a whole list, a sublist-shaped list, and a Str converted from the list.
    // The permutations are deliberately exhaustive because releasing the last
    // reference through either List or Str must route to the same typed heap.
    const Drop = enum { whole, alias, sublist, string };
    const orders = [_][4]Drop{
        .{ .whole, .alias, .sublist, .string },
        .{ .whole, .alias, .string, .sublist },
        .{ .whole, .sublist, .alias, .string },
        .{ .whole, .sublist, .string, .alias },
        .{ .whole, .string, .alias, .sublist },
        .{ .whole, .string, .sublist, .alias },
        .{ .alias, .whole, .sublist, .string },
        .{ .alias, .whole, .string, .sublist },
        .{ .alias, .sublist, .whole, .string },
        .{ .alias, .sublist, .string, .whole },
        .{ .alias, .string, .whole, .sublist },
        .{ .alias, .string, .sublist, .whole },
        .{ .sublist, .whole, .alias, .string },
        .{ .sublist, .whole, .string, .alias },
        .{ .sublist, .alias, .whole, .string },
        .{ .sublist, .alias, .string, .whole },
        .{ .sublist, .string, .whole, .alias },
        .{ .sublist, .string, .alias, .whole },
        .{ .string, .whole, .alias, .sublist },
        .{ .string, .whole, .sublist, .alias },
        .{ .string, .alias, .whole, .sublist },
        .{ .string, .alias, .sublist, .whole },
        .{ .string, .sublist, .whole, .alias },
        .{ .string, .sublist, .alias, .whole },
    };
    const payload = "seamless byte-list aliases keep this host allocation alive";

    for (orders) |order| {
        const owned = try std.testing.allocator.dupe(u8, payload);
        const installed = installReadBytes(std.testing.allocator, owned);
        const whole = installed.bytes;

        // The read owns the first list reference. Give the three aliases below
        // their own references before it drops.
        whole.incref(3);
        try std.testing.expectEqual(owned.ptr, whole.elements_ptr.?);
        try std.testing.expect(whole.isSeamlessSlice());
        try std.testing.expectEqualStrings(payload, whole.items());
        try std.testing.expectEqual(@as(usize, 1), file_bytes_heap.active());

        // `List.sublist` produces this exact shape: visible bytes move while
        // the tagged allocation pointer remains the original backing resource.
        const sublist = abi.RocListWith(u8, false){
            .elements_ptr = whole.elements_ptr.? + 3,
            .length = whole.len() - 7,
            .capacity_or_alloc_ptr = whole.capacity_or_alloc_ptr,
        };
        try std.testing.expectEqualStrings(payload[3 .. payload.len - 4], sublist.items());

        const alias = whole;

        // `Str.from_utf8` validates first, increfs this backing allocation,
        // and returns this tagged-string representation. Build that exact
        // post-validation ownership shape here; the compiler builtin is
        // separately covered by its seamless-slice tests.
        const string = abi.RocStr{
            .bytes = @ptrCast(whole.elements_ptr.?),
            .capacity_or_alloc_ptr = whole.capacity_or_alloc_ptr,
            .length = whole.len(),
        };
        try std.testing.expect(string.isSeamlessSlice());
        try std.testing.expectEqualStrings(payload, string.asSlice());

        for (order, 0..) |drop, index| {
            switch (drop) {
                .whole => whole.decref(&roc_host),
                .alias => alias.decref(&roc_host),
                .sublist => sublist.decref(&roc_host),
                .string => string.decref(&roc_host),
            }
            if (index + 1 == order.len) {
                try std.testing.expectEqual(@as(usize, 1), file_bytes_heap.retiredCount());
            } else {
                try std.testing.expectEqual(@as(usize, 1), file_bytes_heap.active());
            }
        }
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
    }
}

test "an empty file transfers to the canonical empty list without a resource slot" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        file_bytes_heap.deinitAll();
    }

    const owned = try std.testing.allocator.alloc(u8, 0);
    const installed = installReadBytes(std.testing.allocator, owned);
    try std.testing.expect(installed.bytes.isEmpty());
    try std.testing.expect(!installed.bytes.isSeamlessSlice());

    // Canonical empties do not retain a typed resource slot.
    installed.bytes.decref(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.retiredCount());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
}

test "byte-list delivery reservations bound reads before they can start" {
    defer file_bytes_delivery_reservations.clearAfterWorkStops();
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());

    var reserved: usize = 0;
    while (reserved < MAX_LIVE_FILE_BYTE_LISTS) : (reserved += 1) {
        try std.testing.expect(file_bytes_delivery_reservations.reserve());
    }
    try std.testing.expectEqual(MAX_LIVE_FILE_BYTE_LISTS, file_bytes_delivery_reservations.count);
    try std.testing.expect(!file_bytes_delivery_reservations.reserve());

    while (file_bytes_delivery_reservations.count != 0) file_bytes_delivery_reservations.release();
}

test "a full byte-list heap refuses a read before it opens the path" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        file_bytes_delivery_reservations.clearAfterWorkStops();
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        file_bytes_heap.deinitAll();
    }

    // The reads are kept rather than released: dropping one is what frees its
    // bytes, so the heap only fills while the app is still holding.
    var held: [MAX_LIVE_FILE_BYTE_LISTS]abi.RocListWith(u8, false) = undefined;
    var filled: usize = 0;
    while (filled < MAX_LIVE_FILE_BYTE_LISTS) : (filled += 1) {
        const owned = try std.testing.allocator.dupe(u8, "held");
        const installed = installReadBytes(std.testing.allocator, owned);
        try std.testing.expectEqual(@as(u8, 0), installed.err);
        held[filled] = installed.bytes;
    }
    try std.testing.expectEqual(MAX_LIVE_FILE_BYTE_LISTS, file_bytes_heap.active());

    // This must report `Busy`, not `NotFound`: admission happens before the
    // path is opened, so a doomed read never starts.
    const refused = readByteListWaiting(&roc_host, testing_tmp_prefix ++ "definitely-not-here.txt", .read);
    try std.testing.expectEqual(READ_ERR_BUSY, refused.err);
    try std.testing.expectEqual(@as(usize, 0), refused.bytes.len());
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);
    try std.testing.expectEqual(MAX_LIVE_FILE_BYTE_LISTS, file_bytes_heap.active());

    // Installation stays defensive for a caller that already owns bytes: the
    // buffer is freed rather than leaked when there is no slot for it.
    const doomed = try std.testing.allocator.dupe(u8, "no slot for this");
    const no_slot = installReadBytes(std.testing.allocator, doomed);
    try std.testing.expectEqual(READ_ERR_BUSY, no_slot.err);
    try std.testing.expectEqual(@as(usize, 0), no_slot.bytes.len());
    try std.testing.expectEqual(MAX_LIVE_FILE_BYTE_LISTS, file_bytes_heap.active());

    for (held) |item| item.decref(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
}

test "a parked read delivers bytes and releases its reservation either way" {
    // The waiting path is the only read path now, and it must hand back bytes
    // rather than a string whether it succeeded or not -- and must not strand
    // its delivery reservation on the failure.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        file_bytes_delivery_reservations.clearAfterWorkStops();
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        file_bytes_heap.deinitAll();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = "read on a coroutine, delivered as bytes";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bytes.txt", .data = payload });

    var path_buffer: [capture.path_capacity]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, testing_tmp_prefix ++ "{s}/bytes.txt", .{tmp.sub_path});

    const read = readByteListWaiting(&roc_host, path, .read);
    try std.testing.expectEqual(@as(u8, 0), read.err);
    try std.testing.expectEqualStrings(payload, read.bytes.items());
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);

    const missing = readByteListWaiting(&roc_host, testing_tmp_prefix ++ "definitely-not-here.txt", .read);
    try std.testing.expectEqual(READ_ERR_NOT_FOUND, missing.err);
    try std.testing.expectEqual(@as(usize, 0), missing.bytes.len());
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);

    // A listing rides the same path, and answers with the encoded entries.
    var dir_buffer: [capture.path_capacity]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buffer, testing_tmp_prefix ++ "{s}", .{tmp.sub_path});
    const listed = readByteListWaiting(&roc_host, dir_path, .list);
    try std.testing.expectEqual(@as(u8, 0), listed.err);
    try std.testing.expectEqualStrings("bytes.txt", listed.bytes.items()[1 .. listed.bytes.len() - 1]);
    try std.testing.expectEqual(DIR_ENTRY_FILE, listed.bytes.items()[0]);
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);

    read.bytes.decref(&roc_host);
    listed.bytes.decref(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
}

test "a screenshot path that escapes the output directory is refused, not rewritten" {
    // The sandbox check runs before anything else, so the refusal is reported
    // rather than a file appearing beside the example source. It also runs
    // before the effect needs a frame to capture, so this holds with no window.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer capture_screenshot_pending = false;

    try std.testing.expectEqual(
        capture.err_path_escapes,
        hostedCaptureScreenshot(&roc_host, abi.RocStr.fromSlice("../escaped.png", &roc_host)),
    );

    // A valid path gets past the sandbox. Tests run headless, where there is
    // no framebuffer to read, so the effect answers without writing a file of
    // zeroes rather than parking for a frame that cannot arrive.
    try std.testing.expectEqual(
        capture.err_none,
        hostedCaptureScreenshot(&roc_host, abi.RocStr.fromSlice("scene.png", &roc_host)),
    );
}

test "an offscreen export refuses an escaping path and releases the target either way" {
    // Same sandbox as a screenshot, checked before the target is even resolved,
    // so a refused path costs no readback. The target's reference is consumed
    // on every path, which is what the drained heap at the end shows.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_roc_host = null;
    }

    const target = storeRenderTexture(.headless).?;
    abi.increfBox(@ptrCast(target), 1);

    try std.testing.expectEqual(capture.err_path_escapes, hostedCaptureScreenshotTexture(&roc_host, .{
        .path = abi.RocStr.fromSlice("../escaped.png", &roc_host),
        .target = .{ .handle = target, .height = 8, .width = 16 },
    }));

    // A headless target has no pixels: every draw into it was a no-op, so the
    // export answers without writing a file of zeroes, exactly as a screenshot
    // does with no framebuffer.
    try std.testing.expectEqual(capture.err_none, hostedCaptureScreenshotTexture(&roc_host, .{
        .path = abi.RocStr.fromSlice("poster.png", &roc_host),
        .target = .{ .handle = target, .height = 8, .width = 16 },
    }));

    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    try std.testing.expectEqual(@as(u64, 0), still_budget.in_flight);
}

test "an offscreen export of a handle that resolves to nothing is unavailable" {
    // A released target, the `stub` a pure test holds, or a handle of the wrong
    // kind. Reported rather than fatal, because that is how every other
    // unresolved render-target handle is already reported -- and it is checked
    // before the headless answer, so an app sees the same outcome windowed.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_roc_host = null;
    }

    try std.testing.expectEqual(capture.err_target_unavailable, hostedCaptureScreenshotTexture(&roc_host, .{
        .path = abi.RocStr.fromSlice("poster.png", &roc_host),
        .target = .{ .handle = &invalid_texture_box.payload, .height = 0, .width = 0 },
    }));

    const shader = storeShader(.headless).?;
    try std.testing.expectEqual(capture.err_target_unavailable, hostedCaptureScreenshotTexture(&roc_host, .{
        .path = abi.RocStr.fromSlice("poster.png", &roc_host),
        .target = .{ .handle = @ptrCast(shader), .height = 8, .width = 16 },
    }));
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
}

test "an offscreen export called from update! is rejected" {
    // It waits, so it belongs where waiting is defined: a task, or `init!`,
    // where it blocks. Unlike a screenshot it waits for nothing on the frame
    // loop, which is why `init!` is in the set at all.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;
    active_roc_host = &roc_host;
    const phase = PhaseScope.enter(.update);
    last_phase_violation = null;
    defer {
        last_phase_violation = null;
        phase.leave();
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_roc_host = null;
    }

    const target = storeRenderTexture(.headless).?;
    _ = hostedCaptureScreenshotTexture(&roc_host, .{
        .path = abi.RocStr.fromSlice("poster.png", &roc_host),
        .target = .{ .handle = target, .height = 8, .width = 16 },
    });

    const violation = last_phase_violation orelse return error.OperationWasNotRejected;
    try std.testing.expectEqualStrings("Capture.screenshot_texture!", violation.operation);
    try std.testing.expect(violation.allowed.eql(during_wait));
    try std.testing.expectEqual(Phase.update, violation.actual);
}

test "phases restore what they interrupted rather than falling back to idle" {
    try std.testing.expectEqual(Phase.idle, active_phase);

    const startup = PhaseScope.enter(.startup);
    try std.testing.expectEqual(Phase.startup, active_phase);
    startup.leave();
    try std.testing.expectEqual(Phase.idle, active_phase);

    // A hosted effect runs inside the callback that called it, so a nested scope
    // has to land back in update and not in idle -- otherwise the phase after
    // a command would be wrong for the rest of the call.
    const update = PhaseScope.enter(.update);
    const nested = PhaseScope.enter(.render);
    try std.testing.expectEqual(Phase.render, active_phase);
    nested.leave();
    try std.testing.expectEqual(Phase.update, active_phase);
    update.leave();
    try std.testing.expectEqual(Phase.idle, active_phase);
}

test "each fresh input schedules one update and optional presentation" {
    const omitted = CycleCallbackSchedule.forInput(false);
    try std.testing.expectEqual(@as(u8, 1), omitted.updates);
    try std.testing.expectEqual(@as(u8, 0), omitted.presentations);

    const presented = CycleCallbackSchedule.forInput(true);
    try std.testing.expectEqual(@as(u8, 1), presented.updates);
    try std.testing.expectEqual(@as(u8, 1), presented.presentations);
}

/// Release everything `convertTilemapRawMap` allocated.
///
/// Only a test needs this: in a real build the record is returned into Roc,
/// which owns every list and string in it from then on.
fn releaseTilemapRawMap(host: *RocHost, map: TilemapRawMap) void {
    for (map.layers.allocationItems()) |layer| layer.name.decref(host);
    for (map.objects.allocationItems()) |object| {
        object.name.decref(host);
        object.type_name.decref(host);
    }
    for (map.properties.allocationItems()) |property| {
        property.name.decref(host);
        property.text.decref(host);
    }
    for (map.tilesets.allocationItems()) |tileset| {
        tileset.image_source.decref(host);
        tileset.name.decref(host);
    }
    map.layers.decref(host);
    map.objects.decref(host);
    map.properties.decref(host);
    map.tilesets.decref(host);
    map.gids.decref(host);
    map.points.decref(host);
    map.tile_properties.decref(host);
}

test "loading a map from a frame or an update is rejected, and from a task is not" {
    // A map is one file read plus one more per external tileset, so it belongs
    // where waiting is defined. In a real build a refusal aborts and never
    // returns; under `zig test` the guard records instead, so what the test can
    // check is that it fired and named the right things.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer last_phase_violation = null;

    for ([_]Phase{ .render, .update }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        last_phase_violation = null;

        const result = hostedTilemapLoadTmxRaw(&roc_host, abi.RocStr.fromSlice("examples/assets/nothing.tmx", &roc_host));
        try std.testing.expect(!result.ok);

        const violation = last_phase_violation orelse return error.OperationWasNotRejected;
        try std.testing.expectEqualStrings("Tilemap.load_tmx!", violation.operation);
        try std.testing.expect(violation.allowed.eql(during_wait));
        try std.testing.expectEqual(phase, violation.actual);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "tiles.tsx",
        .data =
        \\<tileset version="1.10" name="demo" tilewidth="16" tileheight="16" tilecount="4" columns="2">
        \\ <image source="images/tiles.png" width="32" height="32"/>
        \\</tileset>
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "map.tmx",
        .data =
        \\<map orientation="orthogonal" width="1" height="1" tilewidth="16" tileheight="16">
        \\ <tileset firstgid="5" source="tiles.tsx"/>
        \\ <layer name="Ground" width="1" height="1"><data encoding="csv">5</data></layer>
        \\</map>
        ,
    });
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, testing_tmp_prefix ++ "{s}/map.tmx", .{tmp.sub_path});

    // On a task both reads park, and the parse in between still answers. Two
    // files, so this also covers the referenced tileset going through the same
    // waiting path rather than a blocking one.
    const task = PhaseScope.enter(.task);
    defer task.leave();
    last_phase_violation = null;
    const loaded = hostedTilemapLoadTmxRaw(&roc_host, abi.RocStr.fromSlice(path, &roc_host));
    try std.testing.expect(loaded.ok);
    try std.testing.expect(last_phase_violation == null);
    releaseTilemapRawMap(&roc_host, loaded.map);
}

test "a drawing primitive called from update is rejected" {
    const phase = PhaseScope.enter(.update);
    defer phase.leave();
    last_phase_violation = null;
    defer last_phase_violation = null;
    defer blend_scope_count = 0;

    _ = hostedDrawBeginBlendRaw(.{ .arg0 = 1 });

    const violation = last_phase_violation orelse return error.OperationWasNotRejected;
    try std.testing.expectEqualStrings("Draw.with_blend_mode!", violation.operation);
    try std.testing.expect(violation.allowed.eql(during_render));
    try std.testing.expectEqual(Phase.update, violation.actual);
}

test "allocating a render texture during a frame is rejected" {
    // The review case this guard exists for: GPU allocation is not blocking
    // I/O, so "it does not block" was never the right test for what belongs
    // in a frame.
    const phase = PhaseScope.enter(.render);
    defer phase.leave();
    last_phase_violation = null;
    defer last_phase_violation = null;

    _ = hostedTextureLoadRenderTargetRaw(.{ .width = 0, .height = 0 });

    const violation = last_phase_violation orelse return error.OperationWasNotRejected;
    try std.testing.expectEqualStrings("Draw.RenderTexture.load!", violation.operation);
    try std.testing.expect(violation.allowed.eql(during_load));
}

test "asking how big the drawing surface is is refused outside the frame" {
    // The answer is only defined while a surface is open, and admitting the
    // read anywhere else would make it a back door for `update` to observe the
    // window outside the input.
    last_phase_violation = null;
    defer last_phase_violation = null;

    for ([_]Phase{ .idle, .startup, .update }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        last_phase_violation = null;
        _ = hostedDrawFrameSizeRaw();
        const violation = last_phase_violation orelse return error.OperationWasNotRejected;
        try std.testing.expectEqualStrings("Draw.Frame.size!", violation.operation);
        try std.testing.expect(violation.allowed.eql(during_render));
        try std.testing.expectEqual(phase, violation.actual);
    }
}

test "an operation allowed in several phases is accepted in each of them" {
    last_phase_violation = null;
    defer last_phase_violation = null;

    for ([_]Phase{ .startup, .update }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        enforcePhase("Mouse.set_cursor!", during_update);
        try std.testing.expectEqual(@as(?PhaseViolation, null), last_phase_violation);
    }

    // ...and rejected everywhere else, including the phase it is nearest to.
    for ([_]Phase{ .idle, .render }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        last_phase_violation = null;
        enforcePhase("Mouse.set_cursor!", during_update);
        const violation = last_phase_violation orelse return error.OperationWasNotRejected;
        try std.testing.expectEqual(phase, violation.actual);
    }
}

test "uploading pixels is refused from render, and taken during update" {
    last_phase_violation = null;
    defer last_phase_violation = null;

    // An upload mutates a resource and may enter the graphics driver. It is
    // not drawing, and being allowed here is what let an app pay for a
    // full-texture upload in the middle of a frame it was already behind on.
    {
        const scope = PhaseScope.enter(.render);
        defer scope.leave();
        enforcePhase("Assets.update_texture!", during_update);
        const violation = last_phase_violation orelse return error.UploadWasNotRejected;
        try std.testing.expectEqual(Phase.render, violation.actual);
    }

    // Startup and update both have authority to upload. Neither may turn a
    // structurally valid call into a capacity-based no-op.
    for ([_]Phase{ .startup, .update }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        last_phase_violation = null;
        enforcePhase("Assets.update_texture!", during_update);
        try std.testing.expectEqual(@as(?PhaseViolation, null), last_phase_violation);
    }
}

test "window-size suggestions and frame-rate caps are taken during update" {
    // raylib resizes a live window and re-caps a running loop as readily as it
    // does before the first frame, so both effects are reachable from `update!`
    // and a task: an app can resize itself in response to its own layout, and
    // drop its frame cap while running. Headless keeps the calls off raylib
    // while still exercising the guard and the size bookkeeping.
    last_phase_violation = null;
    defer last_phase_violation = null;
    const restore_width = headless_screen_width;
    const restore_height = headless_screen_height;
    defer headless_screen_width = restore_width;
    defer headless_screen_height = restore_height;

    for ([_]Phase{ .startup, .update }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        last_phase_violation = null;
        try std.testing.expectEqual(TRY_TAG_OK, hostedSuggestWindowSize(.{ .width = 321, .height = 123 }));
        hostedSuggestWindowMinSize(.{ .width = 160, .height = 90 });
        hostedSetTargetFps(45);
        try std.testing.expectEqual(@as(?PhaseViolation, null), last_phase_violation);
        try std.testing.expectEqual(@as(i32, 321), headless_screen_width);
        try std.testing.expectEqual(@as(i32, 123), headless_screen_height);
    }

    // Widening them stops at the frame: a resize mid-draw would move the
    // coordinate space the frame is already drawing into.
    const scope = PhaseScope.enter(.render);
    defer scope.leave();
    last_phase_violation = null;
    hostedSetTargetFps(45);
    const violation = last_phase_violation orelse return error.OperationWasNotRejected;
    try std.testing.expectEqualStrings("Window.set_target_fps!", violation.operation);
    try std.testing.expect(violation.allowed.eql(during_update));
}

test "the DPI scale answers in every callback and never with a factor to divide by" {
    last_phase_violation = null;
    defer last_phase_violation = null;

    // An app multiplies a window size by this to learn the resolution a capture
    // records at, and divides by it to go the other way. The backend answers 0
    // for a window it has not finished creating, so the factor that crosses has
    // to be one that survives both.
    try std.testing.expectEqual(@as(f32, 1), usableScaleFactor(0));
    try std.testing.expectEqual(@as(f32, 1), usableScaleFactor(-2));
    try std.testing.expectEqual(@as(f32, 1), usableScaleFactor(std.math.nan(f32)));
    try std.testing.expectEqual(@as(f32, 1), usableScaleFactor(std.math.inf(f32)));
    try std.testing.expectEqual(@as(f32, 2), usableScaleFactor(2));

    // Monitor positions arrive as floats and are used as whole pixels, so a
    // value no `i32` can hold has to saturate rather than trap the host.
    try std.testing.expectEqual(@as(i32, -1920), monitorCoordinate(-1920));
    try std.testing.expectEqual(@as(i32, 0), monitorCoordinate(std.math.nan(f32)));
    try std.testing.expectEqual(std.math.maxInt(i32), monitorCoordinate(std.math.inf(f32)));
    try std.testing.expectEqual(std.math.minInt(i32), monitorCoordinate(-std.math.inf(f32)));

    // Copying two floats the backend already holds is what makes this legal
    // mid-frame, where a shader or a capture is the thing that needs it.
    for ([_]Phase{ .startup, .update, .render, .task }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        last_phase_violation = null;
        const scale = hostedWindowScaleDpi();
        try std.testing.expectEqual(@as(?PhaseViolation, null), last_phase_violation);
        try std.testing.expectEqual(DEFAULT_WINDOW_SCALE, scale.x);
        try std.testing.expectEqual(DEFAULT_WINDOW_SCALE, scale.y);
    }
}

test "a headless run enumerates one monitor the size of its own window" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;

    last_phase_violation = null;
    defer last_phase_violation = null;
    const restore_width = headless_screen_width;
    const restore_height = headless_screen_height;
    defer headless_screen_width = restore_width;
    defer headless_screen_height = restore_height;
    headless_screen_width = 1280;
    headless_screen_height = 720;

    {
        const scope = PhaseScope.enter(.update);
        defer scope.leave();
        const monitors = hostedMonitors(&roc_host);
        defer {
            for (monitors.allocationItems()) |monitor| monitor.decref(&roc_host);
            monitors.decref(&roc_host);
        }

        try std.testing.expectEqual(@as(?PhaseViolation, null), last_phase_violation);
        try std.testing.expectEqual(@as(usize, 1), monitors.items().len);

        // Sized from the configured window rather than from the CI machine, so
        // an app that places itself on a monitor answers the same everywhere.
        const only = monitors.items()[0];
        try std.testing.expectEqual(@as(i32, 0), only.index);
        try std.testing.expectEqualStrings(HEADLESS_MONITOR_NAME, only.name.asSlice());
        try std.testing.expectEqual(@as(i32, 1280), only.width);
        try std.testing.expectEqual(@as(i32, 720), only.height);
        try std.testing.expectEqual(@as(i32, 0), only.x);
        try std.testing.expectEqual(@as(i32, 0), only.y);
        try std.testing.expectEqual(HEADLESS_MONITOR_REFRESH_HZ, only.refresh_hz);
    }

    // Enumerating allocates a list and copies a name per monitor, which is why
    // it stops at the frame while the scale factor above does not.
    const scope = PhaseScope.enter(.render);
    defer scope.leave();
    last_phase_violation = null;
    const refused = hostedMonitors(&roc_host);
    for (refused.allocationItems()) |monitor| monitor.decref(&roc_host);
    refused.decref(&roc_host);

    const violation = last_phase_violation orelse return error.OperationWasNotRejected;
    try std.testing.expectEqualStrings("Window.monitors!", violation.operation);
    try std.testing.expect(violation.allowed.eql(during_update));
}

test "window placement suggestions are taken wherever host state changes" {
    last_phase_violation = null;
    defer last_phase_violation = null;

    // Headless has no window manager to move a window on, so the raylib calls
    // sit behind `headlessMode()` and what this exercises is the guard --
    // including that an out-of-range monitor index is an ordinary no-op rather
    // than a refusal an app would have to handle.
    for ([_]Phase{ .startup, .update, .task }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        last_phase_violation = null;
        hostedSuggestWindowPosition(.{ .x = -1920, .y = 40 });
        hostedSuggestWindowMonitor(0);
        hostedSuggestWindowMonitor(-1);
        hostedSuggestWindowMonitor(99);
        try std.testing.expectEqual(@as(?PhaseViolation, null), last_phase_violation);
    }

    // Moving the window mid-frame would move the surface being drawn into.
    const scope = PhaseScope.enter(.render);
    defer scope.leave();
    last_phase_violation = null;
    hostedSuggestWindowPosition(.{ .x = 0, .y = 0 });
    const position_violation = last_phase_violation orelse return error.OperationWasNotRejected;
    try std.testing.expectEqualStrings("Window.suggest_position!", position_violation.operation);
    try std.testing.expect(position_violation.allowed.eql(during_update));

    last_phase_violation = null;
    hostedSuggestWindowMonitor(0);
    const monitor_violation = last_phase_violation orelse return error.OperationWasNotRejected;
    try std.testing.expectEqualStrings("Window.suggest_monitor!", monitor_violation.operation);
    try std.testing.expect(monitor_violation.allowed.eql(during_update));
}

test "a rejection names every phase the operation was allowed in" {
    var buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "init! or update! or a task",
        describePhases(during_update, &buffer),
    );
    try std.testing.expectEqualStrings("render!", describePhases(during_render, &buffer));
}

test "an operation called from its own phase is not rejected" {
    const phase = PhaseScope.enter(.render);
    defer phase.leave();
    last_phase_violation = null;
    defer last_phase_violation = null;
    defer blend_scope_count = 0;

    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginBlendRaw(.{ .arg0 = 1 }));
    hostedDrawEndBlendRaw();
    try std.testing.expect(last_phase_violation == null);
}

/// Run the app's startup callback.
///
/// It takes no snapshot: `App.Startup` is authority, not observation. Nothing
/// has been sampled when this runs, so there is nothing to hand over -- an app
/// seeds its model with `Devices.empty` and waits for the first `App.Input`.
fn initModel() RocResult {
    if (TRACE_HOST) std.log.debug("[HOST] Calling init_for_host...", .{});
    const phase = PhaseScope.enter(.startup);
    defer phase.leave();
    const init_result = init_for_host();
    if (TRACE_HOST) std.log.debug("[HOST] init returned, tag={d}", .{@intFromEnum(init_result.tag)});
    return init_result;
}

/// Environment variable that turns per-frame Roc allocator metering on.
const ALLOC_STATS_ENV: []const u8 = "ROC_RAY_ALLOC_STATS";

/// Environment variable that logs every task's spawn, park, resume, and finish.
const TRACE_TASKS_ENV: []const u8 = "ROC_RAY_TRACE_TASKS";

/// Private performance-harness seam for exercising recorder backpressure.
const OBSERVATORY_BENCH_WRITER_DELAY_ENV: []const u8 = "ROC_RAY_OBSERVATORY_BENCH_WRITER_DELAY_MS";

fn observatoryBenchmarkWriterDelayMs(value: ?[]const u8) u32 {
    const text = value orelse return 0;
    const parsed = std.fmt.parseInt(u32, text, 10) catch return 0;
    return @min(parsed, 10_000);
}

/// Per-frame Roc allocator traffic, reported when `ROC_RAY_ALLOC_STATS=1`.
///
/// A frame that mutates a uniquely referenced collection in the model pays
/// nothing proportional to that collection; a frame that copies it pays for
/// every element. That difference is a number, and this is the instrument that
/// reads it. The meter wraps the allocator the Roc environment hands to
/// `roc_alloc`/`roc_realloc`/`roc_dealloc`, so every byte Roc asks for is
/// counted, and a phase mark attributes the `update` call's share separately
/// from the rest of the frame.
///
/// It wraps a real allocator rather than standing in for one, exactly like the
/// `CountingAllocator` used in the byte-delivery tests: the memory is genuinely
/// allocated and freed, so what is counted is work that actually happened.
///
/// Only allocations and frees are counted, which is all of them: Roc's
/// `roc_realloc` always takes a fresh block, copies, and frees the old one, so
/// growing a Roc collection is an alloc and a free here and never an in-place
/// resize. `resize`/`remap` are forwarded so host-side Zig containers still
/// work, and nothing Roc does reaches them.
///
/// Counters are plain integers, not atomics, and nothing needs them to be:
/// every Roc value is allocated and freed on the frame thread, tasks included,
/// because a task runs on its own coroutine stack on that same thread.
const AllocMeter = struct {
    inner: std.mem.Allocator,
    alloc_bytes: u64 = 0,
    alloc_calls: u64 = 0,
    free_bytes: u64 = 0,
    free_calls: u64 = 0,
    update_bytes: u64 = 0,
    update_calls: u64 = 0,
    live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,

    /// Counter snapshot used to attribute one call's allocations to a phase.
    const Mark = struct { bytes: u64, calls: u64 };

    fn allocator(self: *AllocMeter) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *AllocMeter = @ptrCast(@alignCast(context));
        const result = self.inner.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.alloc_bytes += len;
            self.alloc_calls += 1;
            self.live_bytes +|= len;
            self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
            allocationAllocated(@intFromPtr(result.?), len);
        }
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *AllocMeter = @ptrCast(@alignCast(context));
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *AllocMeter = @ptrCast(@alignCast(context));
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *AllocMeter = @ptrCast(@alignCast(context));
        self.free_bytes += memory.len;
        self.free_calls += 1;
        self.live_bytes -|= memory.len;
        allocationFreed(@intFromPtr(memory.ptr), memory.len);
        self.inner.rawFree(memory, alignment, ret_addr);
    }

    fn mark(self: *const AllocMeter) Mark {
        return .{ .bytes = self.alloc_bytes, .calls = self.alloc_calls };
    }

    fn clearFrame(self: *AllocMeter) void {
        self.alloc_bytes = 0;
        self.alloc_calls = 0;
        self.free_bytes = 0;
        self.free_calls = 0;
        self.update_bytes = 0;
        self.update_calls = 0;
        self.peak_live_bytes = self.live_bytes;
    }
};

/// Storage for the frame-thread meter. Only read when `alloc_meter_enabled`.
var alloc_meter: AllocMeter = .{ .inner = undefined };
/// Whether `ROC_RAY_ALLOC_STATS` asked for metering on this run.
var alloc_meter_enabled: bool = false;
/// Whether allocation counters should also be printed to stderr.
///
/// Observatory needs the meter for its cycle summaries, but recording must
/// not silently turn on a high-volume diagnostic stream or perturb an
/// application's ordinary stderr behavior.
var alloc_meter_reporting_enabled: bool = false;

/// Wrap `inner` in the meter when the environment asks for it, else pass it
/// through untouched so an unmetered run keeps its original allocator vtable.
fn meteredAllocator(inner: std.mem.Allocator, record_stats: bool) std.mem.Allocator {
    const requested = hostGetEnv(ALLOC_STATS_ENV);
    const reporting = requested != null and requested.?.len != 0 and !std.mem.eql(u8, requested.?, "0");
    alloc_meter_enabled = false;
    alloc_meter_reporting_enabled = false;
    if (!record_stats and !reporting) return inner;
    alloc_meter = .{ .inner = inner };
    alloc_meter_enabled = true;
    alloc_meter_reporting_enabled = reporting;
    return alloc_meter.allocator();
}

/// Snapshot the meter before a phase whose allocations are attributed on their own.
fn allocMeterMark() AllocMeter.Mark {
    if (!alloc_meter_enabled) return .{ .bytes = 0, .calls = 0 };
    return alloc_meter.mark();
}

/// Attribute everything allocated since `since` to this frame's `update` call.
fn allocMeterRecordUpdate(since: AllocMeter.Mark) void {
    if (!alloc_meter_enabled) return;
    alloc_meter.update_bytes += alloc_meter.alloc_bytes - since.bytes;
    alloc_meter.update_calls += alloc_meter.alloc_calls - since.calls;
}

/// Report and clear everything allocated before the first frame, so the
/// per-frame lines are not polluted by config and `init!`.
fn reportStartupAllocStats() void {
    if (!alloc_meter_enabled) return;
    if (alloc_meter_reporting_enabled) {
        std.debug.print(
            "[roc-ray-alloc] startup alloc_bytes={d} allocs={d} frees={d} free_bytes={d}\n",
            .{ alloc_meter.alloc_bytes, alloc_meter.alloc_calls, alloc_meter.free_calls, alloc_meter.free_bytes },
        );
    }
    alloc_meter.clearFrame();
}

/// Report and clear one host cycle's metered traffic.
fn reportCycleAllocStats(cycle_index: u64) void {
    if (!alloc_meter_enabled) return;
    if (alloc_meter_reporting_enabled) {
        std.debug.print(
            "[roc-ray-alloc] cycle={d} alloc_bytes={d} allocs={d} frees={d} free_bytes={d} update_bytes={d} update_allocs={d}\n",
            .{
                cycle_index,
                alloc_meter.alloc_bytes,
                alloc_meter.alloc_calls,
                alloc_meter.free_calls,
                alloc_meter.free_bytes,
                alloc_meter.update_bytes,
                alloc_meter.update_calls,
            },
        );
    }
    alloc_meter.clearFrame();
}

fn formatObservatoryDefaultPath(allocator: std.mem.Allocator, raw_name: []const u8, seconds: u64, collision: u32) ![]u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_time = epoch.getDaySeconds();
    var sanitized: [128]u8 = undefined;
    var name_len: usize = 0;
    for (raw_name) |byte| {
        if (name_len == sanitized.len) break;
        const portable = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
        const replacement: u8 = if (portable) byte else '-';
        if (replacement == '-' and name_len != 0 and sanitized[name_len - 1] == '-') continue;
        sanitized[name_len] = replacement;
        name_len += 1;
    }
    if (name_len == 0) {
        @memcpy(sanitized[0..3], "app");
        name_len = 3;
    }

    const suffix = if (collision <= 1) "" else try std.fmt.allocPrint(allocator, "-{d}", .{collision});
    defer if (collision > 1) allocator.free(suffix);
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z-{s}{s}.rrstats",
        .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, day_time.getHoursIntoDay(), day_time.getMinutesIntoHour(), day_time.getSecondsIntoMinute(), sanitized[0..name_len], suffix },
    );
}

fn reserveObservatoryPath(allocator: std.mem.Allocator, options: RuntimeOptions) ![]u8 {
    const io = mainThreadIo();
    if (options.stats_output) |explicit| return allocator.dupe(u8, explicit);
    const wall_nanos = std.Io.Clock.real.now(mainThreadIo()).nanoseconds;
    const seconds: u64 = @intCast(@max(@divFloor(wall_nanos, std.time.ns_per_s), 0));
    const raw_name = if (options.app_args.len == 0) "app" else portableAppName(std.mem.span(options.app_args[0]));
    var collision: u32 = 1;
    while (true) : (collision += 1) {
        const path = try formatObservatoryDefaultPath(allocator, raw_name, seconds, collision);
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return path,
            else => {
                allocator.free(path);
                return err;
            },
        };
        allocator.free(path);
        continue;
    }
}

test "observatory default paths use UTC sanitation fallback and collision suffixes" {
    const allocator = std.testing.allocator;
    const first = try formatObservatoryDefaultPath(allocator, "my app?!", 0, 1);
    defer allocator.free(first);
    try std.testing.expectEqualStrings("19700101T000000Z-my-app-.rrstats", first);
    const fallback = try formatObservatoryDefaultPath(allocator, "", 0, 1);
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("19700101T000000Z-app.rrstats", fallback);
    const second = try formatObservatoryDefaultPath(allocator, "app", 0, 2);
    defer allocator.free(second);
    try std.testing.expectEqualStrings("19700101T000000Z-app-2.rrstats", second);
    const third = try formatObservatoryDefaultPath(allocator, "app", 0, 3);
    defer allocator.free(third);
    try std.testing.expectEqualStrings("19700101T000000Z-app-3.rrstats", third);
}

const ObservatoryRecording = struct { session: observatory.Session, path: []u8 };

fn portableBaseName(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == '/' or byte == '\\') start = index + 1;
    }
    return if (start == path.len) "unavailable" else path[start..];
}

fn portableAppName(path: []const u8) []const u8 {
    const executable = portableBaseName(path);
    const generic = std.mem.eql(u8, executable, "main") or
        std.mem.eql(u8, executable, "main.exe") or
        std.mem.eql(u8, executable, "main.roc");
    if (!generic) return executable;

    const executable_start = path.len - executable.len;
    if (executable_start == 0) return executable;
    const parent = path[0 .. executable_start - 1];
    const parent_name = portableBaseName(parent);
    return if (std.mem.eql(u8, parent_name, "unavailable")) executable else parent_name;
}

fn startObservatory(allocator: std.mem.Allocator, options: RuntimeOptions) !ObservatoryRecording {
    const buffer_bytes = std.math.mul(u64, options.stats_buffer_mib, 1024 * 1024) catch return error.InvalidArgument;
    // Each retained chunk also has one free-list and one ready-queue index.
    // Count those arrays inside the operator-selected recorder memory bound.
    const retained_bytes_per_chunk = @sizeOf(observatory.Chunk) + 2 * @sizeOf(usize);
    const chunks: usize = @intCast(buffer_bytes / retained_bytes_per_chunk);
    const max_output_bytes = std.math.mul(u64, options.stats_max_mib, 1024 * 1024) catch return error.InvalidArgument;
    const executable_argument = if (options.app_args.len == 0) "unavailable" else std.mem.span(options.app_args[0]);
    const executable_name = portableBaseName(executable_argument);
    const io = mainThreadIo();
    const clock_resolution = std.Io.Clock.awake.resolution(io) catch std.Io.Duration{ .nanoseconds = 0 };
    const utc_origin = std.Io.Clock.real.now(io).nanoseconds;
    while (true) {
        const path = try reserveObservatoryPath(allocator, options);
        const session = observatory.Session.start(allocator, .{
            .path = path,
            .chunk_count = chunks,
            .summary_reserve = @min(chunks, 8),
            .max_output_bytes = max_output_bytes,
            .detail = switch (options.stats_detail) {
                .summary => .summary,
                .standard => .standard,
                .full => .full,
            },
            .rocray_version = rocray_build_version,
            .roc_compiler_pin = if (roc_compiler_pin.len == 0) "unavailable" else roc_compiler_pin,
            .target_profile = observatoryTargetProfile(options.headless),
            .backend = observatoryBackendName(options.headless),
            .executable_name = executable_name,
            .app_name = portableAppName(executable_argument),
            .clock_resolution_ns = @intCast(@max(clock_resolution.nanoseconds, 0)),
            .utc_origin_unix_ns = @intCast(@max(utc_origin, 0)),
            .benchmark_writer_delay_ms = observatoryBenchmarkWriterDelayMs(
                hostGetEnv(OBSERVATORY_BENCH_WRITER_DELAY_ENV),
            ),
        }) catch |err| {
            allocator.free(path);
            // Generated names promise collision suffixing even when another
            // process wins between our access check and exclusive creation.
            switch (err) {
                error.AlreadyExists => if (options.stats_output == null) continue else return err,
                else => return err,
            }
        };
        return .{ .session = session, .path = path };
    }
}

fn startObservatoryIfEnabled(allocator: std.mem.Allocator, options: RuntimeOptions) !?ObservatoryRecording {
    if (!options.record_stats) return null;
    return try startObservatory(allocator, options);
}

test "observatory executable metadata basename is portable" {
    try std.testing.expectEqualStrings("app", portableBaseName("/opt/games/app"));
    try std.testing.expectEqualStrings("app.exe", portableBaseName("C:\\games\\app.exe"));
    try std.testing.expectEqualStrings("app", portableBaseName("app"));
    try std.testing.expectEqualStrings("unavailable", portableBaseName("/"));
    try std.testing.expectEqualStrings("particles", portableAppName("/tmp/examples/particles/main.roc"));
    try std.testing.expectEqualStrings("particles", portableAppName("C:\\examples\\particles\\main.exe"));
    try std.testing.expectEqualStrings("particles", portableAppName("/opt/games/particles"));
    try std.testing.expectEqualStrings("main.roc", portableAppName("main.roc"));
    try std.testing.expectEqualStrings("nightly-2026-08-23-fb208ba", roc_compiler_pin);
}

test "disabled observatory path performs no recorder startup work" {
    var options = RuntimeOptions{};
    options.stats_output = "must-not-exist-disabled.rrstats";
    var allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const before = active_observatory;
    try std.testing.expect(try startObservatoryIfEnabled(allocations.allocator(), options) == null);
    try std.testing.expectEqual(@as(usize, 0), allocations.allocations);
    try std.testing.expect(!allocations.has_induced_failure);
    try std.testing.expect(active_observatory == before);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, options.stats_output.?, .{}));
}

test "Observatory benchmark writer delay is bounded and opt in" {
    try std.testing.expectEqual(@as(u32, 0), observatoryBenchmarkWriterDelayMs(null));
    try std.testing.expectEqual(@as(u32, 0), observatoryBenchmarkWriterDelayMs("invalid"));
    try std.testing.expectEqual(@as(u32, 7), observatoryBenchmarkWriterDelayMs("7"));
    try std.testing.expectEqual(@as(u32, 10_000), observatoryBenchmarkWriterDelayMs("99999"));
}

fn recordObservatoryCycle(cycle: u64, started_ns: i96, update_ns: u64, render_ns: u64, task_ns: u64) void {
    const session = active_observatory orelse return;
    const duration_ns: u64 = @intCast(@max(observatoryAwakeNs() - started_ns, 0));
    const measured_ns = update_ns +| render_ns +| task_ns;
    _ = session.recordCycle(.{
        .cycle = cycle,
        .start_ns = @intCast(@max(started_ns - observatory_origin_ns, 0)),
        .duration_ns = duration_ns,
        .update_ns = update_ns,
        .render_callback_ns = render_ns,
        .task_executor_ns = task_ns,
        .host_other_ns = duration_ns -| measured_ns,
        .alloc_bytes = alloc_meter.alloc_bytes,
        .alloc_calls = alloc_meter.alloc_calls,
        .free_bytes = alloc_meter.free_bytes,
        .free_calls = alloc_meter.free_calls,
        .live_bytes = alloc_meter.live_bytes,
        .peak_live_bytes = alloc_meter.peak_live_bytes,
        .update_alloc_bytes = alloc_meter.update_bytes,
        .update_alloc_calls = alloc_meter.update_calls,
        .task_events = observatory_cycle_counts.task,
        .effect_calls = observatory_cycle_counts.effect,
        .draw_calls = observatory_draw_calls,
        .resource_events = observatory_cycle_counts.resource,
        .queue_events = observatory_cycle_counts.queue,
    });
    _ = session.flushGaps(cycle, traceNowNs());
    if (session.failed() and !observatory_failure_reported) {
        observatory_failure_reported = true;
        std.log.err("RocRay Observatory writer failed; recording stopped and the application will continue", .{});
    } else if (session.outputLimited() and !observatory_failure_reported) {
        observatory_failure_reported = true;
        std.log.err("RocRay Observatory reached its output limit; the application will continue", .{});
    }
}

/// Records automatic application callback time separately from hosted-effect
/// time. Cycles already summarize update!, render!, and task-pump duration;
/// init! has no enclosing host cycle, so it always receives its own row.
fn recordObservatoryCallback(
    phase: observatory.CallbackPhase,
    cycle: u64,
    started_ns: i96,
    duration_ns: u64,
    outcome: observatory.CallbackOutcome,
    name: []const u8,
) void {
    const session = active_observatory orelse return;
    _ = session.recordCallback(.{
        .cycle = cycle,
        .timestamp_ns = @intCast(@max(started_ns - observatory_origin_ns, 0)),
        .kind = @intFromEnum(phase),
        .duration_ns = duration_ns,
        .value_a = @intFromEnum(outcome),
        .name = name,
    });
}

fn recordObservatoryDrawSummary(presented: bool, render_ns: u64) void {
    const session = active_observatory orelse return;
    _ = session.recordDraw(.{
        .cycle = observatory_cycle,
        .timestamp_ns = traceNowNs(),
        .kind = 0,
        .duration_ns = render_ns,
        .value_a = observatory_draw_calls,
        .value_b = @intFromBool(presented),
        .name = "public_draw_effects",
    });
    _ = session.recordGpu(.{
        .cycle = observatory_cycle,
        .timestamp_ns = traceNowNs(),
        .kind = 1,
        // Host callback time only. This is deliberately not called GPU time.
        .duration_ns = render_ns,
        .value_a = @intFromBool(presented),
        .name = if (presented) "presentation_completed" else "presentation_not_completed",
    });
}

const BackendTimingFact = struct { kind: u8, duration: u64, name: []const u8 };

fn backendTimingFacts(timing: BackendFrameTiming, headless: bool) [4]BackendTimingFact {
    return if (headless)
        [_]BackendTimingFact{
            .{ .kind = 4, .duration = timing.render_callback_ns, .name = "render_callback" },
            .{ .kind = 5, .duration = 0, .name = "begin_drawing_unavailable_headless" },
            .{ .kind = 6, .duration = 0, .name = "host_draw_submission_omitted_headless" },
            .{ .kind = 7, .duration = 0, .name = "presentation_and_pacing_unavailable_headless" },
        }
    else
        [_]BackendTimingFact{
            .{ .kind = 4, .duration = timing.render_callback_ns, .name = "render_callback" },
            .{ .kind = 5, .duration = timing.begin_drawing_ns, .name = "begin_drawing" },
            .{ .kind = 6, .duration = timing.host_submission_ns, .name = "host_draw_submission" },
            .{ .kind = 7, .duration = timing.end_drawing_ns, .name = "end_drawing_including_presentation_and_pacing" },
        };
}

fn recordObservatoryBackendTiming(timing: BackendFrameTiming, headless: bool) void {
    const session = active_observatory orelse return;
    const facts = backendTimingFacts(timing, headless);
    for (facts) |fact| _ = session.recordGpu(.{
        .cycle = observatory_cycle,
        .timestamp_ns = traceNowNs(),
        .kind = fact.kind,
        .duration_ns = fact.duration,
        .name = fact.name,
    });
}

test "backend phase facts never split opaque presentation from pacing" {
    const timing = BackendFrameTiming{ .render_callback_ns = 1, .begin_drawing_ns = 2, .host_submission_ns = 3, .end_drawing_ns = 4 };
    const native = backendTimingFacts(timing, false);
    try std.testing.expectEqual(@as(u64, 1), native[0].duration);
    try std.testing.expectEqual(@as(u64, 4), native[3].duration);
    try std.testing.expectEqualStrings("end_drawing_including_presentation_and_pacing", native[3].name);
    const headless = backendTimingFacts(timing, true);
    try std.testing.expectEqual(@as(u64, 1), headless[0].duration);
    try std.testing.expectEqual(@as(u64, 0), headless[1].duration);
    try std.testing.expectEqual(@as(u64, 0), headless[2].duration);
    try std.testing.expectEqual(@as(u64, 0), headless[3].duration);
    try std.testing.expectEqualStrings("presentation_and_pacing_unavailable_headless", headless[3].name);
}

fn observatoryBackendName(headless: bool) []const u8 {
    return if (headless) "headless_stub" else "raylib_native";
}

fn observatoryTargetProfile(headless: bool) []const u8 {
    return if (headless) "native-headless" else "native-graphical";
}

fn observatoryPacingName(vsync: bool, target_fps: i32) []const u8 {
    if (vsync) return "vsync_requested";
    if (target_fps > 0) return "host_fps_cap";
    return "uncapped";
}

fn recordObservatoryBackendFacts(app_config: AppConfig, headless: bool) void {
    const session = active_observatory orelse return;
    _ = session.recordGpu(.{
        .cycle = 0,
        .timestamp_ns = traceNowNs(),
        .kind = 0,
        .value_a = @intFromBool(headless),
        .name = observatoryBackendName(headless),
    });
    _ = session.recordGpu(.{
        .cycle = 0,
        .timestamp_ns = traceNowNs(),
        .kind = 2,
        .value_a = @intFromBool(app_config.vsync),
        .value_b = @intCast(@max(app_config.target_fps, 0)),
        .name = observatoryPacingName(app_config.vsync, app_config.target_fps),
    });
    _ = session.recordGpu(.{
        .cycle = 0,
        .timestamp_ns = traceNowNs(),
        .kind = 3,
        .name = if (headless) "gpu_timing_unavailable_headless" else "gpu_timing_unavailable_raylib_no_nonstalling_query",
    });
}

test "backend facts distinguish native headless and honest pacing profiles" {
    try std.testing.expectEqualStrings("native-graphical", observatoryTargetProfile(false));
    try std.testing.expectEqualStrings("native-headless", observatoryTargetProfile(true));
    try std.testing.expectEqualStrings("raylib_native", observatoryBackendName(false));
    try std.testing.expectEqualStrings("headless_stub", observatoryBackendName(true));
    try std.testing.expectEqualStrings("vsync_requested", observatoryPacingName(true, 60));
    try std.testing.expectEqualStrings("host_fps_cap", observatoryPacingName(false, 60));
    try std.testing.expectEqualStrings("uncapped", observatoryPacingName(false, 0));
}

fn recordStructuralLatency(kind: u8, subject_id: u64, parent_id: u64, started_ns: u64, name: []const u8) void {
    const session = active_observatory orelse return;
    if (!observatory_task_detail) return;
    const now = traceNowNs();
    _ = session.recordLatency(.{
        .cycle = observatory_cycle,
        .timestamp_ns = now,
        .kind = kind,
        .subject_id = subject_id,
        .parent_id = parent_id,
        .duration_ns = now -| started_ns,
        .name = name,
    });
}

fn recordAllocationEvent(kind: u8, id: u64, bytes: usize, prior_bytes: usize) void {
    const session = active_observatory orelse return;
    if (!observatory_full_detail) return;
    _ = session.recordAllocation(.{
        .cycle = observatory_cycle,
        .timestamp_ns = traceNowNs(),
        .kind = kind | (@as(u8, @intFromEnum(active_phase)) << 4),
        .subject_id = id,
        .parent_id = AppTasks.executingTaskId(),
        .duration_ns = activeTraceZoneToken(),
        .value_a = bytes,
        .value_b = prior_bytes,
        .name = switch (kind) {
            0 => "alloc",
            1 => "free",
            2 => "realloc_move",
            else => "realloc_in_place",
        },
    });
}

fn allocationAllocated(pointer: usize, bytes: usize) void {
    if (!observatory_full_detail) return;
    const moving = allocation_realloc_id != 0;
    const id = if (moving) allocation_realloc_id else observatory_next_allocation_id;
    if (!moving) observatory_next_allocation_id +|= 1;
    allocation_realloc_in_place = moving and pointer == allocation_realloc_old_pointer;
    if (!allocation_identities.put(pointer, id, bytes)) {
        if (active_observatory) |session| session.noteLoss(.allocation_lifecycle, 1);
        return;
    }
    recordAllocationEvent(if (!moving) 0 else if (allocation_realloc_in_place) 3 else 2, id, bytes, if (moving) allocation_realloc_old_bytes else 0);
}

fn allocationFreed(pointer: usize, bytes: usize) void {
    if (!observatory_full_detail) return;
    if (allocation_realloc_in_place and allocation_realloc_old_pointer == pointer) return;
    const identity = allocation_identities.take(pointer) orelse return;
    if (allocation_realloc_id == identity.id and allocation_realloc_old_pointer == pointer) return;
    recordAllocationEvent(1, identity.id, bytes, identity.bytes);
}

fn runNormalApp(roc_host: *RocHost, allocator: std.mem.Allocator, app_config: AppConfig, options: RuntimeOptions) c_int {
    beginAppLifetime();
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
        app_config.visible and !options.hidden,
    ));
    raylib.initWindow(
        positiveCInt(app_config.width, 800),
        positiveCInt(app_config.height, 600),
        window_title.ptr,
    );
    defer raylib.closeWindow();
    // Chained behind raylib's own callbacks, so it needs the window too. Every
    // key, button, wheel and character event between two polls is recorded
    // from here on; without the hook the host would be back to comparing two
    // levels, which loses whatever happened in between.
    if (!raylib.installInputEventCallbacks()) {
        std.log.warn("no GLFW window to record input events on; edges fall back to level sampling", .{});
    }
    // Both of these need a live window: InitWindow zeroes raylib's CORE state
    // and writes exitKey = KEY_ESCAPE, so an earlier SetExitKey is discarded,
    // and SetWindowMinSize needs the window handle.
    raylib.suggestWindowMinSize(
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

    // A read parks its own coroutine on the event loop, so there is no worker
    // thread to start. What is left of the lifetime is the byte-list delivery
    // reservations, cleared before capture and resource teardown can touch the
    // buffers they bound.
    defer file_bytes_delivery_reservations.clearAfterWorkStops();
    defer cmd_effect.clearAfterWorkStops();

    var app_tasks = AppTasks.init(allocator, hostGetEnv(TRACE_TASKS_ENV) != null) catch |err| {
        std.log.err("roc-ray: could not start the task runtime: {s}", .{@errorName(err)});
        return 1;
    };
    defer app_tasks.deinit();
    if (active_observatory) |session| {
        app_tasks.setObserver(taskObserver(session));
    }
    // Registered after the registry's own teardown, so LIFO runs it first:
    // a task parked in `Cmd.run!` cannot be cancelled out of a child it is
    // waiting on, so every child is ended before the runtime tries to join
    // the worker holding one.
    defer cmd_effect.killLiveChildren();
    app_tasks.activate();
    // `Http.send!` drives std.http.Client over the same runtime, so it needs
    // the same handle the task registry holds. Withdrawn before the registry
    // tears the runtime down, so a late send reports a stopped app instead of
    // reaching a dead event loop.
    if (app_tasks.rt) |rt| http_effect.activate(rt, hostGetEnv(TRACE_TASKS_ENV) != null);
    defer http_effect.deactivate();

    const init_started_ns = observatoryMeasurementStart();
    const init_result = initModel();
    const init_duration_ns = observatoryMeasurementElapsed(init_started_ns);
    recordObservatoryCallback(
        .init,
        0,
        init_started_ns,
        init_duration_ns,
        if (init_result.isErr()) .application_error else .success,
        "init!",
    );
    if (init_result.isErr()) {
        const err_code = init_result.getErr();
        if (TRACE_HOST) std.log.debug("[HOST] init returned Err({d})", .{err_code});
        return initExitCode(err_code);
    }

    var boxed_model = init_result.getOk();
    var exit_code: i32 = 0;
    var cycle_count: u64 = 0;

    // Outlives the cycle: a task that finishes while `update!` is running
    // answers on the next input, so its message waits here in between.
    var staging = TaskResultStaging{};
    defer staging.release(roc_host);

    reportStartupAllocStats();
    while (!raylib.windowShouldClose()) {
        observatory_cycle = cycle_count;
        observatory_draw_calls = 0;
        observatory_cycle_counts = .{};
        const structural_input_id = observatory_next_input_id;
        observatory_current_input_id = structural_input_id;
        observatory_next_input_id +|= 1;
        const structural_input_ns = traceNowNs();
        const stats_cycle_start = observatoryMeasurementStart();
        var stats_task_ns: u64 = 0;
        var stats_update_ns: u64 = 0;
        var stats_render_ns: u64 = 0;
        app_tasks.pump(cycle_count, .yield);
        stats_task_ns +|= app_tasks.last_pump_ns;
        stageTaskResults(&app_tasks, &staging, roc_host);
        const callbacks = CycleCallbackSchedule.forInput(true);
        std.debug.assert(callbacks.updates == 1);
        // Sample raylib's monotonic clock (seconds since window init) at the
        // start of the frame and expose it as nanoseconds. frame_time is
        // raylib's own delta, forced to 0 on the first frame -- unless a
        // fixed-step recording is running, which substitutes an exact delta so
        // the captured animation is smooth and reproducible.
        const real_ns: u64 = @intFromFloat(raylib.getTime() * 1_000_000_000.0);
        const fixed_step = capture_session.fixedStepSeconds();
        const frame_time: f32 = if (cycle_count == 0) 0 else (fixed_step orelse raylib.getFrameTime());
        const now_ns: u64 = captureAdjustedClock(real_ns, fixed_step);
        updateMusicStreams();

        applyInputScripts(options, cycle_count);
        // Text is taken first, and either way: a scripted frame that left the
        // hardware characters behind would deliver them on the next one, and
        // which source the text came from decides whose text events the cycle
        // takes below.
        const typed_text = raylib.takeTextInput();
        const scripted_text = takeVirtualText();
        const text_input = scripted_text orelse typed_text;
        input.updateFromRaylib(if (scripted_text != null) .virtual else .hardware);
        const mouse_pos = if (virtual_mouse_active)
            raylib.Vec2{ .x = virtual_mouse_x, .y = virtual_mouse_y }
        else
            raylib.getMousePosition();
        const mouse_delta = if (virtual_mouse_active) virtualMouseDelta() else raylib.getMouseDelta();
        // Taken either way: notches turned while the pointer was scripted
        // would otherwise land on the cycle the app hands it back.
        const hardware_wheel = raylib.takeMouseWheelMove();
        const mouse_wheel = if (virtual_mouse_active)
            raylib.Vec2{ .x = 0, .y = virtual_mouse_wheel }
        else
            hardware_wheel;
        if (virtual_mouse_active) {
            recordVirtualMousePosition();
            // A real wheel reports movement for one interval and then returns
            // to zero, so consume the scripted value rather than reporting it
            // again on every subsequent frame.
            virtual_mouse_wheel = 0;
        }
        const input_snapshot = input.hostState(
            mouse_pos.x,
            mouse_pos.y,
            mouse_delta,
            mouse_wheel,
            text_input,
        );
        if (input_snapshot.text_input_overflow and !raylib.recordedTextPressureAvailable()) recordInputOverflow("text input overflow", input_snapshot.text_input.len());
        // raylib owns the dropped paths only until they are released, so they
        // are copied into Roc strings first and handed back immediately. The
        // pointer position is this cycle's, which is where the drop landed.
        const dropped_paths = raylib.takeDroppedFiles();
        const dropped = droppedFilesSnapshot(roc_host, dropped_paths, .{ .x = mouse_pos.x, .y = mouse_pos.y });
        if (dropped.overflowed) recordInputOverflow("dropped files overflow", dropped.files.len());
        raylib.releaseDroppedFiles();

        last_frame_nanos = now_ns;
        last_wall_nanos = real_ns;
        // One call, before the drawing scope opens. `update!` changes host
        // state directly and spawns tasks while it runs; drawing is refused by
        // the phase guard.
        const stats_update_start = observatoryMeasurementStart();
        recordStructuralLatency(0, structural_input_id, 0, structural_input_ns, "input_to_update");
        const update_result = updateOnce(&boxed_model, .{
            .devices = input_snapshot,
            .window = windowState(),
            .time = .{
                .cycle_count = cycle_count,
                .simulation_nanos = now_ns,
                .monotonic_nanos = real_ns,
                .elapsed_seconds = frame_time,
            },
            .task_results = staging.take(roc_host),
            .capture = captureStateForStep(),
            .dropped = dropped.files,
            .dropped_overflow = dropped.overflowed,
        });
        stats_update_ns = observatoryMeasurementElapsed(stats_update_start);
        recordObservatoryCallback(
            .update,
            cycle_count,
            stats_update_start,
            stats_update_ns,
            if (update_result.tag == .Err) .application_error else .success,
            "update!",
        );
        if (update_result.tag == .Err) {
            exit_code = @intCast(update_result.payload_err());
            if (TRACE_HOST) std.log.debug("[HOST] update returned Err({d})", .{exit_code});
            recordObservatoryCycle(cycle_count, stats_cycle_start, stats_update_ns, stats_render_ns, stats_task_ns);
            recordObservatoryDrawSummary(false, 0);
            break;
        }
        boxed_model = update_result.payload_ok();
        // Newly spawned tasks run to their first park before the frame is
        // drawn, so their waiting overlaps rendering.
        app_tasks.pump(cycle_count, .yield);
        stats_task_ns +|= app_tasks.last_pump_ns;

        // This graphical backend schedules one optional presentation for every
        // cycle. A backend that omits it still calls update once for the fresh
        // input above; presentation is not another transition.
        if (callbacks.presentations == 1) {
            const render_result = renderFrame(takeModelForRender(&boxed_model));
            stats_render_ns = observatory_backend_timing.render_callback_ns;
            recordObservatoryCallback(
                .render,
                cycle_count,
                observatory_backend_timing.render_callback_started_ns,
                stats_render_ns,
                if (render_result.isErr()) .application_error else .success,
                "render!",
            );
            recordObservatoryBackendTiming(observatory_backend_timing, false);
            if (render_result.isErr()) {
                exit_code = @intCast(render_result.getErr());
                if (TRACE_HOST) std.log.debug("[HOST] render returned Err({d})", .{exit_code});
                recordObservatoryDrawSummary(false, stats_render_ns);
                recordObservatoryCycle(cycle_count, stats_cycle_start, stats_update_ns, stats_render_ns, stats_task_ns);
                break;
            }
            boxed_model = render_result.getOk();
            recordStructuralLatency(1, structural_input_id, 0, structural_input_ns, "input_to_end_drawing_including_pacing");
        }
        drainRetiredResources();
        recordObservatoryDrawSummary(callbacks.presentations == 1, stats_render_ns);
        recordObservatoryCycle(cycle_count, stats_cycle_start, stats_update_ns, stats_render_ns, stats_task_ns);
        reportCycleAllocStats(cycle_count);
        cycle_count += 1;

        if (exit_requested) |code| {
            exit_code = @intCast(code);
            break;
        }

        // A bounded unattended run ends itself once it has presented the
        // frames it was asked for, exactly as if the window had been closed.
        if (options.frames) |limit| {
            if (cycle_count >= limit) break;
        }
    }

    dropFinalModel(boxed_model);
    return finalExitCode(exit_code);
}

fn runHeadlessApp(roc_host: *RocHost, app_config: AppConfig, frames: u64) c_int {
    beginAppLifetime();
    resetHeadlessRuntime(app_config);
    defer deinitResources();
    // A failed or early-exiting run must not poison the next app lifetime.
    defer file_bytes_delivery_reservations.clearAfterWorkStops();
    defer cmd_effect.clearAfterWorkStops();

    var input = InputState.init(roc_host);
    defer input.deinit();

    var app_tasks = AppTasks.init(allocatorFromHost(roc_host), hostGetEnv(TRACE_TASKS_ENV) != null) catch |err| {
        std.log.err("roc-ray: could not start the task runtime: {s}", .{@errorName(err)});
        return 1;
    };
    defer app_tasks.deinit();
    if (active_observatory) |session| {
        app_tasks.setObserver(taskObserver(session));
    }
    // Registered after the registry's own teardown, so LIFO runs it first:
    // a task parked in `Cmd.run!` cannot be cancelled out of a child it is
    // waiting on, so every child is ended before the runtime tries to join
    // the worker holding one.
    defer cmd_effect.killLiveChildren();
    app_tasks.activate();
    // `Http.send!` drives std.http.Client over the same runtime, so it needs
    // the same handle the task registry holds. Withdrawn before the registry
    // tears the runtime down, so a late send reports a stopped app instead of
    // reaching a dead event loop.
    if (app_tasks.rt) |rt| http_effect.activate(rt, hostGetEnv(TRACE_TASKS_ENV) != null);
    defer http_effect.deactivate();

    const init_started_ns = observatoryMeasurementStart();
    const init_result = initModel();
    const init_duration_ns = observatoryMeasurementElapsed(init_started_ns);
    recordObservatoryCallback(
        .init,
        0,
        init_started_ns,
        init_duration_ns,
        if (init_result.isErr()) .application_error else .success,
        "init!",
    );
    if (init_result.isErr()) {
        const err_code = init_result.getErr();
        if (TRACE_HOST) std.log.debug("[HOST] init returned Err({d})", .{err_code});
        return initExitCode(err_code);
    }

    var boxed_model = init_result.getOk();
    var exit_code: i32 = 0;
    var cycle_count: u64 = 0;

    // Outlives the cycle: a task that finishes while `update!` is running
    // answers on the next input, so its message waits here in between.
    var staging = TaskResultStaging{};
    defer staging.release(roc_host);

    reportStartupAllocStats();
    while (cycle_count < frames) : (cycle_count += 1) {
        observatory_cycle = cycle_count;
        observatory_draw_calls = 0;
        observatory_cycle_counts = .{};
        const structural_input_id = observatory_next_input_id;
        observatory_current_input_id = structural_input_id;
        observatory_next_input_id +|= 1;
        const structural_input_ns = traceNowNs();
        const stats_cycle_start = observatoryMeasurementStart();
        var stats_task_ns: u64 = 0;
        var stats_update_ns: u64 = 0;
        var stats_render_ns: u64 = 0;
        // A headless run has no frame pacing and no real clock, but task
        // timers are real time. While a task is live, pace the cycle to the
        // simulated 60 Hz so "18 cycles later" means what it means windowed.
        app_tasks.pump(cycle_count, if (app_tasks.liveCount() != 0) .{ .sleep_ns = HEADLESS_FRAME_NANOS } else .yield);
        stats_task_ns +|= app_tasks.last_pump_ns;
        stageTaskResults(&app_tasks, &staging, roc_host);
        const callbacks = CycleCallbackSchedule.forInput(true);
        std.debug.assert(callbacks.updates == 1);
        const frame_time: f32 = if (cycle_count == 0) 0 else HEADLESS_FRAME_TIME;
        const timestamp_nanos = cycle_count * HEADLESS_FRAME_NANOS;
        const scripted_text = takeVirtualText();
        const text_input = scripted_text orelse raylib.TextInput{ .codepoints = &.{}, .overflowed = false };
        input.updateHeadless(if (scripted_text != null) .virtual else .hardware);
        // A headless run has no pointer, so a scripted one is the only pointer
        // there is. Everything a windowed run derives from it -- position,
        // delta, the wheel's single frame of movement -- is derived here the
        // same way, and stays at the origin when nothing is scripted.
        const mouse_pos = if (virtual_mouse_active)
            raylib.Vec2{ .x = virtual_mouse_x, .y = virtual_mouse_y }
        else
            raylib.Vec2{ .x = 0, .y = 0 };
        const mouse_delta = if (virtual_mouse_active) virtualMouseDelta() else raylib.Vec2{ .x = 0, .y = 0 };
        const mouse_wheel = raylib.Vec2{ .x = 0, .y = virtual_mouse_wheel };
        if (virtual_mouse_active) {
            recordVirtualMousePosition();
            virtual_mouse_wheel = 0;
        }
        const input_snapshot = input.hostState(
            mouse_pos.x,
            mouse_pos.y,
            mouse_delta,
            mouse_wheel,
            text_input,
        );
        if (input_snapshot.text_input_overflow) recordInputOverflow("text input overflow", input_snapshot.text_input.len());

        last_frame_nanos = timestamp_nanos;
        // A headless run has no real clock to expose: it exists to produce the
        // same output twice, and a wall clock would be the one thing in the
        // input that differed between runs.
        last_wall_nanos = timestamp_nanos;
        // One call, before the drawing scope opens. `update!` changes host
        // state directly and spawns tasks while it runs; drawing is refused by
        // the phase guard.
        const stats_update_start = observatoryMeasurementStart();
        recordStructuralLatency(0, structural_input_id, 0, structural_input_ns, "input_to_update");
        const update_result = updateOnce(&boxed_model, .{
            .devices = input_snapshot,
            .window = windowState(),
            .time = .{
                .cycle_count = cycle_count,
                .simulation_nanos = timestamp_nanos,
                .monotonic_nanos = timestamp_nanos,
                .elapsed_seconds = frame_time,
            },
            .task_results = staging.take(roc_host),
            .capture = captureStateForStep(),
            // A headless run has no window to drop a file onto, and its output
            // has to be reproducible, so nothing is ever dropped there.
            .dropped = abi.RocList(DroppedFile).empty(),
            .dropped_overflow = false,
        });
        stats_update_ns = observatoryMeasurementElapsed(stats_update_start);
        recordObservatoryCallback(
            .update,
            cycle_count,
            stats_update_start,
            stats_update_ns,
            if (update_result.tag == .Err) .application_error else .success,
            "update!",
        );
        if (update_result.tag == .Err) {
            exit_code = @intCast(update_result.payload_err());
            if (TRACE_HOST) std.log.debug("[HOST] update returned Err({d})", .{exit_code});
            recordObservatoryCycle(cycle_count, stats_cycle_start, stats_update_ns, stats_render_ns, stats_task_ns);
            recordObservatoryDrawSummary(false, 0);
            break;
        }
        boxed_model = update_result.payload_ok();
        app_tasks.pump(cycle_count, .yield);
        stats_task_ns +|= app_tasks.last_pump_ns;

        // Headless examples run render! to cover semantic render and resource
        // paths, but the stub has no presentation surface.
        if (callbacks.presentations == 1) {
            const render_result = renderFrame(takeModelForRender(&boxed_model));
            stats_render_ns = observatory_backend_timing.render_callback_ns;
            recordObservatoryCallback(
                .render,
                cycle_count,
                observatory_backend_timing.render_callback_started_ns,
                stats_render_ns,
                if (render_result.isErr()) .application_error else .success,
                "render!",
            );
            recordObservatoryBackendTiming(observatory_backend_timing, true);
            if (render_result.isErr()) {
                exit_code = @intCast(render_result.getErr());
                if (TRACE_HOST) std.log.debug("[HOST] render returned Err({d})", .{exit_code});
                recordObservatoryDrawSummary(false, stats_render_ns);
                recordObservatoryCycle(cycle_count, stats_cycle_start, stats_update_ns, stats_render_ns, stats_task_ns);
                break;
            }
            boxed_model = render_result.getOk();
            // Headless render has no presentation boundary. The per-cycle GPU
            // facts above disclose that omission explicitly.
        }
        drainRetiredResources();
        recordObservatoryDrawSummary(false, stats_render_ns);
        recordObservatoryCycle(cycle_count, stats_cycle_start, stats_update_ns, stats_render_ns, stats_task_ns);
        reportCycleAllocStats(cycle_count);
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
    const options = parseRuntimeOptions(std.heap.smp_allocator, argc, argv) catch {
        printUsage();
        return 2;
    };
    defer options.deinit(std.heap.smp_allocator);
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
    // Metering is opt-in: with ROC_RAY_ALLOC_STATS unset this returns the same
    // allocator, so a normal run has no wrapper and no counters. Everything
    // Roc allocates runs on the frame thread, tasks included, so what is
    // counted here is all of it.
    var roc_env = abi.RocEnv{
        .allocator = meteredAllocator(allocator, options.record_stats),
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
    active_app_args = options.app_args;
    exit_requested = null;
    debug_or_expect_called.store(false, .release);
    defer {
        // No frame loop here to end, so the retirement queue is drained by
        // hand -- and without a frame's budget, since there is no frame to
        // protect and anything left behind reads as a leak.
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
        active_app_args = &.{};
        active_roc_host = null;
    }

    // Standard output and standard error are queued effects: a write copies
    // its payload into a host-owned ring and returns, and one host thread does
    // the blocking writing. Armed before the startup config callback, which is
    // the first Roc code to run, and drained by a `defer` registered here so it
    // outlives the app lifetime and every other teardown. That is what lets an
    // application print and then exit in the same `update!`.
    stdio_effect.activate(allocator, mainThreadIo(), .stdout(), .stderr());
    defer stdio_effect.shutdown();

    // Startup, not idle: reading an environment variable to decide the window
    // size is a reasonable thing for a config to do, and it works today. It is
    // still before `InitWindow`, so a texture load here would fail for its own
    // reasons rather than because the phase guard caught it.
    const config_phase = PhaseScope.enter(.startup);
    var app_config = app_config_for_host();
    config_phase.leave();
    startup_font_config = .{
        .path = app_config.default_font_path.asSlice(),
        .size = app_config.default_font_size,
    };
    defer startup_font_config = .{};
    // The config's Roc strings stay borrowed by startup configuration until
    // the selected host lifetime finishes; `decref` then releases all of them.
    var app_config_released = false;
    defer if (!app_config_released) app_config.decref(&roc_host);

    var stats_recording = startObservatoryIfEnabled(allocator, options) catch |err| {
        std.log.err("Could not start RocRay Observatory recording: {s}", .{@errorName(err)});
        return 1;
    };
    if (stats_recording != null) {
        active_observatory = &stats_recording.?.session;
        observatory_origin_ns = observatoryAwakeNs();
        observatory_failure_reported = false;
        observatory_task_detail = options.stats_detail != .summary;
        observatory_full_detail = options.stats_detail == .full;
        observatory_next_input_id = 1;
        observatory_next_effect_id = 1;
        observatory_current_input_id = 0;
        task_finish_correlations = [_]TaskFinishCorrelation{.{}} ** task_finish_correlation_capacity;
        observatory_next_allocation_id = 1;
        allocation_identities.reset();
        recordObservatoryBackendFacts(app_config, options.headless);
    }
    host_resource.setObserver(if (active_observatory != null) observeHostResource else null);
    defer host_resource.setObserver(null);
    cmd_effect.setQueueObserver(if (active_observatory != null) observeCommandQueue else null);
    defer cmd_effect.setQueueObserver(null);
    still_budget.setObserver(if (active_observatory != null) observeCaptureQueue else null);
    defer still_budget.setObserver(null);
    stdio_effect.setObserver(if (active_observatory != null) observeStdioQueue else null);
    defer stdio_effect.setObserver(null);
    raylib.setInputQueueObserver(if (active_observatory != null) observeInputQueue else null);
    defer raylib.setInputQueueObserver(null);
    const app_exit_code = if (options.headless)
        runHeadlessApp(&roc_host, app_config, options.headless_frames)
    else
        runNormalApp(&roc_host, allocator, app_config, options);

    // Observatory remains active through host-owned teardown. This captures
    // the final Roc releases, deferred native destruction, and stdio queue
    // drain before end-of-stream instead of making an orderly recording look
    // as though those resources remained live at shutdown.
    app_config.decref(&roc_host);
    app_config_released = true;
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    stdio_effect.shutdown();

    if (stats_recording) |*recording| {
        active_observatory = null;
        var outcome_buffer: [32]u8 = undefined;
        const outcome = std.fmt.bufPrint(&outcome_buffer, "exit_code:{d}", .{app_exit_code}) catch "exit_code:unknown";
        recording.session.setApplicationOutcome(outcome);
        const report = recording.session.stop();
        if (report.failed) {
            std.log.err("RocRay Observatory writer failed during final drain; partial recording: {s}", .{recording.path});
        }
        std.debug.print("RocRay Observatory recording: {s} ({s}, drain {d} ns, {d} omitted)\n", .{
            recording.path,
            if (report.complete) "complete" else if (report.output_limited) "output limit" else "incomplete",
            report.drain_duration_ns,
            report.omitted_events,
        });
        allocator.free(recording.path);
        observatory_origin_ns = 0;
        observatory_failure_reported = false;
        observatory_task_detail = false;
        observatory_full_detail = false;
        allocation_identities.reset();
    }
    return app_exit_code;
}

/// Decode one entry of an encoded listing, returning its kind, its name, and
/// where the next entry begins. Test-only mirror of the private transport decoder.
fn testNextEntry(encoded: []const u8, at: usize) ?struct { kind: u8, name: []const u8, next: usize } {
    if (at >= encoded.len) return null;
    const kind = encoded[at];
    const end = std.mem.indexOfScalarPos(u8, encoded, at + 1, 0) orelse return null;
    return .{ .kind = kind, .name = encoded[at + 1 .. end], .next = end + 1 };
}

fn testFindEntry(encoded: []const u8, name: []const u8) ?u8 {
    var at: usize = 0;
    while (testNextEntry(encoded, at)) |entry| : (at = entry.next) {
        if (std.mem.eql(u8, entry.name, name)) return entry.kind;
    }
    return null;
}

test "a listing encodes one kind byte and one NUL-terminated name per entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "alpha.txt", .data = "a" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "beta.txt", .data = "b" });
    try tmp.dir.createDirPath(std.testing.io, "nested");

    var encoded: ?[]u8 = null;
    try std.testing.expectEqual(@as(u8, 0), encodeListingIn(tmp.parent_dir, std.testing.io, std.testing.allocator, &tmp.sub_path, &encoded));
    const bytes = encoded.?;
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqual(DIR_ENTRY_FILE, testFindEntry(bytes, "alpha.txt").?);
    try std.testing.expectEqual(DIR_ENTRY_FILE, testFindEntry(bytes, "beta.txt").?);
    try std.testing.expectEqual(DIR_ENTRY_DIR, testFindEntry(bytes, "nested").?);
    try std.testing.expect(testFindEntry(bytes, "absent") == null);

    // Exactly three entries, and nothing trailing: the decoder stops when the
    // bytes run out rather than on a count it was told.
    var at: usize = 0;
    var seen: usize = 0;
    while (testNextEntry(bytes, at)) |entry| : (at = entry.next) seen += 1;
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expectEqual(bytes.len, at);
}

test "an empty directory lists as no bytes rather than as a failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var encoded: ?[]u8 = null;
    try std.testing.expectEqual(@as(u8, 0), encodeListingIn(tmp.parent_dir, std.testing.io, std.testing.allocator, &tmp.sub_path, &encoded));
    const bytes = encoded.?;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "listing names what went wrong: a missing path and a file are different" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plain.txt", .data = "x" });

    var encoded: ?[]u8 = null;
    try std.testing.expectEqual(
        READ_ERR_NOT_FOUND,
        encodeListingIn(tmp.dir, std.testing.io, std.testing.allocator, "absent", &encoded),
    );
    try std.testing.expect(encoded == null);

    try std.testing.expectEqual(
        READ_ERR_NOT_A_DIRECTORY,
        encodeListingIn(tmp.dir, std.testing.io, std.testing.allocator, "plain.txt", &encoded),
    );
    try std.testing.expect(encoded == null);
}

test "a write creates the directories above it and replaces the whole file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectEqual(
        @as(u8, 0),
        writeFileWaitingIn(tmp.dir, std.testing.io, "saves/slot1/state.json", "the first contents"),
    );
    const first = try tmp.dir.readFileAlloc(std.testing.io, "saves/slot1/state.json", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("the first contents", first);

    // Shorter than what is already there: a whole-file write has to shrink the
    // file rather than leave the tail of the previous contents behind.
    try std.testing.expectEqual(
        @as(u8, 0),
        writeFileWaitingIn(tmp.dir, std.testing.io, "saves/slot1/state.json", "second"),
    );
    const second = try tmp.dir.readFileAlloc(std.testing.io, "saves/slot1/state.json", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("second", second);
}

test "a write whose parent is a file is refused by name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plain.txt", .data = "x" });

    try std.testing.expectEqual(
        READ_ERR_NOT_FOUND,
        writeFileWaitingIn(tmp.dir, std.testing.io, "plain.txt/nested.txt", "x"),
    );
}

test "a write names the failures an app can act on differently" {
    try std.testing.expectEqual(READ_ERR_NOT_FOUND, writeErrorCode(error.FileNotFound));
    try std.testing.expectEqual(READ_ERR_NOT_FOUND, writeErrorCode(error.NotDir));
    try std.testing.expectEqual(WRITE_ERR_PERMISSION_DENIED, writeErrorCode(error.AccessDenied));
    try std.testing.expectEqual(WRITE_ERR_NO_SPACE, writeErrorCode(error.NoSpaceLeft));
    try std.testing.expectEqual(WRITE_ERR_NO_SPACE, writeErrorCode(error.DiskQuota));
    try std.testing.expectEqual(READ_ERR_FAILED, writeErrorCode(error.Unexpected));
}

test "a stat reports what a path is, how big it is, and when it changed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "twelve bytes" });
    try tmp.dir.createDirPath(std.testing.io, "assets");

    const file = statPathIn(tmp.dir, std.testing.io, "notes.txt");
    try std.testing.expectEqual(@as(u8, 0), file.err);
    try std.testing.expectEqual(DIR_ENTRY_FILE, file.kind);
    try std.testing.expectEqual(@as(u64, "twelve bytes".len), file.size_bytes);

    // The modification time is wall-clock, so it is a plausible instant rather
    // than a counter starting at the app's own start. Anything after 2020 is
    // enough to catch a monotonic clock leaking in here by mistake.
    try std.testing.expect(file.modified_seconds > 1_577_836_800);
    try std.testing.expect(file.modified_nanosecond < 1_000_000_000);

    const dir = statPathIn(tmp.dir, std.testing.io, "assets");
    try std.testing.expectEqual(@as(u8, 0), dir.err);
    try std.testing.expectEqual(DIR_ENTRY_DIR, dir.kind);

    // A failed stat answers with the reason and zeroes, so an app cannot read
    // a size or a time out of an answer that has neither.
    const missing = statPathIn(tmp.dir, std.testing.io, "absent.txt");
    try std.testing.expectEqual(READ_ERR_NOT_FOUND, missing.err);
    try std.testing.expectEqual(@as(u64, 0), missing.size_bytes);
    try std.testing.expectEqual(@as(i64, 0), missing.modified_seconds);
}

test "a stat rewrites a modification a hot-reload loop can compare" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "shader.fs", .data = "one" });
    const before = statPathIn(tmp.dir, std.testing.io, "shader.fs");

    // Polling `modified` is the whole hot-reload story, so rewriting the file
    // has to move the instant an app is comparing against.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "shader.fs", .data = "two but longer" });
    const after = statPathIn(tmp.dir, std.testing.io, "shader.fs");

    try std.testing.expect(after.size_bytes > before.size_bytes);
    const moved = after.modified_seconds > before.modified_seconds or
        (after.modified_seconds == before.modified_seconds and after.modified_nanosecond >= before.modified_nanosecond);
    try std.testing.expect(moved);
}

test "a stat names the refusals apart from the failures" {
    try std.testing.expectEqual(READ_ERR_NOT_FOUND, statErrorCode(error.FileNotFound));
    try std.testing.expectEqual(READ_ERR_NOT_FOUND, statErrorCode(error.NotDir));
    try std.testing.expectEqual(WRITE_ERR_PERMISSION_DENIED, statErrorCode(error.AccessDenied));
    try std.testing.expectEqual(READ_ERR_UNAVAILABLE, statErrorCode(error.Canceled));
    try std.testing.expectEqual(READ_ERR_FAILED, statErrorCode(error.Unexpected));

    // A stat follows links, so what an app is told is the kind of the thing at
    // the end of the path and never `sym_link`.
    try std.testing.expectEqual(DIR_ENTRY_FILE, statEntryKind(.file));
    try std.testing.expectEqual(DIR_ENTRY_DIR, statEntryKind(.directory));
    try std.testing.expectEqual(DIR_ENTRY_OTHER, statEntryKind(.named_pipe));
    try std.testing.expectEqual(DIR_ENTRY_OTHER, statEntryKind(.sym_link));
}

test "startup entropy varies, and is refused once the app is running" {
    last_phase_violation = null;
    defer last_phase_violation = null;

    {
        const scope = PhaseScope.enter(.startup);
        defer scope.leave();
        var drawn: [4]u64 = undefined;
        for (&drawn) |*slot| slot.* = hostedEntropy();
        try std.testing.expectEqual(@as(?PhaseViolation, null), last_phase_violation);

        // Four identical draws would mean the host is handing out a constant
        // dressed as entropy, which is exactly the bug this effect exists to
        // fix: a headless run used to reseed from a fixed counter and call the
        // result random.
        var varied = false;
        for (drawn[1..]) |value| {
            if (value != drawn[0]) varied = true;
        }
        try std.testing.expect(varied);
    }

    // Seeding is a startup decision, kept in the model afterwards, so reaching
    // for fresh entropy mid-run is a mistake worth naming.
    const scope = PhaseScope.enter(.update);
    defer scope.leave();
    last_phase_violation = null;
    _ = hostedEntropy();
    const violation = last_phase_violation orelse return error.EntropyWasNotRejected;
    try std.testing.expectEqual(Phase.update, violation.actual);
}

test "a wall-clock reading is normalized on both sides of the epoch" {
    try std.testing.expectEqual(@as(i64, 0), timestampFromNanos(0).seconds);
    try std.testing.expectEqual(@as(u32, 0), timestampFromNanos(0).nanosecond);

    try std.testing.expectEqual(@as(i64, 1), timestampFromNanos(1_500_000_000).seconds);
    try std.testing.expectEqual(@as(u32, 500_000_000), timestampFromNanos(1_500_000_000).nanosecond);

    // One nanosecond before the epoch is the last nanosecond of 1969, not a
    // negative fraction of second zero. Truncating instead of flooring here
    // would make the two sides of 1970 disagree about what a second is.
    try std.testing.expectEqual(@as(i64, -1), timestampFromNanos(-1).seconds);
    try std.testing.expectEqual(@as(u32, 999_999_999), timestampFromNanos(-1).nanosecond);

    // No real clock reaches this, but a reading that cannot be represented
    // saturates rather than wrapping into the middle of history.
    const beyond = @as(i128, std.math.maxInt(i64)) * std.time.ns_per_s + std.time.ns_per_s;
    try std.testing.expectEqual(std.math.maxInt(i64), timestampFromNanos(beyond).seconds);
    try std.testing.expectEqual(std.math.minInt(i64), timestampFromNanos(-beyond).seconds);
}

test "reading the clock is refused while drawing" {
    last_phase_violation = null;
    defer last_phase_violation = null;

    // Not because it costs anything, but because a frame that reads the
    // calendar is a frame animating on a timeline the platform does not pace.
    const scope = PhaseScope.enter(.render);
    defer scope.leave();
    enforcePhase("Time.now!", during_update);
    const violation = last_phase_violation orelse return error.ClockReadWasNotRejected;
    try std.testing.expectEqual(Phase.render, violation.actual);
}

/// A pipe standing in for the process's standard output, so a host test can
/// read back what the writer thread actually wrote. POSIX only; the tests that
/// use it skip elsewhere.
const StdioTestPipe = struct {
    read_end: std.Io.File,
    write_end: std.Io.File,

    fn open() !StdioTestPipe {
        const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
        return .{
            .read_end = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
            .write_end = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
        };
    }

    fn readExactly(self: *StdioTestPipe, out: []u8) !void {
        var filled: usize = 0;
        while (filled < out.len) {
            const got = try std.posix.read(self.read_end.handle, out[filled..]);
            if (got == 0) return error.EndOfStream;
            filled += got;
        }
    }
};

test "a stream payload past the whole queue is refused and still releases the string" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;

    const scope = PhaseScope.enter(.update);
    defer scope.leave();

    const oversized = try std.testing.allocator.alloc(u8, stdio_effect.ring_capacity + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');

    // Larger than the whole queue, so no amount of draining could ever make
    // room: `TooLarge` rather than `BufferFull`, and nothing is queued. The
    // string is still the host's to release -- the testing allocator fails
    // this test if the early return skips it.
    try std.testing.expectEqual(
        stdio_effect.ERR_TOO_LARGE,
        hostedStdioWriteText(&roc_host, STDIO_STREAM_STDOUT, abi.RocStr.fromSlice(oversized, &roc_host)),
    );

    // A line queues the newline with its text, so the longest string a line
    // can carry is one byte shorter than the longest `write!` can.
    try std.testing.expectEqual(
        stdio_effect.ERR_TOO_LARGE,
        hostedStdioWriteLine(&roc_host, STDIO_STREAM_STDOUT, abi.RocStr.fromSlice(oversized[0..stdio_effect.ring_capacity], &roc_host)),
    );
}

test "writing to a stream is queued, so update! is allowed and render! is not" {
    last_phase_violation = null;
    defer last_phase_violation = null;

    // Drawing is the one phase a queued write is refused from: `render!` only
    // draws, and output it produced would not be part of the model that frame
    // came from.
    for ([_]Phase{ .render, .idle }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        last_phase_violation = null;
        enforcePhase("Stdout.line!", during_update);
        const violation = last_phase_violation orelse return error.StreamWriteWasNotRejected;
        try std.testing.expectEqual(phase, violation.actual);
    }

    // The queue is what makes `update!` legal: the call copies and returns,
    // and the writing happens on the host's own thread.
    for ([_]Phase{ .startup, .update, .task }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        last_phase_violation = null;
        enforcePhase("Stdout.line!", during_update);
        try std.testing.expectEqual(@as(?PhaseViolation, null), last_phase_violation);
    }
}

test "a queued write with no drainer running is unavailable" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;

    const scope = PhaseScope.enter(.update);
    defer scope.leave();

    // No app lifetime, so no writer thread. Output that nothing will ever
    // drain is refused rather than accepted and forgotten.
    try std.testing.expectEqual(
        stdio_effect.ERR_UNAVAILABLE,
        hostedStdioWriteLine(&roc_host, STDIO_STREAM_STDOUT, abi.RocStr.fromSlice("nobody home", &roc_host)),
    );
}

test "lines queued from update! reach the stream in order, and shutdown drains the rest" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    roc_host.roc_dealloc = &nativeRocDealloc;

    var pipe = try StdioTestPipe.open();
    defer std.Io.Threaded.closeFd(pipe.read_end.handle);

    stdio_effect.activate(std.testing.allocator, mainThreadIo(), pipe.write_end, pipe.write_end);

    {
        const scope = PhaseScope.enter(.update);
        defer scope.leave();

        var line: usize = 0;
        while (line < 16) : (line += 1) {
            var digits: [8]u8 = undefined;
            const text = std.fmt.bufPrint(&digits, "line {d}", .{line}) catch unreachable;
            try std.testing.expectEqual(
                @as(u8, 0),
                hostedStdioWriteLine(&roc_host, STDIO_STREAM_STDOUT, abi.RocStr.fromSlice(text, &roc_host)),
            );
        }

        // Bytes go out as they are: no newline, no encoding check.
        const raw = [_]u8{ 'r', 'a', 'w', '\n' };
        try std.testing.expectEqual(
            @as(u8, 0),
            hostedStdioWriteBytes(&roc_host, STDIO_STREAM_STDOUT, abi.RocListWith(u8, false).fromSlice(&raw, &roc_host)),
        );
    }

    // The app is over with output still queued -- the "print, then exit in the
    // same update!" case. Shutdown is what gets it out of the process.
    stdio_effect.shutdown();
    std.Io.Threaded.closeFd(pipe.write_end.handle);

    var expected: std.ArrayListUnmanaged(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    var line: usize = 0;
    while (line < 16) : (line += 1) {
        try expected.print(std.testing.allocator, "line {d}\n", .{line});
    }
    try expected.appendSlice(std.testing.allocator, "raw\n");

    const seen = try std.testing.allocator.alloc(u8, expected.items.len);
    defer std.testing.allocator.free(seen);
    try pipe.readExactly(seen);
    try std.testing.expectEqualStrings(expected.items, seen);
}

test "a directory past the entry cap is refused rather than allocated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One past the cap, so the refusal is the cap and not the loop ending.
    var made: usize = 0;
    while (made <= MAX_DIR_ENTRIES) : (made += 1) {
        var name: [24]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&name, "{d}", .{made}) catch unreachable;
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = "" });
    }

    var encoded: ?[]u8 = null;
    try std.testing.expectEqual(
        READ_ERR_TOO_LARGE,
        encodeListingIn(tmp.parent_dir, std.testing.io, std.testing.allocator, &tmp.sub_path, &encoded),
    );
    try std.testing.expect(encoded == null);
}

/// Put a known framebuffer in place of the one a frame loop would have taken.
///
/// The snapshot is what a `Screen` readback reads, and a unit test has no
/// graphics context to fill it, so these tests install one directly. Every
/// pixel encodes its own coordinates, so a transposed or flipped read cannot
/// look right by accident.
fn installTestScreenSnapshot(width: u32, height: u32) !void {
    const pixels = try std.testing.allocator.alloc(u8, width * height * 4);
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * width + x) * 4;
            pixels[offset] = @intCast(x);
            pixels[offset + 1] = @intCast(y);
            pixels[offset + 2] = 7;
            pixels[offset + 3] = 255;
        }
    }
    releaseScreenSnapshot();
    screen_snapshot = .{
        .allocator = std.testing.allocator,
        .pixels = pixels,
        .width = width,
        .height = height,
        .reserved = 0,
    };
}

/// A readback source naming the screen. The target field still has to carry a
/// handle, so it carries the same resource-free one `Draw.RenderTexture.stub`
/// does; nothing resolves it.
fn screenReadbackSource() abi.HostABICapture_pixel_atArg0Source {
    return .{ .target = .{ .handle = &invalid_texture_box.payload, .height = 0, .width = 0 }, .screen = true };
}

test "a screen readback answers with the snapshot's own pixels, top-down" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    active_roc_host = &roc_host;
    const phase = PhaseScope.enter(.update);
    defer {
        phase.leave();
        releaseScreenSnapshot();
        screen_snapshot_requested = false;
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_roc_host = null;
    }

    try installTestScreenSnapshot(4, 3);

    const read = hostedCapturePixelAt(&roc_host, .{ .source = screenReadbackSource(), .x = 2, .y = 1 });
    try std.testing.expectEqual(capture.err_none, read.err);
    try std.testing.expectEqual(@as(u8, 2), read.r);
    try std.testing.expectEqual(@as(u8, 1), read.g);
    try std.testing.expectEqual(@as(u8, 7), read.b);
    try std.testing.expectEqual(@as(u8, 255), read.a);

    // The region and the point agree at the same coordinates, and the bytes
    // come back row-major from the topmost requested row.
    const region = hostedCaptureReadRegion(&roc_host, .{
        .source = screenReadbackSource(),
        .x = 1,
        .y = 1,
        .width = 2,
        .height = 2,
    });
    try std.testing.expectEqual(capture.err_none, region.err);
    try std.testing.expectEqualSlices(u8, &.{
        1, 1, 7, 255, 2, 1, 7, 255,
        1, 2, 7, 255, 2, 2, 7, 255,
    }, region.bytes.items());

    // The payload is handed over rather than copied, so it occupies a delivery
    // slot until the app drops it -- and releases the reservation either way.
    try std.testing.expect(region.bytes.isSeamlessSlice());
    try std.testing.expectEqual(@as(usize, 1), file_bytes_heap.active());
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);

    region.bytes.decref(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
}

test "a readback outside its source is refused rather than clamped" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    active_roc_host = &roc_host;
    const phase = PhaseScope.enter(.update);
    defer {
        phase.leave();
        releaseScreenSnapshot();
        screen_snapshot_requested = false;
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_roc_host = null;
    }

    try installTestScreenSnapshot(4, 3);

    // Clamping would hand back a plausible colour from the wrong pixel, which
    // is precisely what a colour picker must not be given.
    for ([_][2]i32{ .{ 4, 0 }, .{ 0, 3 }, .{ -1, 0 }, .{ 0, -1 } }) |point| {
        const read = hostedCapturePixelAt(&roc_host, .{
            .source = screenReadbackSource(),
            .x = point[0],
            .y = point[1],
        });
        try std.testing.expectEqual(capture.err_region_out_of_bounds, read.err);
        try std.testing.expectEqual(@as(u8, 0), read.a);
    }

    for ([_]capture.Region{
        .{ .x = 1, .y = 0, .width = 4, .height = 3 },
        .{ .x = 0, .y = 1, .width = 4, .height = 3 },
        .{ .x = 0, .y = 0, .width = 0, .height = 1 },
        .{ .x = 0, .y = 0, .width = 1, .height = -1 },
    }) |region| {
        const read = hostedCaptureReadRegion(&roc_host, .{
            .source = screenReadbackSource(),
            .x = region.x,
            .y = region.y,
            .width = region.width,
            .height = region.height,
        });
        try std.testing.expectEqual(capture.err_region_out_of_bounds, read.err);
        try std.testing.expectEqual(@as(usize, 0), read.bytes.len());
    }

    // A refused read leaves nothing behind: no delivery reservation, no slot,
    // and no budget.
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
    try std.testing.expectEqual(@as(u64, 0), still_budget.in_flight);
}

test "a region past the readback cap never reaches a source" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    active_roc_host = &roc_host;
    const phase = PhaseScope.enter(.update);
    defer {
        phase.leave();
        releaseScreenSnapshot();
        screen_snapshot_requested = false;
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_roc_host = null;
    }

    // No snapshot at all, so a read that got as far as resolving the source
    // would report `Unavailable`. It must report the cap instead: the size is
    // refused before anything is read, because no later frame lifts it.
    const read = hostedCaptureReadRegion(&roc_host, .{
        .source = screenReadbackSource(),
        .x = 0,
        .y = 0,
        .width = 8192,
        .height = 4097,
    });
    try std.testing.expectEqual(capture.err_region_out_of_bounds, read.err);
    try std.testing.expectEqual(@as(usize, 0), read.bytes.len());
    try std.testing.expect(!screen_snapshot_requested);
}

test "a screen readback with no presented frame is unavailable and arms the next one" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    active_roc_host = &roc_host;
    const phase = PhaseScope.enter(.startup);
    defer {
        phase.leave();
        releaseScreenSnapshot();
        screen_snapshot_requested = false;
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_roc_host = null;
    }

    screen_snapshot_requested = false;

    // `init!` runs before the frame loop has presented anything, and so does
    // the first `update!`. There is no colour to invent, and the ask is what
    // makes the following frame keep one.
    const read = hostedCapturePixelAt(&roc_host, .{ .source = screenReadbackSource(), .x = 0, .y = 0 });
    try std.testing.expectEqual(capture.err_unavailable, read.err);
    try std.testing.expect(screen_snapshot_requested);

    const region = hostedCaptureReadRegion(&roc_host, .{
        .source = screenReadbackSource(),
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    try std.testing.expectEqual(capture.err_unavailable, region.err);
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);
}

test "a render-target readback reports what the handle resolves to" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    active_roc_host = &roc_host;
    const phase = PhaseScope.enter(.update);
    defer {
        phase.leave();
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_roc_host = null;
    }

    // The `stub` a pure test holds, and a handle of the wrong kind: neither
    // names a live target, and both are runtime data rather than a crash.
    const stubbed = hostedCapturePixelAt(&roc_host, .{
        .source = .{ .target = .{ .handle = &invalid_texture_box.payload, .height = 0, .width = 0 }, .screen = false },
        .x = 0,
        .y = 0,
    });
    try std.testing.expectEqual(capture.err_target_unavailable, stubbed.err);

    // A headless target holds nothing: every draw into it was a no-op, so
    // there is no pixel to report, exactly as there is no file to export.
    const target = storeRenderTexture(.headless).?;
    const headless = hostedCapturePixelAt(&roc_host, .{
        .source = .{ .target = .{ .handle = target, .height = 8, .width = 16 }, .screen = false },
        .x = 0,
        .y = 0,
    });
    try std.testing.expectEqual(capture.err_unavailable, headless.err);

    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), render_texture_heap.active());
    try std.testing.expectEqual(@as(u64, 0), still_budget.in_flight);
    // The source's reference is consumed on every path, taken or refused.
    try std.testing.expect(!screen_snapshot_requested);
}

test "a full byte-list heap refuses a region read before it reads any pixels" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    active_roc_host = &roc_host;
    const phase = PhaseScope.enter(.update);
    defer {
        phase.leave();
        releaseScreenSnapshot();
        screen_snapshot_requested = false;
        file_bytes_delivery_reservations.clearAfterWorkStops();
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        file_bytes_heap.deinitAll();
        active_roc_host = null;
    }

    try installTestScreenSnapshot(4, 3);
    screen_snapshot_requested = false;

    var held: [MAX_LIVE_FILE_BYTE_LISTS]abi.RocListWith(u8, false) = undefined;
    var filled: usize = 0;
    while (filled < MAX_LIVE_FILE_BYTE_LISTS) : (filled += 1) {
        const owned = try std.testing.allocator.dupe(u8, "held");
        const installed = installReadBytes(std.testing.allocator, owned);
        try std.testing.expectEqual(@as(u8, 0), installed.err);
        held[filled] = installed.bytes;
    }

    // `Busy` rather than a colour: the slot is reserved before the readback,
    // so a read with nowhere to deliver never pays for the pixels. The source
    // is never even resolved, which is what the unasked snapshot shows.
    const refused = hostedCaptureReadRegion(&roc_host, .{
        .source = screenReadbackSource(),
        .x = 0,
        .y = 0,
        .width = 2,
        .height = 2,
    });
    try std.testing.expectEqual(capture.err_busy, refused.err);
    try std.testing.expectEqual(@as(usize, 0), refused.bytes.len());
    try std.testing.expect(!screen_snapshot_requested);
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);

    // A single pixel needs no slot, so the same moment still answers it.
    const point = hostedCapturePixelAt(&roc_host, .{ .source = screenReadbackSource(), .x = 0, .y = 0 });
    try std.testing.expectEqual(capture.err_none, point.err);

    for (held) |item| item.decref(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
}

test "a pixel readback called from render! is rejected" {
    // Drawing is what `render!` is for; a readback is a stall in the middle of
    // a frame, and the pixels it would find are the ones this frame has not
    // finished writing.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    active_roc_host = &roc_host;
    const phase = PhaseScope.enter(.render);
    last_phase_violation = null;
    defer {
        last_phase_violation = null;
        phase.leave();
        screen_snapshot_requested = false;
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_roc_host = null;
    }

    _ = hostedCapturePixelAt(&roc_host, .{ .source = screenReadbackSource(), .x = 0, .y = 0 });
    const point_violation = last_phase_violation orelse return error.OperationWasNotRejected;
    try std.testing.expectEqualStrings("Capture.pixel_at!", point_violation.operation);
    try std.testing.expect(point_violation.allowed.eql(during_update));
    try std.testing.expectEqual(Phase.render, point_violation.actual);

    last_phase_violation = null;
    const region = hostedCaptureReadRegion(&roc_host, .{
        .source = screenReadbackSource(),
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    try std.testing.expectEqual(@as(usize, 0), region.bytes.len());
    const region_violation = last_phase_violation orelse return error.OperationWasNotRejected;
    try std.testing.expectEqualStrings("Capture.read_region!", region_violation.operation);
    try std.testing.expect(region_violation.allowed.eql(during_update));
}
