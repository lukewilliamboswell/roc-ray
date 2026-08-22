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

// `hostedHttpSend` is the only thing that names `http_effect`, and the hosted
// exports are compiled out under `zig test` (see the `!builtin.is_test` gate
// below), so nothing would reference the module and its own tests would never
// be collected. Reference it here instead.
test {
    _ = http_effect;
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
const ReadEnvResult = abi.HostHostRead_envResult;
// get_clipboard_text! returns Try(Str, [Unavailable]) -- the same shape as
// read_env!'s result, generated separately because the error tag differs.
const ClipboardTextResult = abi.HostHostGet_clipboard_textResult;
const ClipboardTextResultTag = abi.HostHostGet_clipboard_textResultTag;
const HostReadFileRawResult = abi.HostHostRead_fileRetRecord;
const TilemapLoadTmxRawResult = abi.TilemapHostLoad_tmxRetRecord;
const AppConfig = abi.App_config_for_host;
// One cycle of observations handed to update. Unions do not cross this
// boundary, so the recording state arrives as a flat record that Roc decodes.
const InputFromHost = abi.Update_for_hostArg1;
const UpdateResult = abi.Update_for_hostResult;
/// One finished task's message, wrapped in the erased thunk Roc calls to
/// unwrap it. The host only moves it; it never calls it.
const TaskResultEnvelope = abi.Update_for_hostArg1TaskResults;
const CaptureFromHost = abi.Update_for_hostArg1Capture;
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
    }

    /// Hand this input's task messages to Roc and empty the staging area.
    ///
    /// The returned list owns its thunks. Staging is cleared without releasing
    /// them, to avoid a double free; a task that finishes afterwards is staged
    /// again and delivered on the next input.
    fn take(self: *TaskResultStaging, roc_host: *RocHost) abi.RocList(TaskResultEnvelope) {
        const list = if (self.count() == 0)
            abi.RocList(TaskResultEnvelope).empty()
        else
            abi.RocList(TaskResultEnvelope).fromSlice(self.items.items, roc_host);
        self.items.clearRetainingCapacity();
        return list;
    }

    /// Release messages staged but never delivered, such as a task that
    /// finished during the frame the app exited on.
    fn release(self: *TaskResultStaging, roc_host: *RocHost) void {
        for (self.items.items) |item| item.decref(roc_host);
        self.items.deinit(allocatorFromHost(roc_host));
        self.items = .empty;
    }
};

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

/// Loading, allocating or generating a resource. Allowed wherever the app
/// changes host state -- `init!`, `update!`, and tasks -- but not during
/// `render!`, where an upload or a decode lands in the middle of a frame.
/// The same set as `during_update`; the separate name records intent.
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
    pub fn enterTaskPhase() void {
        active_phase = .task;
    }
    pub fn leaveTaskPhase() void {
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

/// `Task.spawn!`: hand an erased `() => Msg` closure to the task runtime.
///
/// The closure is owned by this call. It starts on its own coroutine at the
/// next pump, which the frame loop runs right after `update!` returns, so a
/// task spawned this cycle parks on its first wait before the frame is drawn.
fn hostedTaskSpawn(run: abi.RocErasedCallable) callconv(.c) void {
    enforcePhase("Task.spawn!", during_spawn);
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
    for (finished) |item| staging.append(roc_host, item.result);
}

/// The phase a waiting effect must restore when its park returns.
///
/// The phase is saved and cleared across the park: the frame loop runs in
/// between and sets phases of its own, and the task must see `.task` again
/// when it resumes.
const WaitScope = struct {
    resumed: Phase,

    fn enter() WaitScope {
        const scope = WaitScope{ .resumed = active_phase };
        active_phase = .idle;
        return scope;
    }

    fn leave(self: WaitScope) void {
        active_phase = self.resumed;
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
    const scope = WaitScope.enter();
    defer scope.leave();
    AppTasks.tracePark("sleep", millis);
    zio.sleep(.fromMilliseconds(@intCast(millis))) catch |err| switch (err) {
        // Cancelled at shutdown: return at once so the task can run to its end.
        error.Canceled => {},
    };
    AppTasks.traceResume("sleep");
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
    AppTasks.tracePark("read", 0);
    defer AppTasks.traceResume("read");
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
fn hostedFilesReadText(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.FilesHostRead_textRetRecord {
    enforcePhase("Files.read_text!", during_wait);
    defer path_arg.decref(roc_host);

    const allocator = allocatorFromHost(roc_host);
    var err: u8 = READ_ERR_FAILED;
    const bytes = readFileWaiting(allocator, path_arg.asSlice(), MAX_INLINE_READ_BYTES + 1, &err) orelse
        return .{ .err = err, .contents = abi.RocStr.empty() };
    defer allocator.free(bytes);

    if (!std.unicode.utf8ValidateSlice(bytes)) {
        return .{ .err = READ_ERR_NOT_UTF8, .contents = abi.RocStr.empty() };
    }
    return .{ .err = 0, .contents = abi.RocStr.fromSlice(bytes, roc_host) };
}

fn exportedFilesReadText(path_arg: abi.RocStr) callconv(.c) abi.FilesHostRead_textRetRecord {
    return hostedFilesReadText(activeHost(), path_arg);
}

/// `Files.read_bytes!`: read a bounded file without copying its payload.
///
/// The buffer the read filled is the buffer Roc gets: it moves into the typed
/// byte-list heap and out again as an owning seamless `List(U8)`, so a 16 MiB
/// file costs one allocation and no copy. A delivery slot is reserved before
/// any I/O starts, so a full heap answers `Busy` rather than reading a file and
/// discarding it.
fn hostedFilesReadBytes(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.FilesHostRead_bytesRetRecord {
    enforcePhase("Files.read_bytes!", during_wait);
    defer path_arg.decref(roc_host);
    return readByteListWaiting(roc_host, path_arg.asSlice(), .read);
}

fn exportedFilesReadBytes(path_arg: abi.RocStr) callconv(.c) abi.FilesHostRead_bytesRetRecord {
    return hostedFilesReadBytes(activeHost(), path_arg);
}

/// `Files.list!`: one directory's entries, encoded into the same byte list a
/// read delivers and decoded by `Files`.
fn hostedFilesList(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.FilesHostListRetRecord {
    enforcePhase("Files.list!", during_wait);
    defer path_arg.decref(roc_host);
    // Structurally the same record as a byte read's, but a distinct generated
    // type, so copy it across field by field rather than casting.
    const result = readByteListWaiting(roc_host, path_arg.asSlice(), .list);
    return .{ .err = result.err, .bytes = result.bytes };
}

fn exportedFilesList(path_arg: abi.RocStr) callconv(.c) abi.FilesHostListRetRecord {
    return hostedFilesList(activeHost(), path_arg);
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
    AppTasks.tracePark("write", 0);
    defer AppTasks.traceResume("write");
    return writeFileWaitingIn(std.Io.Dir.cwd(), waitingIo(), path, bytes);
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
    defer path_arg.decref(roc_host);
    defer contents_arg.decref(roc_host);
    return writeFileWaiting(path_arg.asSlice(), contents_arg.asSlice());
}

fn exportedFilesWriteText(path_arg: abi.RocStr, contents_arg: abi.RocStr) callconv(.c) u8 {
    return hostedFilesWriteText(activeHost(), path_arg, contents_arg);
}

/// `Files.write_bytes!`: replace a file's contents with the app's bytes.
fn hostedFilesWriteBytes(roc_host: *RocHost, path_arg: abi.RocStr, bytes_arg: abi.RocListWith(u8, false)) callconv(.c) u8 {
    enforcePhase("Files.write_bytes!", during_wait);
    defer path_arg.decref(roc_host);
    defer bytes_arg.decref(roc_host);
    return writeFileWaiting(path_arg.asSlice(), bytes_arg.items());
}

fn exportedFilesWriteBytes(path_arg: abi.RocStr, bytes_arg: abi.RocListWith(u8, false)) callconv(.c) u8 {
    return hostedFilesWriteBytes(activeHost(), path_arg, bytes_arg);
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
        AppTasks.tracePark("screenshot", 0);
        defer AppTasks.traceResume("screenshot");
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

/// Which of the two byte-list producing waits to run. They share everything
/// after the syscall: the same admission, the same ownership transfer, and the
/// same list on the way out.
const ByteListWait = enum { read, list };

fn readByteListWaiting(roc_host: *RocHost, path: []const u8, kind: ByteListWait) abi.FilesHostRead_bytesRetRecord {
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
            AppTasks.tracePark("list", 0);
            defer AppTasks.traceResume("list");
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
fn installReadBytes(allocator: std.mem.Allocator, bytes: []u8) abi.FilesHostRead_bytesRetRecord {
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
    const roc_host = activeHost();
    const resume_phase = active_phase;
    active_phase = .idle;
    defer active_phase = resume_phase;
    return http_effect.send(roc_host, allocatorFromHost(roc_host), request);
}

var active_phase: Phase = .idle;

/// Enter a phase for one call, restoring the prior phase to preserve nesting.
const PhaseScope = struct {
    previous: Phase,

    fn enter(phase: Phase) PhaseScope {
        const scope = PhaseScope{ .previous = active_phase };
        active_phase = phase;
        return scope;
    }

    fn leave(self: PhaseScope) void {
        active_phase = self.previous;
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
    if (allowed.contains(active_phase)) return;
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
var render_target_sizes: [SCOPE_STACK_LIMIT]abi.DrawHostFrame_size = @splat(.{ .height = 0, .width = 0 });
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
    payload: u64 = 0,
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

fn writeU64Token(payload: *u64, token: u64) void {
    payload.* = token;
}

fn readU64Token(payload: *const u64) u64 {
    return payload.*;
}

const SoundHeap = host_resource.HostResourceHeap(u64, SoundResource, 128, 1, writeU64Token, readU64Token, destroySound);
const MusicHeap = host_resource.HostResourceHeap(u64, MusicResource, 16, 2, writeU64Token, readU64Token, destroyMusic);
const FontHeap = host_resource.HostResourceHeap(u64, FontResource, 32, 3, writeU64Token, readU64Token, destroyFont);
const TextureHeap = host_resource.HostResourceHeap(u64, TextureResource, 128, 4, writeU64Token, readU64Token, destroyTexture);
const RenderTextureHeap = host_resource.HostResourceHeap(u64, RenderTextureResource, 32, 5, writeU64Token, readU64Token, destroyRenderTexture);
const ShaderHeap = host_resource.HostResourceHeap(u64, ShaderResource, 32, 6, writeU64Token, readU64Token, destroyShader);
const PreparedTextHeap = host_resource.HostResourceHeap(u64, PreparedTextResource, 256, 7, writeU64Token, readU64Token, destroyPreparedText);
const StoreHeap = host_resource.HostResourceHeap(u64, StoreResource, 16, 9, writeU64Token, readU64Token, destroyStore);

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
const FileBytesHeap = host_resource.HostResourceHeap(u64, FileBytesResource, MAX_LIVE_FILE_BYTE_LISTS, 8, writeU64Token, readU64Token, destroyFileBytes);
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
var texture_heap: TextureHeap = .{};
var render_texture_heap: RenderTextureHeap = .{};
var shader_heap: ShaderHeap = .{};
var prepared_text_heap: PreparedTextHeap = .{};
var store_heap: StoreHeap = .{};

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
    inline for (.{ &sound_heap, &music_heap, &font_heap, &texture_heap, &render_texture_heap, &shader_heap, &prepared_text_heap, &file_bytes_heap, &store_heap }) |heap| {
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

const FontMetric = abi.DrawHostFont_metricsGlyphs;

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
    const result = hostedDrawPrepareTextRaw(&roc_host, .{
        .font = .{ .payload = .{ .loaded_font = font }, .tag = .LoadedFont },
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
    const result = hostedDrawPrepareTextRaw(&roc_host, .{
        .font = .{ .payload = .{ .loaded_font = font_shader }, .tag = .LoadedFont },
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
    const target = hostedDrawLoadRenderTextureRaw(.{ .height = 0, .width = 160 });
    try std.testing.expectEqual(RESOURCE_ERR_FAILED, target.err);
    try std.testing.expectEqual(@as(u64, 0), target.target.handle.*);
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
    hostedAssetsSetTextureFilterRaw(.{ .handle = texture, .height = 2, .width = 2 }, 1);
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

/// The handle a Roc `stub` value carries: a real `Box(0)`.
///
/// Zero is the officialized invalid token -- `decodeToken` rejects it and no
/// heap ever emits it -- so every resource operation this reaches takes its
/// unresolvable-handle branch. The box is a genuine Roc allocation rather than
/// a fake, so the host's decref of it runs the same path it runs at runtime and
/// the testing allocator reports a leak or a double free either way.
fn allocateTestResourceStub(host: *RocHost) *u64 {
    const handle: *u64 = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(u64), @alignOf(u64), false, host)));
    handle.* = 0;
    return handle;
}

fn allocateTestTextureStub(host: *RocHost, width: f32, height: f32) abi.Texture {
    return .{ .handle = allocateTestResourceStub(host), .width = width, .height = height };
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
    try std.testing.expect(nativeTextureForToken(0) == null);

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

        hostedAssetsSetTextureFilterRaw(allocateTestTextureStub(&roc_host, 16, 8), 1);
        hostedAssetsSetTextureWrapRaw(allocateTestTextureStub(&roc_host, 16, 8), 1);

        const whole_err = hostedAssetsUpdateTextureRaw(&roc_host, .{
            .pixels = abi.RocListWith(Color, false).empty(),
            .texture = allocateTestTextureStub(&roc_host, 16, 8),
        });
        try std.testing.expectEqual(TEXTURE_UPDATE_NOT_MUTABLE, whole_err);

        const region_err = hostedAssetsUpdateTextureRegionRaw(&roc_host, .{
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
    // model -- `Draw.Font.stub`, `Draw.Shader.stub`, `Draw.RenderTexture.stub`,
    // `Text.Prepared.stub`, `Assets.Store.stub` -- so that a pure test can write
    // a model down. Each one carries `Box(0)`, and this is the other half of
    // that promise: the host resolves none of them, refuses the operations they
    // reach, and releases the box exactly once.
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

    // Zero resolves nowhere, in any heap. This is the property every stub rests
    // on, and the reason `stub` can be a pure value at all.
    try std.testing.expect(font_heap.get(0) == null);
    try std.testing.expect(shader_heap.get(0) == null);
    try std.testing.expect(render_texture_heap.get(0) == null);
    try std.testing.expect(prepared_text_heap.get(0) == null);
    try std.testing.expect(store_heap.get(0) == null);

    const real_shader = storeShader(.headless).?;
    const real_target = storeRenderTexture(.headless).?;

    {
        const scope = PhaseScope.enter(.startup);
        defer scope.leave();

        // A stub font has no metrics to snapshot; the headless answer is the
        // built-in one, and the transferred handle is still released.
        const snapshot = hostedDrawFontMetricsRaw(&roc_host, .{
            .payload = .{ .loaded_font = allocateTestResourceStub(&roc_host) },
            .tag = .LoadedFont,
        });
        defer snapshot.glyphs.decref(&roc_host);

        // Preparing text with a stub font is refused rather than silently
        // prepared against the default font, and consumes no heap slot.
        const prepared = hostedDrawPrepareTextRaw(&roc_host, .{
            .font = .{ .payload = .{ .loaded_font = allocateTestResourceStub(&roc_host) }, .tag = .LoadedFont },
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
        const store_texture = hostedAssetsLoadStoreTextureRaw(&roc_host, .{
            .store = allocateTestResourceStub(&roc_host),
            .path = abi.RocStr.fromSlice("atlas.png", &roc_host),
        });
        try std.testing.expectEqual(STORE_LOAD_ERR_READ, store_texture.err);

        const store_font = hostedDrawLoadStoreFontRaw(&roc_host, .{
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

    try std.testing.expect(sound_heap.get(0) == null);
    try std.testing.expect(music_heap.get(0) == null);

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
            .texture = .{ .handle = texture, .height = 16, .width = 16 },
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

fn headlessTextureInstances(host: *RocHost, count: usize) abi.RocListWith(abi.DrawHostDraw_texture_instancesArg0Instances, false) {
    const list = abi.RocListWith(abi.DrawHostDraw_texture_instancesArg0Instances, false).allocate(count, host);
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
    const err = hostedAssetsUpdateTextureRaw(&roc_host, .{
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
    try std.testing.expectEqual(RESOURCE_ERR_LIMIT, hostedAssetsGenerateColorTextureRaw(.{
        .height = 1,
        .width = 1,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    }).err);
    for (textures) |texture| releaseResourceBox(&roc_host, texture);

    var targets: [32]*u64 = undefined;
    for (&targets) |*target| target.* = storeRenderTexture(.headless).?;
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
    const result = hostedAssetsUpdateTextureRaw(&roc_host, .{
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
    const whole_err = hostedAssetsUpdateTextureRaw(&roc_host, .{
        .pixels = abi.RocListWith(Color, false).fromSlice(&pixels, &roc_host),
        .texture = .{ .handle = whole_handle, .height = 99, .width = 99 },
    });
    try std.testing.expectEqual(TEXTURE_UPDATE_OK, whole_err);

    const region_handle = storeTexture(.{ .headless = .{ .width = 2, .height = 3 } }).?;
    const region_err = hostedAssetsUpdateTextureRegionRaw(&roc_host, .{
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

fn openStoreRootRelative(base: std.Io.Dir, root: []const u8) !std.Io.Dir {
    if (!isSafeRootRelativePath(root)) return error.InvalidRootPath;
    return base.openDir(mainThreadIo(), root, .{});
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

fn openStoreDirectory(allocator: std.mem.Allocator, location_kind: u8, root: []const u8) !std.Io.Dir {
    const io = mainThreadIo();
    switch (location_kind) {
        // The executable directory is opened first, then the configured root
        // is opened through that handle. This remains CWD-independent even if
        // another library changes CWD later in the process lifetime.
        0 => {
            const executable_dir_path = try std.process.executableDirPathAlloc(io, allocator);
            defer allocator.free(executable_dir_path);
            const executable_dir = try std.Io.Dir.openDirAbsolute(io, executable_dir_path, .{});
            defer executable_dir.close(io);
            return openStoreRootRelative(executable_dir, root);
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

fn expectedManifestHash(args: abi.AssetsHostOpen_storeArgs) union(enum) { any, hash: []const u8, invalid } {
    const hash = args.content_hash.asSlice();
    return switch (args.content_hash_mode) {
        0 => if (hash.len == 0) .any else .invalid,
        1 => if (isSha256Hex(hash)) .{ .hash = hash } else .invalid,
        else => .invalid,
    };
}

fn validateStoreManifest(allocator: std.mem.Allocator, root: *std.Io.Dir, args: abi.AssetsHostOpen_storeArgs) u8 {
    if (!args.manifest_required) return STORE_ERR_NONE;
    const bytes = root.readFileAlloc(mainThreadIo(), "roc-assets.manifest", allocator, .limited(MAX_ASSET_MANIFEST_BYTES)) catch |err| {
        return switch (err) {
            error.FileNotFound => STORE_ERR_MANIFEST_MISSING,
            else => STORE_ERR_MANIFEST_UNREADABLE,
        };
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
    var root = try openStoreRootRelative(executable_dir, "assets");
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

fn testStoreOpenArgs(host: *RocHost, root: []const u8, manifest_required: bool, content_hash_mode: u8, content_hash: []const u8) abi.AssetsHostOpen_storeArgs {
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
    const texture = hostedAssetsLoadTextureBytesRaw(&roc_host, .{ .bytes = texture_bytes, .format = 0 });
    try std.testing.expectEqual(RESOURCE_ERR_NONE, texture.err);
    try std.testing.expectEqual(@as(isize, 1), texture_rc.*);
    texture.texture.decref(&roc_host);
    texture_bytes.decref(&roc_host);

    const bad_texture_bytes = abi.RocListWith(u8, false).fromSlice("bad format", &roc_host);
    bad_texture_bytes.incref(1);
    const bad_texture_rc = byteListRefcount(bad_texture_bytes);
    try std.testing.expectEqual(RESOURCE_ERR_FAILED, hostedAssetsLoadTextureBytesRaw(&roc_host, .{ .bytes = bad_texture_bytes, .format = 99 }).err);
    try std.testing.expectEqual(@as(isize, 1), bad_texture_rc.*);
    bad_texture_bytes.decref(&roc_host);

    const font_bytes = abi.RocListWith(u8, false).fromSlice("not decoded in headless tests", &roc_host);
    font_bytes.incref(1);
    const font_rc = byteListRefcount(font_bytes);
    const font = hostedDrawLoadFontBytesRaw(&roc_host, .{ .bytes = font_bytes, .format = 0, .size = 16 });
    try std.testing.expectEqual(RESOURCE_ERR_NONE, font.err);
    try std.testing.expectEqual(@as(isize, 1), font_rc.*);
    releaseResourceBox(&roc_host, font.font);
    font_bytes.decref(&roc_host);

    const bad_font_bytes = abi.RocListWith(u8, false).fromSlice("bad format", &roc_host);
    bad_font_bytes.incref(1);
    const bad_font_rc = byteListRefcount(bad_font_bytes);
    try std.testing.expectEqual(RESOURCE_ERR_FAILED, hostedDrawLoadFontBytesRaw(&roc_host, .{ .bytes = bad_font_bytes, .format = 99, .size = 16 }).err);
    try std.testing.expectEqual(@as(isize, 1), bad_font_rc.*);
    bad_font_bytes.decref(&roc_host);
}

fn hostedAssetsOpenStoreRaw(host: *RocHost, args: abi.AssetsHostOpen_storeArgs) callconv(.c) abi.AssetsHostOpen_storeRetRecord {
    enforcePhase("Assets.Store.open!", during_load);
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
    var root = openStoreDirectory(allocator, args.location_kind, root_path) catch |err| {
        const code: u8 = switch (err) {
            error.InvalidRootPath => STORE_ERR_INVALID_ROOT_PATH,
            else => storeOpenError(err),
        };
        reportStoreOpenFailure(code, root_path, null);
        return .{ .store = invalidResourceHandle(), .err = code };
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

fn exportedAssetsOpenStoreRaw(args: abi.AssetsHostOpen_storeArgs) callconv(.c) abi.AssetsHostOpen_storeRetRecord {
    return hostedAssetsOpenStoreRaw(activeHost(), args);
}

const StoreRead = union(enum) { bytes: []u8, path_invalid, not_found, failed };

fn readStoreAsset(allocator: std.mem.Allocator, store: *StoreResource, path: []const u8) StoreRead {
    if (!isSafeStoreRelativePath(path)) return .path_invalid;
    const bytes = store.root.readFileAlloc(mainThreadIo(), path, allocator, .limited(MAX_ASSET_FILE_BYTES)) catch |err| {
        return switch (err) {
            error.FileNotFound => .not_found,
            else => .failed,
        };
    };
    return .{ .bytes = bytes };
}

fn hostedAssetsLoadStoreTextureRaw(host: *RocHost, args: abi.AssetsHostLoad_store_textureArgs) callconv(.c) abi.AssetsHostLoad_store_textureRetRecord {
    enforcePhase("Assets.load_texture!", during_load);
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

fn exportedAssetsLoadStoreTextureRaw(args: abi.AssetsHostLoad_store_textureArgs) callconv(.c) abi.AssetsHostLoad_store_textureRetRecord {
    return hostedAssetsLoadStoreTextureRaw(activeHost(), args);
}

fn hostedAssetsLoadTextureBytesRaw(host: *RocHost, args: abi.AssetsHostLoad_texture_bytesArgs) callconv(.c) abi.AssetsHostLoad_texture_bytesRetRecord {
    enforcePhase("Assets.texture_from_bytes!", during_load);
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

fn exportedAssetsLoadTextureBytesRaw(args: abi.AssetsHostLoad_texture_bytesArgs) callconv(.c) abi.AssetsHostLoad_texture_bytesRetRecord {
    return hostedAssetsLoadTextureBytesRaw(activeHost(), args);
}

fn hostedAssetsGenerateColorTextureRaw(args: abi.AssetsHostGenerate_color_textureArgs) callconv(.c) abi.AssetsHostGenerate_color_textureRetRecord {
    enforcePhase("Assets.generate_color_texture!", during_load);
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

fn hostedAssetsGenerateCheckedTextureRaw(args: abi.AssetsHostGenerate_checked_textureArgs) callconv(.c) abi.AssetsHostGenerate_checked_textureRetRecord {
    enforcePhase("Assets.generate_checked_texture!", during_load);
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

fn hostedAssetsUpdateTextureRaw(host: *RocHost, args: abi.AssetsHostUpdate_textureArgs) callconv(.c) u8 {
    enforcePhase("Assets.update_texture!", during_update);
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
fn hostedAssetsUpdateTextureRegionRaw(host: *RocHost, args: abi.AssetsHostUpdate_texture_regionArgs) callconv(.c) u8 {
    enforcePhase("Assets.update_texture_region!", during_update);
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

fn exportedAssetsUpdateTextureRaw(args: abi.AssetsHostUpdate_textureArgs) callconv(.c) u8 {
    return hostedAssetsUpdateTextureRaw(activeHost(), args);
}

fn exportedAssetsUpdateTextureRegionRaw(args: abi.AssetsHostUpdate_texture_regionArgs) callconv(.c) u8 {
    return hostedAssetsUpdateTextureRegionRaw(activeHost(), args);
}

fn hostedAssetsSetTextureFilterRaw(texture_owner: abi.Texture, code: u8) callconv(.c) void {
    enforcePhase("Assets.set_texture_filter!", during_update);
    defer texture_owner.decref(activeHost());
    if (builtin.is_test) return;
    const texture = nativeTextureForToken(texture_owner.handle.*) orelse return;
    raylib.setTextureFilter(texture, code);
}

fn hostedAssetsSetTextureWrapRaw(texture_owner: abi.Texture, code: u8) callconv(.c) void {
    enforcePhase("Assets.set_texture_wrap!", during_update);
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

fn hostedDrawLoadRenderTextureRaw(args: abi.DrawHostLoad_render_textureArgs) callconv(.c) abi.DrawHostLoad_render_textureRetRecord {
    enforcePhase("Draw.RenderTexture.load!", during_load);
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

fn hostedDrawLoadShaderSourceRaw(host: *RocHost, args: abi.DrawHostLoad_shader_sourceArgs) callconv(.c) abi.DrawHostLoad_shader_sourceRetRecord {
    enforcePhase("Draw.Shader.from_source!", during_load);
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

fn hostedDrawLoadStoreShaderRaw(host: *RocHost, args: abi.DrawHostLoad_store_shaderArgs) callconv(.c) abi.DrawHostLoad_store_shaderRetRecord {
    enforcePhase("Draw.Shader.from_store!", during_load);
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

fn exportedDrawLoadStoreShaderRaw(args: abi.DrawHostLoad_store_shaderArgs) callconv(.c) abi.DrawHostLoad_store_shaderRetRecord {
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

fn hostedDrawBeginRenderTextureRaw(args: abi.DrawHostBegin_render_textureArgs) callconv(.c) u8 {
    enforcePhase("Draw.with_render_texture!", during_render);
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
fn hostedDrawFrameSizeRaw() callconv(.c) abi.DrawHostFrame_size {
    enforcePhase("Draw.Frame.size!", during_render);
    if (render_texture_lease_count > 0) return render_target_sizes[render_texture_lease_count - 1];
    const window = windowState();
    return .{ .height = @floatFromInt(window.size.height), .width = @floatFromInt(window.size.width) };
}

fn hostedDrawBeginShaderRaw(args: abi.DrawHostBegin_shaderArgs) callconv(.c) u8 {
    enforcePhase("Draw.with_shader!", during_render);
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
    enforcePhase("Draw.with_blend_mode!", during_render);
    if (blend_scope_count == SCOPE_STACK_LIMIT) return SCOPE_LIMIT;
    if (args.arg0 > 5) return SCOPE_UNAVAILABLE;
    if (!headlessMode()) raylib.beginBlendMode(args.arg0);
    blend_scopes[blend_scope_count] = args.arg0;
    blend_scope_count += 1;
    return SCOPE_OK;
}

fn hostedDrawEndBlendRaw() callconv(.c) void {
    enforcePhase("Draw.with_blend_mode!", during_render);
    if (blend_scope_count == 0) return;
    if (!headlessMode()) raylib.endBlendMode();
    blend_scope_count -= 1;
    if (!headlessMode() and blend_scope_count > 0) raylib.beginBlendMode(blend_scopes[blend_scope_count - 1]);
}

fn hostedDrawShaderLocationRaw(host: *RocHost, args: abi.DrawHostShader_locationArgs) callconv(.c) i32 {
    enforcePhase("Draw.Shader.uniform_*!", during_load);
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

fn exportedDrawShaderLocationRaw(args: abi.DrawHostShader_locationArgs) callconv(.c) i32 {
    return hostedDrawShaderLocationRaw(activeHost(), args);
}

fn hostedDrawSetShaderFloatRaw(args: abi.DrawHostSet_shader_floatArgs) callconv(.c) void {
    enforcePhase("Draw.F32Uniform.set!", during_render);
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderFloat(resource.native, args.uniform.location, args.value);
}

fn hostedDrawSetShaderIntRaw(args: abi.DrawHostSet_shader_intArgs) callconv(.c) void {
    enforcePhase("Draw.I32Uniform.set!", during_render);
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderInt(resource.native, args.uniform.location, args.value);
}

fn hostedDrawSetShaderVec2Raw(args: abi.DrawHostSet_shader_vec2Args) callconv(.c) void {
    enforcePhase("Draw.Vec2Uniform.set!", during_render);
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderVec2(resource.native, args.uniform.location, .{ args.value.x, args.value.y });
}

fn hostedDrawSetShaderVec3Raw(args: abi.DrawHostSet_shader_vec3Args) callconv(.c) void {
    enforcePhase("Draw.Vec3Uniform.set!", during_render);
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderVec3(resource.native, args.uniform.location, .{ args.value.x, args.value.y, args.value.z });
}

fn hostedDrawSetShaderVec4Raw(args: abi.DrawHostSet_shader_vec4Args) callconv(.c) void {
    enforcePhase("Draw.Vec4Uniform.set!", during_render);
    defer args.uniform.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    raylib.setShaderVec4(resource.native, args.uniform.location, .{ args.value.x, args.value.y, args.value.z, args.value.w });
}

fn hostedDrawSetShaderTextureRaw(args: abi.DrawHostSet_shader_textureArgs) callconv(.c) void {
    enforcePhase("Draw.TextureUniform.set!", during_render);
    defer args.uniform.decref(activeHost());
    defer args.texture.decref(activeHost());
    if (builtin.is_test) return;
    const resource = shader_heap.get(args.uniform.shader.*) orelse return;
    if (resource.* == .headless) return;
    const texture = nativeTextureForToken(args.texture.handle.*) orelse return;
    raylib.setShaderTexture(resource.native, args.uniform.location, texture);
}

/// Forward Roc scissor bounds to the raylib backend.
fn hostedDrawBeginScissorRaw(args: abi.DrawHostBegin_scissorArgs) callconv(.c) u8 {
    enforcePhase("Draw.with_scissor!", during_render);
    if (scissor_scope_count == SCOPE_STACK_LIMIT) return SCOPE_LIMIT;
    if (!headlessMode()) raylib.beginScissor(args.x, args.y, args.width, args.height);
    scissor_scopes[scissor_scope_count] = args;
    scissor_scope_count += 1;
    return SCOPE_OK;
}

/// End the scissor region opened by the Roc renderer.
fn hostedDrawEndScissorRaw() callconv(.c) void {
    enforcePhase("Draw.with_scissor!", during_render);
    if (scissor_scope_count == 0) return;
    if (!headlessMode()) raylib.endScissor();
    scissor_scope_count -= 1;
    if (!headlessMode() and scissor_scope_count > 0) {
        const outer = scissor_scopes[scissor_scope_count - 1];
        raylib.beginScissor(outer.x, outer.y, outer.width, outer.height);
    }
}

fn hostedDrawBeginCamera(args: abi.DrawHostBegin_cameraArgs) callconv(.c) u8 {
    enforcePhase("Draw.with_camera!", during_render);
    if (camera_scope_count == SCOPE_STACK_LIMIT) return SCOPE_LIMIT;
    if (!headlessMode()) raylib.beginMode2D(args);
    camera_scopes[camera_scope_count] = args;
    camera_scope_count += 1;
    return SCOPE_OK;
}

fn hostedDrawCircleRaw(args: abi.DrawHostCircleArgs) callconv(.c) void {
    enforcePhase("Draw.circle!", during_render);
    if (active_headless) return;
    raylib.drawCircle(args);
}

fn hostedDrawCircleGradient(args: abi.DrawHostCircle_gradientArgs) callconv(.c) void {
    enforcePhase("Draw.circle_gradient!", during_render);
    if (active_headless) return;
    raylib.drawCircleGradient(args);
}

fn hostedDrawCircleLinesRaw(args: abi.DrawHostCircle_linesArgs) callconv(.c) void {
    enforcePhase("Draw.circle_lines!", during_render);
    if (active_headless) return;
    raylib.drawCircleLines(args);
}

fn hostedDrawClear(color: Color) callconv(.c) void {
    enforcePhase("Draw.clear!", during_render);
    if (active_headless) return;
    raylib.clearBackground(color);
}

fn hostedDrawEndCamera() callconv(.c) void {
    enforcePhase("Draw.with_camera!", during_render);
    if (camera_scope_count == 0) return;
    if (!headlessMode()) raylib.endMode2D();
    camera_scope_count -= 1;
    if (!headlessMode() and camera_scope_count > 0) raylib.beginMode2D(camera_scopes[camera_scope_count - 1]);
}

fn hostedDrawFps(args: abi.DrawHostFpsArgs) callconv(.c) void {
    enforcePhase("Draw.fps!", during_render);
    if (active_headless) return;
    raylib.drawFps(args);
}

fn hostedDrawLineRaw(args: abi.DrawHostLineArgs) callconv(.c) void {
    enforcePhase("Draw.line!", during_render);
    if (active_headless) return;
    raylib.drawLine(args);
}

fn hostedDrawPolygonRaw(host: *RocHost, args: abi.DrawHostPolygonArgs) callconv(.c) void {
    enforcePhase("Draw.polygon!", during_render);
    defer args.points.decref(host);
    if (active_headless) return;
    raylib.drawPolygon(args.points.items(), args.color);
}

fn exportedDrawPolygonRaw(args: abi.DrawHostPolygonArgs) callconv(.c) void {
    hostedDrawPolygonRaw(activeHost(), args);
}

fn hostedDrawPolygonLinesRaw(host: *RocHost, args: abi.DrawHostPolygon_linesArgs) callconv(.c) void {
    enforcePhase("Draw.polygon_lines!", during_render);
    defer args.points.decref(host);
    if (active_headless) return;
    raylib.drawPolygonLines(args.points.items(), args.thickness, args.color);
}

fn exportedDrawPolygonLinesRaw(args: abi.DrawHostPolygon_linesArgs) callconv(.c) void {
    hostedDrawPolygonLinesRaw(activeHost(), args);
}

fn hostedDrawRectangleRaw(args: abi.DrawHostRectangleArgs) callconv(.c) void {
    enforcePhase("Draw.rectangle!", during_render);
    if (active_headless) return;
    raylib.drawRectangle(args);
}

fn hostedDrawRectangleLinesRaw(args: abi.DrawHostRectangle_linesArgs) callconv(.c) void {
    enforcePhase("Draw.rectangle_lines!", during_render);
    if (active_headless) return;
    raylib.drawRectangleLines(args);
}

fn hostedDrawRectangleGradientH(args: abi.DrawHostRectangle_gradient_hArgs) callconv(.c) void {
    enforcePhase("Draw.rectangle_gradient_h!", during_render);
    if (active_headless) return;
    raylib.drawRectangleGradientH(args);
}

fn hostedDrawRectangleGradientV(args: abi.DrawHostRectangle_gradient_vArgs) callconv(.c) void {
    enforcePhase("Draw.rectangle_gradient_v!", during_render);
    if (active_headless) return;
    raylib.drawRectangleGradientV(args);
}

fn hostedDrawRoundedRectangleRaw(args: abi.DrawHostRounded_rectangleArgs) callconv(.c) void {
    enforcePhase("Draw.rounded_rectangle!", during_render);
    if (active_headless) return;
    raylib.drawRoundedRectangle(args);
}

fn hostedDrawRoundedRectangleLinesRaw(args: abi.DrawHostRounded_rectangle_linesArgs) callconv(.c) void {
    enforcePhase("Draw.rounded_rectangle_lines!", during_render);
    if (active_headless) return;
    raylib.drawRoundedRectangleLines(args);
}

fn hostedDrawTriangleRaw(args: abi.DrawHostTriangleArgs) callconv(.c) void {
    enforcePhase("Draw.triangle!", during_render);
    if (active_headless) return;
    raylib.drawTriangle(args);
}

fn hostedDrawTriangleLinesRaw(args: abi.DrawHostTriangle_linesArgs) callconv(.c) void {
    enforcePhase("Draw.triangle_lines!", during_render);
    if (active_headless) return;
    raylib.drawTriangleLines(args);
}

fn hostedDrawLoadFontBytesRaw(host: *RocHost, args: abi.DrawHostLoad_font_bytesArgs) callconv(.c) abi.DrawHostLoad_font_bytesRetRecord {
    enforcePhase("Draw.font_from_bytes!", during_load);
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

fn exportedDrawLoadFontBytesRaw(args: abi.DrawHostLoad_font_bytesArgs) callconv(.c) abi.DrawHostLoad_font_bytesRetRecord {
    return hostedDrawLoadFontBytesRaw(activeHost(), args);
}

fn hostedDrawLoadStoreFontRaw(host: *RocHost, args: abi.DrawHostLoad_store_fontArgs) callconv(.c) abi.DrawHostLoad_store_fontRetRecord {
    enforcePhase("Draw.load_store_font!", during_load);
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

fn exportedDrawLoadStoreFontRaw(args: abi.DrawHostLoad_store_fontArgs) callconv(.c) abi.DrawHostLoad_store_fontRetRecord {
    return hostedDrawLoadStoreFontRaw(activeHost(), args);
}

fn fontForValue(font_value: *const abi.DefaultFontOrLoadedFont) raylib.Font {
    if (font_value.tag == .DefaultFont) return raylib.defaultFont();
    const resource = font_heap.get(font_value.payload_loaded_font().*) orelse return raylib.defaultFont();
    return switch (resource.*) {
        .headless => raylib.defaultFont(),
        .native => |font| font,
    };
}

fn headlessFontMetrics(host: *RocHost) abi.DrawHostFont_metricsRetRecord {
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
fn snapshotRaylibFontMetrics(host: *RocHost, font: raylib.Font) abi.DrawHostFont_metricsRetRecord {
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

fn hostedDrawFontMetricsRaw(host: *RocHost, font: abi.DefaultFontOrLoadedFont) callconv(.c) abi.DrawHostFont_metricsRetRecord {
    enforcePhase("Draw font metric snapshot", during_load);
    defer font.decref(host);
    if (headlessMode()) return headlessFontMetrics(host);
    return snapshotRaylibFontMetrics(host, fontForValue(&font));
}

fn exportedDrawFontMetricsRaw(font: abi.DefaultFontOrLoadedFont) callconv(.c) abi.DrawHostFont_metricsRetRecord {
    return hostedDrawFontMetricsRaw(activeHost(), font);
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
    const snapshot = hostedDrawFontMetricsRaw(&roc_host, .{
        .payload = .{ .loaded_font = source },
        .tag = .LoadedFont,
    });
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

fn hostedDrawPrepareTextRaw(host: *RocHost, args: abi.DrawHostPrepare_textArgs) callconv(.c) abi.DrawHostPrepare_textRetRecord {
    enforcePhase("Text.prepare!", during_load);
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
        break :blk TextMeasurement{ .height = size.y, .width = size.x };
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
    enforcePhase("Text.Prepared.draw!", during_render);
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
    enforcePhase("Draw.text!", during_render);
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
    enforcePhase("Draw.text_at!", during_render);
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
    enforcePhase("Draw.texture!", during_render);
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
fn hostedDrawTextureInstancesRaw(host: *RocHost, args: abi.DrawHostDraw_texture_instancesArgs) callconv(.c) void {
    enforcePhase("Draw.texture_instances!", during_render);
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

fn exportedDrawTextureInstancesRaw(args: abi.DrawHostDraw_texture_instancesArgs) callconv(.c) void {
    hostedDrawTextureInstancesRaw(activeHost(), args);
}

fn hostedDrawTextureQuadRaw(args: abi.DrawHostDraw_texture_quadArgs) callconv(.c) void {
    enforcePhase("Draw.projective_texture!", during_render);
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

fn hostedReadEnvWindows(roc_host: *RocHost, key_arg: abi.RocStr) callconv(.c) ReadEnvResult {
    enforcePhase("Host.read_env!", during_startup);
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
    enforcePhase("Host.read_env!", during_startup);
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
    enforcePhase("Host.read_file!", during_startup);
    defer path_arg.decref(roc_host);

    const allocator = allocatorFromHost(roc_host);
    const path = path_arg.asSlice();
    const bytes = std.Io.Dir.cwd().readFileAlloc(mainThreadIo(), path, allocator, .limited(MAX_FILE_READ_BYTES)) catch |err| {
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
    enforcePhase("Tilemap.load_tmx!", during_load);
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

fn hostedTilemapDrawRaw(host: *RocHost, args: abi.TilemapHostDrawArgs) callconv(.c) void {
    enforcePhase("Tilemap.draw_layers!", during_render);
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
    enforcePhase("App.Startup.exit!", during_update);
    exit_requested = @as(i64, code);
}

/// Suggest a new logical window size.
///
/// Native window managers may adjust or ignore the hint. A later input's
/// window snapshot, and the active frame size during presentation, report the
/// geometry the backend actually established. The headless semantic backend
/// honors the hint deterministically.
fn hostedSuggestWindowSize(args: abi.HostHostSuggest_window_sizeArgs) callconv(.c) u8 {
    enforcePhase("Window.suggest_size!", during_update);
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
    if (headlessMode()) return;
    raylib.setTargetFps(fps);
}

fn hostedSuggestWindowMinSize(args: abi.HostHostSuggest_window_min_sizeArgs) callconv(.c) void {
    enforcePhase("Window.suggest_min_size!", during_update);
    if (headlessMode()) return;
    raylib.suggestWindowMinSize(nonNegativeCInt(args.width), nonNegativeCInt(args.height));
}

fn hostedSetExitKey(key_code: i32) callconv(.c) void {
    enforcePhase("Keys.set_exit_key!", during_update);
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
fn hostedCaptureStartRecording(roc_host: *RocHost, args: abi.CaptureHostStart_recordingArgs) callconv(.c) u8 {
    enforcePhase("Capture.start!", during_update);
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

fn hostedCaptureSetVirtualMouse(args: abi.CaptureHostSet_virtual_mouseArgs) callconv(.c) void {
    enforcePhase("Mouse.set_source!", during_update);
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
    enforcePhase("Capture.stop!", during_update);
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

fn hostedGetClipboardText(roc_host: *RocHost) callconv(.c) ClipboardTextResult {
    enforcePhase("App.Startup.get_clipboard_text!", during_startup);
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
fn hostedReadClipboard(roc_host: *RocHost) callconv(.c) abi.HostHostRead_clipboardRetRecord {
    enforcePhase("Window.read_clipboard!", during_update);

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

fn exportedReadClipboard() callconv(.c) abi.HostHostRead_clipboardRetRecord {
    return hostedReadClipboard(activeHost());
}

fn hostedSetClipboardText(roc_host: *RocHost, text_arg: abi.RocStr) callconv(.c) void {
    enforcePhase("Window.set_clipboard_text!", during_update);
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
    enforcePhase("App.Startup.random_i32!", during_startup);
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
    enforcePhase("Audio.gen_tone!", during_load);
    if (headlessMode()) {
        const sound = storeSound(.headless) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .sound = sound, .err = RESOURCE_ERR_NONE };
    }
    const sound = raylib.genTone(args.freq, args.ms) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeSound(.{ .native = sound }) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .sound = stored, .err = RESOURCE_ERR_NONE };
}

fn hostedAudioGenSound(args: abi.AudioHostGen_soundArgs) callconv(.c) abi.AudioHostGen_soundRetRecord {
    enforcePhase("Audio.gen_sound!", during_load);
    if (headlessMode()) {
        const sound = storeSound(.headless) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .sound = sound, .err = RESOURCE_ERR_NONE };
    }
    const sound = raylib.genSound(args) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeSound(.{ .native = sound }) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .sound = stored, .err = RESOURCE_ERR_NONE };
}

fn hostedAudioLoadSound(host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.AudioHostLoad_soundRetRecord {
    enforcePhase("Audio.load_sound!", during_load);
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
    enforcePhase("Audio.load_music!", during_load);
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

// The audio entry points below guard their `.native` arm with `builtin.is_test`
// rather than returning early, the way the scoped drawing operations do. The
// guard exists only to keep raylib's audio symbols out of the test link -- a
// unit test never reaches a `.native` resource, since everything it stores is
// `.headless` -- and keeping it inside the arm leaves the handle lookup itself
// running, which is the part worth testing: an unresolvable token has to reach
// the `orelse return` and still release the reference it was handed.
fn hostedAudioPlay(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.play!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.playSound(sound),
    }
}

fn hostedAudioStop(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.stop!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.stopSound(sound),
    }
}

fn hostedAudioPause(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.pause!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.pauseSound(sound),
    }
}

fn hostedAudioResume(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.resume!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.resumeSound(sound),
    }
}

fn hostedAudioIsPlaying(handle: *u64) callconv(.c) bool {
    enforcePhase("Audio.Sound.is_playing!", constant_time_anywhere);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return false;
    return switch (resource.*) {
        .headless => false,
        .native => |sound| if (builtin.is_test) false else raylib.isSoundPlaying(sound),
    };
}

fn hostedAudioSetVolume(handle: *u64, volume: f32) callconv(.c) void {
    enforcePhase("Audio.Sound.set_volume!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.setSoundVolume(sound, volume),
    }
}

fn hostedAudioSetPitch(handle: *u64, pitch: f32) callconv(.c) void {
    enforcePhase("Audio.Sound.set_pitch!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.setSoundPitch(sound, pitch),
    }
}

fn hostedAudioSetPan(handle: *u64, pan: f32) callconv(.c) void {
    enforcePhase("Audio.Sound.set_pan!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.setSoundPan(sound, pan),
    }
}

fn hostedAudioPlayMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.play!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.playMusic(music),
    }
}

fn hostedAudioStopMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.stop!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.stopMusic(music),
    }
}

fn hostedAudioPauseMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.pause!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.pauseMusic(music),
    }
}

fn hostedAudioResumeMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.resume!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.resumeMusic(music),
    }
}

fn hostedAudioSetMusicVolume(handle: *u64, volume: f32) callconv(.c) void {
    enforcePhase("Audio.Music.set_volume!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.setMusicVolume(music, volume),
    }
}

fn hostedAudioSetMusicPitch(handle: *u64, pitch: f32) callconv(.c) void {
    enforcePhase("Audio.Music.set_pitch!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.setMusicPitch(music, pitch),
    }
}

fn hostedAudioSetMusicPan(handle: *u64, pan: f32) callconv(.c) void {
    enforcePhase("Audio.Music.set_pan!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.setMusicPan(music, pan),
    }
}

fn hostedAudioSetMusicLooping(handle: *u64, looping: bool) callconv(.c) void {
    enforcePhase("Audio.Music.set_looping!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |*music| raylib.setMusicLooping(music, looping),
    }
}

fn hostedAudioIsMusicPlaying(handle: *u64) callconv(.c) bool {
    enforcePhase("Audio.Music.is_playing!", constant_time_anywhere);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return false;
    return switch (resource.*) {
        .headless => false,
        .native => |music| if (builtin.is_test) false else raylib.isMusicPlaying(music),
    };
}

fn hostedAudioSeekMusic(handle: *u64, seconds: f32) callconv(.c) void {
    enforcePhase("Audio.Music.seek!", during_update);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.seekMusic(music, seconds),
    }
}

fn hostedAudioMusicLength(handle: *u64) callconv(.c) f32 {
    enforcePhase("Audio.Music.length!", constant_time_anywhere);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return 0;
    return switch (resource.*) {
        .headless => 0,
        .native => |music| if (builtin.is_test) 0 else raylib.musicLength(music),
    };
}

fn hostedAudioMusicTimePlayed(handle: *u64) callconv(.c) f32 {
    enforcePhase("Audio.Music.time_played!", constant_time_anywhere);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return 0;
    return switch (resource.*) {
        .headless => 0,
        .native => |music| if (builtin.is_test) 0 else raylib.musicTimePlayed(music),
    };
}

fn hostedAudioSetMasterVolume(volume: f32) callconv(.c) void {
    enforcePhase("Audio.set_master_volume!", during_update);
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
    // The final model has been dropped, so everything it held is retired.
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
    std.debug.assert(texture_heap.active() == 0);
    std.debug.assert(render_texture_heap.active() == 0);
    std.debug.assert(shader_heap.active() == 0);
    std.debug.assert(prepared_text_heap.active() == 0);
    std.debug.assert(font_heap.active() == 0);
    std.debug.assert(music_heap.active() == 0);
    std.debug.assert(sound_heap.active() == 0);
    std.debug.assert(file_bytes_heap.active() == 0);
    std.debug.assert(store_heap.active() == 0);
    file_bytes_heap.deinitAll();
    store_heap.deinitAll();
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

        @export(&exportedAssetsOpenStoreRaw, .{ .name = "roc_assets_open_store_raw" });
        @export(&exportedAssetsLoadStoreTextureRaw, .{ .name = "roc_assets_load_store_texture_raw" });
        @export(&exportedAssetsLoadTextureBytesRaw, .{ .name = "roc_assets_load_texture_bytes_raw" });
        @export(&hostedAssetsGenerateColorTextureRaw, .{ .name = "roc_assets_generate_color_texture_raw" });
        @export(&hostedAssetsGenerateCheckedTextureRaw, .{ .name = "roc_assets_generate_checked_texture_raw" });
        @export(&exportedAssetsUpdateTextureRaw, .{ .name = "roc_assets_update_texture_raw" });
        @export(&exportedAssetsUpdateTextureRegionRaw, .{ .name = "roc_assets_update_texture_region_raw" });
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
        @export(&exportedDrawTextureInstancesRaw, .{ .name = "roc_draw_draw_texture_instances_raw" });
        @export(&hostedDrawTextureQuadRaw, .{ .name = "roc_draw_draw_texture_quad_raw" });
        @export(&hostedDrawEndCamera, .{ .name = "roc_draw_end_camera" });
        @export(&hostedDrawEndBlendRaw, .{ .name = "roc_draw_end_blend_raw" });
        @export(&hostedDrawEndRenderTextureRaw, .{ .name = "roc_draw_end_render_texture_raw" });
        @export(&hostedDrawEndScissorRaw, .{ .name = "roc_draw_end_scissor_raw" });
        @export(&hostedDrawEndShaderRaw, .{ .name = "roc_draw_end_shader_raw" });
        @export(&hostedDrawFps, .{ .name = "roc_draw_fps" });
        @export(&exportedDrawFontMetricsRaw, .{ .name = "roc_draw_font_metrics_raw" });
        @export(&hostedDrawFrameSizeRaw, .{ .name = "roc_draw_frame_size" });
        @export(&hostedDrawLineRaw, .{ .name = "roc_draw_line_raw" });
        @export(&exportedDrawLoadFontBytesRaw, .{ .name = "roc_draw_load_font_bytes_raw" });
        @export(&exportedDrawLoadStoreFontRaw, .{ .name = "roc_draw_load_store_font_raw" });
        @export(&hostedDrawLoadRenderTextureRaw, .{ .name = "roc_draw_load_render_texture_raw" });
        @export(&exportedDrawLoadShaderSourceRaw, .{ .name = "roc_draw_load_shader_source_raw" });
        @export(&exportedDrawLoadStoreShaderRaw, .{ .name = "roc_draw_load_store_shader_raw" });
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
        @export(&exportedArgs, .{ .name = "roc_host_args" });
        @export(&hostedExit, .{ .name = "roc_host_exit" });
        @export(&hostedTaskSleep, .{ .name = "roc_task_sleep" });
        @export(&exportedFilesReadText, .{ .name = "roc_files_read_text" });
        @export(&exportedFilesReadBytes, .{ .name = "roc_files_read_bytes" });
        @export(&exportedFilesList, .{ .name = "roc_files_list" });
        @export(&exportedFilesWriteText, .{ .name = "roc_files_write_text" });
        @export(&exportedFilesWriteBytes, .{ .name = "roc_files_write_bytes" });
        @export(&hostedTaskSpawn, .{ .name = "roc_task_spawn" });
        @export(&exportedGetClipboardText, .{ .name = "roc_host_get_clipboard_text" });
        @export(&exportedReadClipboard, .{ .name = "roc_host_read_clipboard" });
        @export(&hostedRandomI32, .{ .name = "roc_host_random_i32" });
        @export(if (builtin.os.tag == .windows) &exportedReadEnvWindows else &exportedReadEnvPosix, .{ .name = "roc_host_read_env" });
        @export(&exportedReadFileRaw, .{ .name = "roc_host_read_file_raw" });
        @export(&exportedSetClipboardText, .{ .name = "roc_host_set_clipboard_text" });
        @export(&hostedSetExitKey, .{ .name = "roc_host_set_exit_key" });
        @export(&exportedCaptureStartRecording, .{ .name = "roc_capture_start_recording" });
        @export(&hostedCaptureSetVirtualMouse, .{ .name = "roc_capture_set_virtual_mouse" });
        @export(&hostedCaptureStopRecording, .{ .name = "roc_capture_stop_recording" });
        @export(&exportedCaptureScreenshot, .{ .name = "roc_capture_screenshot" });
        @export(&hostedSuggestWindowSize, .{ .name = "roc_host_suggest_window_size" });
        @export(&hostedSetTargetFps, .{ .name = "roc_host_set_target_fps" });
        @export(&hostedSuggestWindowMinSize, .{ .name = "roc_host_suggest_window_min_size" });
        @export(&hostedMouseSetCursorModeRaw, .{ .name = "roc_mouse_set_cursor_mode_raw" });
        @export(&hostedMouseSetCursorRaw, .{ .name = "roc_mouse_set_cursor_raw" });
        @export(&exportedTilemapDrawRaw, .{ .name = "roc_tilemap_draw_raw" });
        @export(&exportedTilemapLoadTmxRaw, .{ .name = "roc_tilemap_load_tmx_raw" });
        @export(&hostedHttpSend, .{ .name = "roc_http_send" });
    }
}

const RuntimeOptions = struct {
    headless: bool = false,
    headless_frames: u64 = DEFAULT_HEADLESS_FRAMES,
    debug_allocator: bool = false,
    help: bool = false,
    app_args: []const [*:0]u8 = &.{},
    app_args_allocation: ?[][*:0]u8 = null,

    fn deinit(self: RuntimeOptions, allocator: std.mem.Allocator) void {
        if (self.app_args_allocation) |allocation| allocator.free(allocation);
    }
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
        mouse_x: f32,
        mouse_y: f32,
        mouse_delta: raylib.Vec2,
        mouse_wheel: raylib.Vec2,
        text_input: []const u32,
    ) InputSnapshot {
        self.text_input.update(text_input);
        self.retainForRoc();
        return .{
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
    std.debug.print("usage: app [--host-headless] [--host-headless-frames=N] [--host-debug-allocator] [app arguments...]\n", .{});
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
        } else if (std.mem.eql(u8, arg, "--host-debug-allocator")) {
            options.debug_allocator = true;
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

test "runtime options reject malformed reserved host switches" {
    var argv = [_][*:0]u8{ @constCast("app"), @constCast("--host-unknown") };
    try std.testing.expectError(error.InvalidArgument, parseRuntimeOptions(std.testing.allocator, argv.len, &argv));

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
        if (wants_screenshot) {
            if (screenshot_wait) |wait| {
                wait.err = capture.err_out_of_memory;
                wait.ready.set();
            }
        }
        return;
    };
    defer image.deinit();

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

/// Run one Roc render call inside the host-owned raylib frame scope.
/// `defer` closes the frame for both `Ok` and `Err` results.
fn renderFrame(boxed_model: RocBox) RocResult {
    if (active_headless) return callRender(boxed_model);

    const NativeRender = struct {
        model: RocBox,

        fn begin(_: *@This()) void {
            raylib.beginDrawing();
        }

        fn render(self: *@This()) RocResult {
            return callRender(self.model);
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

test "a loader called from render! is rejected" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    const phase = PhaseScope.enter(.render);
    defer phase.leave();
    last_phase_violation = null;
    defer last_phase_violation = null;

    // Reachable from an app today: the loader is an ordinary effect and nothing
    // but the phase says it may not run mid-frame. In a real build this call
    // aborts and never returns; under `zig test` the guard records instead, so
    // what the test can check is that it fired and named the right things.
    const result = hostedTilemapLoadTmxRaw(&roc_host, abi.RocStr.fromSlice("examples/assets/nothing.tmx", &roc_host));
    try std.testing.expect(!result.ok);

    const violation = last_phase_violation orelse return error.OperationWasNotRejected;
    try std.testing.expectEqualStrings("Tilemap.load_tmx!", violation.operation);
    try std.testing.expect(violation.allowed.eql(during_load));
    try std.testing.expectEqual(Phase.render, violation.actual);
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

    _ = hostedDrawLoadRenderTextureRaw(.{ .width = 0, .height = 0 });

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
    }
};

/// Storage for the frame-thread meter. Only read when `alloc_meter_enabled`.
var alloc_meter: AllocMeter = .{ .inner = undefined };
/// Whether `ROC_RAY_ALLOC_STATS` asked for metering on this run.
var alloc_meter_enabled: bool = false;

/// Wrap `inner` in the meter when the environment asks for it, else pass it
/// through untouched so an unmetered run keeps its original allocator vtable.
fn meteredAllocator(inner: std.mem.Allocator) std.mem.Allocator {
    const requested = hostGetEnv(ALLOC_STATS_ENV) orelse return inner;
    if (requested.len == 0 or std.mem.eql(u8, requested, "0")) return inner;
    alloc_meter = .{ .inner = inner };
    alloc_meter_enabled = true;
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
    std.debug.print(
        "[roc-ray-alloc] startup alloc_bytes={d} allocs={d} frees={d} free_bytes={d}\n",
        .{ alloc_meter.alloc_bytes, alloc_meter.alloc_calls, alloc_meter.free_calls, alloc_meter.free_bytes },
    );
    alloc_meter.clearFrame();
}

/// Report and clear one host cycle's metered traffic.
fn reportCycleAllocStats(cycle_index: u64) void {
    if (!alloc_meter_enabled) return;
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
    alloc_meter.clearFrame();
}

fn runNormalApp(roc_host: *RocHost, allocator: std.mem.Allocator, app_config: AppConfig) c_int {
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

    var app_tasks = AppTasks.init(allocator, hostGetEnv(TRACE_TASKS_ENV) != null) catch |err| {
        std.log.err("roc-ray: could not start the task runtime: {s}", .{@errorName(err)});
        return 1;
    };
    defer app_tasks.deinit();
    app_tasks.activate();
    // `Http.send!` drives std.http.Client over the same runtime, so it needs
    // the same handle the task registry holds. Withdrawn before the registry
    // tears the runtime down, so a late send reports a stopped app instead of
    // reaching a dead event loop.
    if (app_tasks.rt) |rt| http_effect.activate(rt, hostGetEnv(TRACE_TASKS_ENV) != null);
    defer http_effect.deactivate();

    const init_result = initModel();
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
        app_tasks.pump(cycle_count, .yield);
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
        const input_snapshot = input.hostState(
            mouse_pos.x,
            mouse_pos.y,
            mouse_delta,
            mouse_wheel,
            text_input,
        );

        last_frame_nanos = now_ns;
        last_wall_nanos = real_ns;
        // One call, before the drawing scope opens. `update!` changes host
        // state directly and spawns tasks while it runs; drawing is refused by
        // the phase guard.
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
        });
        if (update_result.tag == .Err) {
            exit_code = @intCast(update_result.payload_err());
            if (TRACE_HOST) std.log.debug("[HOST] update returned Err({d})", .{exit_code});
            break;
        }
        boxed_model = update_result.payload_ok();
        // Newly spawned tasks run to their first park before the frame is
        // drawn, so their waiting overlaps rendering.
        app_tasks.pump(cycle_count, .yield);

        // This graphical backend schedules one optional presentation for every
        // cycle. A backend that omits it still calls update once for the fresh
        // input above; presentation is not another transition.
        if (callbacks.presentations == 1) {
            const render_result = renderFrame(takeModelForRender(&boxed_model));
            if (render_result.isErr()) {
                exit_code = @intCast(render_result.getErr());
                if (TRACE_HOST) std.log.debug("[HOST] render returned Err({d})", .{exit_code});
                break;
            }
            boxed_model = render_result.getOk();
        }
        drainRetiredResources();
        reportCycleAllocStats(cycle_count);
        cycle_count += 1;

        if (exit_requested) |code| {
            exit_code = @intCast(code);
            break;
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

    var input = InputState.init(roc_host);
    defer input.deinit();

    var app_tasks = AppTasks.init(allocatorFromHost(roc_host), hostGetEnv(TRACE_TASKS_ENV) != null) catch |err| {
        std.log.err("roc-ray: could not start the task runtime: {s}", .{@errorName(err)});
        return 1;
    };
    defer app_tasks.deinit();
    app_tasks.activate();
    // `Http.send!` drives std.http.Client over the same runtime, so it needs
    // the same handle the task registry holds. Withdrawn before the registry
    // tears the runtime down, so a late send reports a stopped app instead of
    // reaching a dead event loop.
    if (app_tasks.rt) |rt| http_effect.activate(rt, hostGetEnv(TRACE_TASKS_ENV) != null);
    defer http_effect.deactivate();

    const init_result = initModel();
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
        // A headless run has no frame pacing and no real clock, but task
        // timers are real time. While a task is live, pace the cycle to the
        // simulated 60 Hz so "18 cycles later" means what it means windowed.
        app_tasks.pump(cycle_count, if (app_tasks.liveCount() != 0) .{ .sleep_ns = HEADLESS_FRAME_NANOS } else .yield);
        stageTaskResults(&app_tasks, &staging, roc_host);
        const callbacks = CycleCallbackSchedule.forInput(true);
        std.debug.assert(callbacks.updates == 1);
        const frame_time: f32 = if (cycle_count == 0) 0 else HEADLESS_FRAME_TIME;
        const timestamp_nanos = cycle_count * HEADLESS_FRAME_NANOS;
        const input_snapshot = input.hostState(
            0,
            0,
            .{ .x = 0, .y = 0 },
            .{ .x = 0, .y = 0 },
            &.{},
        );

        last_frame_nanos = timestamp_nanos;
        // A headless run has no real clock to expose: it exists to produce the
        // same output twice, and a wall clock would be the one thing in the
        // input that differed between runs.
        last_wall_nanos = timestamp_nanos;
        // One call, before the drawing scope opens. `update!` changes host
        // state directly and spawns tasks while it runs; drawing is refused by
        // the phase guard.
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
        });
        if (update_result.tag == .Err) {
            exit_code = @intCast(update_result.payload_err());
            if (TRACE_HOST) std.log.debug("[HOST] update returned Err({d})", .{exit_code});
            break;
        }
        boxed_model = update_result.payload_ok();
        app_tasks.pump(cycle_count, .yield);

        // Headless examples schedule semantic presentation to cover render and
        // resource paths. The host-cycle contract itself permits omission.
        if (callbacks.presentations == 1) {
            const render_result = renderFrame(takeModelForRender(&boxed_model));
            if (render_result.isErr()) {
                exit_code = @intCast(render_result.getErr());
                if (TRACE_HOST) std.log.debug("[HOST] render returned Err({d})", .{exit_code});
                break;
            }
            boxed_model = render_result.getOk();
        }
        drainRetiredResources();
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
        .allocator = meteredAllocator(allocator),
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

    // Startup, not idle: reading an environment variable to decide the window
    // size is a reasonable thing for a config to do, and it works today. It is
    // still before `InitWindow`, so a texture load here would fail for its own
    // reasons rather than because the phase guard caught it.
    const config_phase = PhaseScope.enter(.startup);
    var app_config = app_config_for_host();
    config_phase.leave();
    // The config now carries three Roc strings; `decref` releases all of them.
    defer app_config.decref(&roc_host);

    if (options.headless) {
        return runHeadlessApp(&roc_host, app_config, options.headless_frames);
    }

    return runNormalApp(&roc_host, allocator, app_config);
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
