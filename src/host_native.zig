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
const png = @import("png.zig");
const tilemap_batch = @import("tilemap_batch.zig");
const tmx_loader = @import("tmx_loader.zig");

// Import backend
const raylib = @import("backend_raylib.zig");

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
// boundary, so completions and the recording state arrive as flat records that
// Roc decodes.
const StepFromHost = abi.Update_for_hostArg1;
const UpdateResult = abi.Update_for_hostResult;
const CompletionFromHost = abi.Update_for_hostArg1Completed;
const CaptureFromHost = abi.Update_for_hostArg1Capture;
// Actions never come here: `update` is pure, and the platform's own adapter
// applies them in Roc, through effects that already exist. Only tasks -- the
// work that answers back -- reach the host.
const TaskToHost = abi.Update_for_hostOkTasks;
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
const TEXTURE_UPDATE_OUT_OF_BOUNDS: u8 = 3;
const TEXTURE_UPDATE_BUDGET: u8 = 4;

/// How many bytes of pixel data may be pushed to the GPU in one frame.
///
/// An upload is a synchronous driver call whose cost is proportional to the
/// bytes handed over, so "it is only a commit action" does not make it free.
/// The budget is one 1024x1024 RGBA texture per frame: enough that no
/// reasonable upload is refused, small enough that a loop uploading an atlas
/// every frame is told about it rather than quietly costing the frame.
const MAX_TEXTURE_UPLOAD_BYTES_PER_FRAME: usize = 4 * 1024 * 1024;
var texture_upload_bytes_this_frame: usize = 0;
const TRY_TAG_OK: u8 = 1;
const MAX_HOST_TEXT_FILE_BYTES: usize = 16 * 1024 * 1024;
const HEADLESS_CLIPBOARD_CAPACITY: usize = 4096;

extern fn app_config_for_host() callconv(.c) AppConfig;
extern fn init_for_host() callconv(.c) RocResult;
extern fn update_for_host(arg0: RocBox, arg1: StepFromHost) callconv(.c) UpdateResult;
extern fn render_for_host(arg0: RocBox) callconv(.c) RocResult;
extern fn drop_model_for_host(arg0: RocBox) callconv(.c) void;

/// `kind` codes for a completion. Mirrored in `platform/Program.roc`.
const COMPLETION_SMALL_FILE_READ: u8 = 0;
const COMPLETION_DELAY: u8 = 1;
const COMPLETION_SCREENSHOT_FINISHED: u8 = 2;
const COMPLETION_CLIPBOARD_READ: u8 = 3;
const COMPLETION_FILE_READ: u8 = 4;

/// `kind` codes for a task returned by `update`. Mirrored in `platform/Program.roc`.
const TASK_READ_SMALL_FILE: u8 = 0;
const TASK_DELAY: u8 = 1;
const TASK_SCREENSHOT: u8 = 2;
const TASK_READ_CLIPBOARD: u8 = 3;
const TASK_READ_FILE: u8 = 4;

/// Why an operation on a blob produced no bytes. Mirrored in `platform/File.roc`.
const BLOB_ERR_RELEASED: u8 = 1;
const BLOB_ERR_OUT_OF_BOUNDS: u8 = 2;
const BLOB_ERR_NOT_UTF8: u8 = 3;
const BLOB_ERR_TOO_LARGE: u8 = 4;

/// Read-error codes. Mirrored in `platform/Program.roc`.
///
/// `BUSY` and `UNAVAILABLE` are refusals rather than failures: the host declined
/// to start the work rather than running it on the frame thread.
const READ_ERR_NOT_FOUND: u8 = 1;
const READ_ERR_FAILED: u8 = 2;
const READ_ERR_BUSY: u8 = 3;
const READ_ERR_UNAVAILABLE: u8 = 4;
const READ_ERR_TOO_LARGE: u8 = 5;

/// The only way a delay fails: the host was already holding as many unanswered
/// tasks as it will, so it never started this one. Mirrored in `Program.roc`.
const DELAY_ERR_BUSY: u8 = 1;

/// The most the host will copy into a Roc string in one operation.
///
/// The worker does the reading off-thread, but turning bytes into a `Str`
/// happens on the frame thread -- so without a bound a 16 MiB "async" read
/// still costs a 16 MiB allocation and copy mid-frame, which is most of what
/// moving the read off-thread was supposed to buy.
///
/// One number with one meaning, applied everywhere a copy could be that large:
/// `ReadSmallFile` reports `TooLarge` above it, and so does any blob-to-string
/// copy. `ReadFile` has no such limit *because it makes no such copy* -- the
/// worker's allocation is installed into a blob slot and the app is handed a
/// handle. Reaching past this limit is therefore not a refusal to do the work;
/// it is a signal to use the operation that does not copy.
const MAX_INLINE_READ_BYTES: usize = 64 * 1024;

/// How many host-owned blobs may be live at once.
///
/// Small on purpose. A blob is released by hand, so this is also the bound on
/// what an app that never releases can pin: with the 16 MiB per-file ceiling
/// that is a few hundred megabytes, refused rather than unbounded. An app that
/// wants more should copy what it needs and release.
const MAX_LIVE_BLOBS: usize = 32;

/// Name a failed read in the app's vocabulary.
///
/// A file past the host's per-file ceiling is `TooLarge` rather than
/// `ReadFailed`: nothing went wrong, the host declined a read of that size, and
/// those are different things for an app deciding what to do next.
/// How many bytes a read may take before it is refused as too large.
///
/// A blob read has no per-file ceiling below the host's own, because nothing
/// proportional to the file happens on the frame thread. A small read is
/// delivered as a `Str`, so it stops one byte past the largest string the frame
/// thread will build -- `readFileAlloc` refuses at the limit, and one past is
/// what makes a file of exactly that size succeed.
fn smallReadLimit(deliver_blob: bool) usize {
    return if (deliver_blob) MAX_HOST_TEXT_FILE_BYTES else MAX_INLINE_READ_BYTES + 1;
}

fn readErrorCode(err: anyerror) u8 {
    return switch (err) {
        error.FileNotFound => READ_ERR_NOT_FOUND,
        error.StreamTooLong => READ_ERR_TOO_LARGE,
        else => READ_ERR_FAILED,
    };
}






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
/// indices is all the *data* transfer needs, and neither ring is ever locked.
///
/// The lock below exists for one thing only: deciding whether the worker may
/// go to sleep. An idle app must not burn a core polling, so the worker blocks
/// on a condition variable rather than waking every millisecond; the mutex is
/// what makes "the ring looked empty, so I will sleep" and "I just filled the
/// ring" impossible to interleave. See `wake` and `awaitRequest`.
const EffectWorker = struct {
    /// Power of two so the index wrap is a mask.
    const capacity: usize = 64;
    const mask: usize = capacity - 1;

    /// What the worker was asked to do.
    ///
    /// The two share a ring because they share the property that matters: a
    /// bounded amount of plain-Zig state goes in, slow work happens on this
    /// thread, and a plain-Zig answer comes back.
    const Kind = enum(u8) { read_file, write_png };

    const Request = struct {
        kind: Kind,
        id: u64,
        path: [capture.path_capacity]u8,
        path_len: usize,
        /// Whether the answer is a host-owned blob rather than a Roc string.
        ///
        /// The worker reads a file the same way either way -- it allocates and
        /// fills native memory and knows nothing about Roc. This only says what
        /// the main thread will do with the buffer when it drains the result:
        /// install it into a blob slot, or copy it into a `RocStr` and free it.
        deliver_blob: bool = false,
        /// `write_png`: the framebuffer readback, owned by `allocator` and
        /// freed on this thread once it has been encoded.
        pixels: []u8 = &.{},
        width: u32 = 0,
        height: u32 = 0,
        /// `write_png`: false for the `Capture.screenshot!` effect, which has
        /// no completion to report to and latches its outcome instead.
        for_task: bool = false,
    };

    /// `bytes` is owned by `allocator` until the main thread takes it: either by
    /// copying it into a `RocStr` and freeing it, or -- for a blob -- by moving
    /// the allocation itself into a blob slot without touching its contents.
    const Result = struct {
        kind: Kind,
        id: u64,
        bytes: ?[]u8 = null,
        err: u8 = 0,
        deliver_blob: bool = false,
        for_task: bool = false,
    };

    requests: [capacity]Request = undefined,
    request_write: std.atomic.Value(usize) = .init(0),
    request_read: std.atomic.Value(usize) = .init(0),

    results: [capacity]Result = undefined,
    result_write: std.atomic.Value(usize) = .init(0),
    result_read: std.atomic.Value(usize) = .init(0),

    should_stop: std.atomic.Value(bool) = .init(false),

    /// Guards the sleep decision, and nothing else. Never held across a read.
    idle: std.Io.Mutex = .init,
    /// Signalled when `should_stop` is set or a request is published.
    wakeup: std.Io.Condition = .init,
    /// Signalled when the frame thread takes a result, or on shutdown, so a
    /// worker parked on a full result ring can continue.
    drained: std.Io.Condition = .init,
    /// How many times the worker has decided to sleep.
    ///
    /// Observability only, and the reason it lives here rather than in a test:
    /// nothing else distinguishes "the submission woke a parked worker" from
    /// "the worker had not looked at the ring yet", and only the first of those
    /// exercises the wake protocol at all.
    parks: std.atomic.Value(u64) = .init(0),

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
            // Same protocol as a submission, for the same reason: the flag is
            // published before the lock is taken, so a worker that reaches the
            // sleep decision after this cannot fail to see it, and a worker
            // already asleep is signalled. Queued requests are not serviced,
            // so shutdown costs at most the operation already in flight.
            self.should_stop.store(true, .release);
            self.wake();
            thread.join();
            self.thread = null;
        }
        // The worker has stopped, so both rings belong to this thread again.
        // Everything still in them owns memory nobody will come back for.
        while (self.takeRequest()) |request| {
            if (request.pixels.len != 0) self.allocator.free(request.pixels);
        }
        while (self.takeResult()) |result| {
            if (result.bytes) |bytes| self.allocator.free(bytes);
        }
    }

    /// Nudge the worker out of `awaitRequest`. Frame thread only.
    ///
    /// This is the half of the protocol that makes a lost wakeup impossible.
    /// The caller has already published the state change (a ring index or
    /// `should_stop`) with a release store. Taking and immediately releasing
    /// `idle` orders that publication against the worker's sleep decision:
    ///
    ///   * If the worker already read the predicate under `idle` and found
    ///     nothing, it registered itself as a waiter *before* releasing the
    ///     lock inside `wait`, so this `lock` can only succeed once it is
    ///     parked -- and the `signal` below therefore reaches it.
    ///   * Otherwise the worker takes `idle` after this `unlock`, so it
    ///     observes the published change and never waits at all.
    ///
    /// There is no third case, which is why the wait is never a bare one-shot.
    fn wake(self: *EffectWorker) void {
        const io = mainThreadIo();
        self.idle.lockUncancelable(io);
        self.idle.unlock(io);
        self.wakeup.signal(io);
        // Shutdown has to reach a worker parked on either condition, and this
        // is the only path that sets `should_stop`.
        self.drained.signal(io);
    }

    /// Why a submission was refused, so the caller can report it rather than
    /// dropping the command or running it on the frame thread.
    const Submission = enum { accepted, busy, unavailable };

    /// Queue a read. Frame thread only.
    fn submitReadFile(self: *EffectWorker, id: u64, path: []const u8, deliver_blob: bool) Submission {
        if (!self.accepting) return .unavailable;
        if (path.len > capture.path_capacity) return .unavailable;

        const write = self.request_write.load(.monotonic);
        if (write -% self.request_read.load(.acquire) >= capacity) return .busy;

        const slot = &self.requests[write & mask];
        slot.* = .{ .kind = .read_file, .id = id, .path = undefined, .path_len = path.len, .deliver_blob = deliver_blob };
        // The worker cannot borrow the Roc string the path arrived in.
        @memcpy(slot.path[0..path.len], path);
        self.request_write.store(write +% 1, .release);
        // Only after the request is visible; a refusal wakes nobody, which is
        // what keeps `Busy` and `Unavailable` pure refusals.
        self.wake();
        return .accepted;
    }

    /// Queue a screenshot write. Frame thread only.
    ///
    /// Takes ownership of `pixels` on acceptance, and leaves it with the caller
    /// otherwise -- a refusal must not free a buffer the caller may still want
    /// to write inline.
    fn submitWritePng(
        self: *EffectWorker,
        id: u64,
        path: []const u8,
        pixels: []u8,
        width: u32,
        height: u32,
        for_task: bool,
    ) Submission {
        if (!self.accepting) return .unavailable;
        if (path.len > capture.path_capacity) return .unavailable;

        const write = self.request_write.load(.monotonic);
        if (write -% self.request_read.load(.acquire) >= capacity) return .busy;

        const slot = &self.requests[write & mask];
        slot.* = .{
            .kind = .write_png,
            .id = id,
            .path = undefined,
            .path_len = path.len,
            .pixels = pixels,
            .width = width,
            .height = height,
            .for_task = for_task,
        };
        @memcpy(slot.path[0..path.len], path);
        self.request_write.store(write +% 1, .release);
        self.wake();
        return .accepted;
    }

    /// Pop one request. Worker thread only.
    fn takeRequest(self: *EffectWorker) ?Request {
        const read = self.request_read.load(.monotonic);
        if (read == self.request_write.load(.acquire)) return null;
        const request = self.requests[read & mask];
        self.request_read.store(read +% 1, .release);
        return request;
    }

    /// Pop one result. Frame thread only.
    fn takeResult(self: *EffectWorker) ?Result {
        const read = self.result_read.load(.monotonic);
        if (read == self.result_write.load(.acquire)) return null;
        const result = self.results[read & mask];
        self.result_read.store(read +% 1, .release);
        // A worker parked on a full ring is now free to continue. Signalling
        // only here means the cost is one signal per completed task rather than
        // one per frame.
        if (self.accepting) self.drained.signal(mainThreadIo());
        return result;
    }

    /// Publish a finished result, waiting for room if the ring is full.
    ///
    /// Worker thread only. Waiting is the point: an accepted task has promised
    /// the app exactly one completion, so there is no version of this that may
    /// discard one. Blocking the worker is free -- it has nothing else to do,
    /// and the frame thread is never waiting on it.
    ///
    /// Today the wait is unreachable, because the ring is larger than the
    /// reservation budget in `MAX_TASKS_IN_FLIGHT` and so cannot fill. It is
    /// written anyway so that changing either number is a performance decision
    /// rather than a correctness one.
    fn postResult(self: *EffectWorker, io: std.Io, result: Result) void {
        while (true) {
            const write = self.result_write.load(.monotonic);
            if (write -% self.result_read.load(.acquire) < capacity) {
                self.results[write & mask] = result;
                self.result_write.store(write +% 1, .release);
                return;
            }
            if (self.should_stop.load(.acquire)) {
                // Nobody will ever drain this. Owning the buffer, free it.
                if (result.bytes) |bytes| self.allocator.free(bytes);
                return;
            }
            self.idle.lockUncancelable(io);
            defer self.idle.unlock(io);
            // Re-check under the lock: a drain between the test above and the
            // lock would otherwise park this thread on a ring that has room.
            if (self.result_write.load(.monotonic) -% self.result_read.load(.acquire) >= capacity and
                !self.should_stop.load(.acquire))
            {
                self.drained.waitUncancelable(io, &self.idle);
            }
        }
    }

    /// Block until there is a request to run, or until shutdown. Worker only.
    ///
    /// The predicate -- "shutting down, or the ring is non-empty" -- is read
    /// under `idle` and re-read in a loop, so a spurious wakeup just goes back
    /// to sleep and a real one cannot be missed. See `wake` for the other half.
    /// The lock is released before the caller does any I/O.
    fn awaitRequest(self: *EffectWorker, io: std.Io) ?Request {
        self.idle.lockUncancelable(io);
        defer self.idle.unlock(io);
        while (true) {
            if (self.should_stop.load(.acquire)) return null;
            if (self.takeRequest()) |request| return request;
            // Bumped under `idle`, so a frame thread that has seen it knows the
            // worker is past its last predicate check and cannot miss a signal.
            _ = self.parks.fetchAdd(1, .release);
            self.wakeup.waitUncancelable(io, &self.idle);
        }
    }

    /// The worker loop. Nothing in here may touch Roc.
    fn run(self: *EffectWorker) void {
        // Its own IO: `mainThreadIo` is explicitly single-threaded, and this
        // thread must never reach for it.
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        while (self.awaitRequest(io)) |request| {
            switch (request.kind) {
                .read_file => self.runRead(io, request),
                .write_png => self.runWritePng(io, request),
            }
        }
    }

    /// Read a file whole. Worker thread only.
    fn runRead(self: *EffectWorker, io: std.Io, request: Request) void {
        const path = request.path[0..request.path_len];
        // The allocation the blob path hands to Roc is made here, on this
        // thread, and is filled here. The main thread only ever moves the
        // slice -- which is the entire claim of the feature.
        //
        // A small read stops one byte past what it could deliver rather than
        // reading up to the blob ceiling and then rejecting it: refusing a
        // 16 MiB file should not mean having read 16 MiB first.
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(smallReadLimit(request.deliver_blob))) catch |err| {
            self.postResult(io, .{
                .kind = .read_file,
                .id = request.id,
                .err = readErrorCode(err),
                .deliver_blob = request.deliver_blob,
            });
            return;
        };
        self.postResult(io, .{
            .kind = .read_file,
            .id = request.id,
            .bytes = bytes,
            .deliver_blob = request.deliver_blob,
        });
    }

    /// Encode a framebuffer readback as a PNG and write it. Worker thread only.
    ///
    /// This is the slow half of a screenshot -- deflate over a few megabytes,
    /// plus a directory create and a file write -- and it is the whole reason
    /// the frame thread now only does the readback. Nothing here touches
    /// raylib: the pixels arrived as a plain byte slice and `png` is
    /// deliberately backend-free.
    fn runWritePng(self: *EffectWorker, io: std.Io, request: Request) void {
        defer self.allocator.free(request.pixels);
        const path = request.path[0..request.path_len];

        const encoded = png.encodeRgba(self.allocator, request.pixels, request.width, request.height) catch |err| {
            self.postResult(io, .{
                .kind = .write_png,
                .id = request.id,
                .err = switch (err) {
                    error.OutOfMemory => capture.err_out_of_memory,
                    else => capture.err_write_failed,
                },
                .for_task = request.for_task,
            });
            return;
        };
        defer self.allocator.free(encoded);

        self.postResult(io, .{
            .kind = .write_png,
            .id = request.id,
            .err = writeWholeFile(io, path, encoded),
            .for_task = request.for_task,
        });
    }
};

/// Create the parent directory if needed, then write the file. Any thread.
fn writeWholeFile(io: std.Io, path: []const u8, bytes: []const u8) u8 {
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch return capture.err_write_failed;
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch return capture.err_write_failed;
    return capture.err_none;
}

var effect_worker = EffectWorker{};

/// The clock this frame reported to Roc, so a delay's deadline sits on the
/// timeline the app sees rather than on the wall clock.
var last_frame_nanos: u64 = 0;

/// How many tasks may be accepted but not yet answered.
///
/// This is the only bound in the task system, and it is deliberately on
/// *acceptance* rather than on delivery. A task is accepted only if a
/// reservation is free, and it holds that reservation until its completion is
/// staged. So the amount of deferred work one step can be handed is bounded
/// without any completion ever being dropped -- which is what makes "every
/// accepted task yields exactly one completion" a property of the code rather
/// than a hope.
///
/// Refusing a task is not deferred work: it allocates nothing, does no I/O and
/// touches no table, so refusals are not reserved. Their cost is proportional
/// to the list the app itself submitted, which is the app's own budget to keep.
const MAX_TASKS_IN_FLIGHT: usize = 32;

/// Commands whose result is due once a deadline passes.
///
/// Sized to the reservation budget: an armed timer holds one, so the table
/// cannot fill while a reservation was free to arm it.
const PendingTimer = struct { id: u64, due_nanos: u64 };
var pending_timers: [MAX_TASKS_IN_FLIGHT]PendingTimer = undefined;
var pending_timer_count: usize = 0;

/// Completions gathered for the step being assembled.
///
/// Grows rather than truncating. The normal frame completes nothing and this
/// keeps whatever capacity it reached, so an ordinary frame still allocates
/// nothing; the growable part exists only so that an app which submits more
/// tasks than the host will accept gets a refusal for every one of them,
/// instead of silence for the tail.
const CompletionStaging = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(CompletionFromHost) = .empty,
    /// Reservations held by accepted tasks that have not been answered yet.
    in_flight: usize = 0,

    fn init(allocator: std.mem.Allocator) CompletionStaging {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *CompletionStaging) void {
        self.items.deinit(self.allocator);
    }

    fn count(self: *const CompletionStaging) usize {
        return self.items.items.len;
    }

    /// Claim the right to answer one task on a later step.
    ///
    /// Returns false when the budget is spent, which is the *only* reason the
    /// host ever declines to start work. The caller must then refuse the task
    /// -- it must not start it anyway, and it must not stay silent.
    fn reserve(self: *CompletionStaging) bool {
        if (self.in_flight == MAX_TASKS_IN_FLIGHT) return false;
        self.in_flight += 1;
        return true;
    }

    /// Give back a reservation whose task has now been answered.
    fn finish(self: *CompletionStaging) void {
        std.debug.assert(self.in_flight > 0);
        self.in_flight -= 1;
    }

    fn push(self: *CompletionStaging, item: CompletionFromHost) void {
        // A completion is the only report an app will ever get for its task, so
        // failing to keep it would strand that task forever. There is nothing
        // sensible to do here but fail loudly.
        self.items.append(self.allocator, item) catch {
            @panic("roc-ray: out of memory staging a completion");
        };
    }

    /// A completion that carries nothing Roc has to free.
    ///
    /// Every field the operation does not use is spelled out once here rather
    /// than at each call site, so adding one to the transport record does not
    /// mean editing five constructors that never fill it in.
    fn plain(kind: u8, id: u64, err: u8) CompletionFromHost {
        return .{
            .kind = kind,
            .id = id,
            .err = err,
            .contents = abi.RocStr.empty(),
            .blob = 0,
            .blob_len = 0,
        };
    }

    fn fileRead(self: *CompletionStaging, roc_host: *RocHost, id: u64, err: u8, contents: []const u8) void {
        var item = plain(COMPLETION_SMALL_FILE_READ, id, err);
        if (contents.len != 0) item.contents = abi.RocStr.fromSlice(contents, roc_host);
        self.push(item);
    }

    /// Report a read whose bytes stayed here.
    ///
    /// `token` names a blob slot and `len` describes it; neither is a payload,
    /// which is why this constructor -- unlike `fileRead` -- takes no `RocHost`.
    /// There is nothing to allocate.
    fn blobRead(self: *CompletionStaging, id: u64, err: u8, token: u64, len: usize) void {
        var item = plain(COMPLETION_FILE_READ, id, err);
        item.blob = token;
        item.blob_len = @intCast(len);
        self.push(item);
    }

    fn delayElapsed(self: *CompletionStaging, id: u64, err: u8) void {
        self.push(plain(COMPLETION_DELAY, id, err));
    }

    fn screenshotFinished(self: *CompletionStaging, id: u64, err: u8) void {
        self.push(plain(COMPLETION_SCREENSHOT_FINISHED, id, err));
    }

    fn clipboardRead(self: *CompletionStaging, roc_host: *RocHost, id: u64, err: u8, text: []const u8) void {
        var item = plain(COMPLETION_CLIPBOARD_READ, id, err);
        if (text.len != 0) item.contents = abi.RocStr.fromSlice(text, roc_host);
        self.push(item);
    }

    /// Hand the staged completions to Roc as one list, transferring ownership.
    fn toRocList(self: *CompletionStaging, roc_host: *RocHost) abi.RocList(CompletionFromHost) {
        if (self.count() == 0) return abi.RocList(CompletionFromHost).empty();
        return abi.RocList(CompletionFromHost).fromSlice(self.items.items, roc_host);
    }

    /// Hand this step's completions to Roc and empty the staging area.
    ///
    /// Emptying is the point: the payloads now belong to the list Roc drops, so
    /// releasing them here too would free them twice. Anything staged after this
    /// -- a refused task, a screenshot serviced at the end of this frame -- is
    /// owned by the staging area again and is delivered on the next step.
    fn take(self: *CompletionStaging, roc_host: *RocHost) abi.RocList(CompletionFromHost) {
        const list = self.toRocList(roc_host);
        self.items.clearRetainingCapacity();
        return list;
    }

    /// Release staged completions that never reached Roc.
    fn release(self: *CompletionStaging, roc_host: *RocHost) void {
        for (self.items.items) |item| item.contents.decref(roc_host);
        self.items.clearRetainingCapacity();
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

/// Which of the app's callbacks the host is currently inside.
///
/// Roc capabilities outlive the call that produced them -- a `Draw.Frame` is a
/// value, a texture handle is a value -- and nothing in the type system stops
/// an app from stashing one and reaching for it a frame later. The phase is how
/// the host says when an operation is actually meaningful.
const Phase = enum {
    /// Between callbacks: config, host bookkeeping, capture, shutdown.
    idle,
    /// Inside `init_for_host`, and inside the startup config callback.
    startup,
    /// Inside `update_for_host`, applying the actions `update` returned.
    ///
    /// Note what this is *not* named. The pure reducer has no phase at all,
    /// because it cannot reach the host: `update` is annotated `->` rather than
    /// `=>`, so Roc's effect system rejects any effect call inside it at compile
    /// time. Every host call in this window is therefore an action being
    /// applied, which is a different thing from computing the next model and is
    /// worth a different name.
    commit,
    /// Inside `render_for_host`.
    render,

    /// How the phase is named in a rejection, in the app's own vocabulary.
    fn label(self: Phase) []const u8 {
        return switch (self) {
            .idle => "outside any app callback",
            .startup => "init!",
            .commit => "an action returned by update",
            .render => "render!",
        };
    }
};

/// The phases an operation may be reached from.
///
/// A set rather than a single phase, because the honest answer for most
/// operations is more than one: setting the cursor is meaningful while
/// starting up and while applying an action, and nonsense in between.
const PhaseSet = std.EnumSet(Phase);

/// Loading, allocating or generating a resource. Startup only: all of these
/// block, allocate on the GPU, or both, and a frame is not the place for it.
const during_startup = PhaseSet.initOne(.startup);

/// Drawing, and anything that changes how the draws after it are interpreted.
/// Only defined inside the frame scope the host opens around `render!`.
const during_render = PhaseSet.initOne(.render);

/// Changing host state between frames: cursor, window, audio, releases.
/// Reachable while starting up and while applying an action, and nowhere else.
const during_commit = PhaseSet.initMany(&.{ .startup, .commit });

/// Reading something back. Cheap, allocates nothing, and meaningful wherever
/// the app is running -- but still not from outside a callback entirely.
const during_any_callback = PhaseSet.initMany(&.{ .startup, .commit, .render });

var active_phase: Phase = .idle;

/// Enter a phase for the duration of one call, restoring the previous one.
///
/// Restoring rather than resetting to `idle` keeps nesting honest: the actions
/// `update` applies run inside the update phase, and nothing has to know
/// whether it was entered from the frame loop or from somewhere else.
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

/// Refuse an operation that was reached from the wrong phase.
///
/// This aborts, in every build mode, and that is the deliberate part. Both
/// guarded families are bugs rather than degraded behaviour: a blocking loader
/// called mid-frame reintroduces exactly the stall the task/worker split exists
/// to remove, and a draw call outside `render!` reaches raylib outside the
/// host's `BeginDrawing`/`EndDrawing` scope, where the result is undefined
/// rather than merely misplaced. Neither has a sensible fallback value --
/// returning a blank texture or silently dropping the draw would hide the bug
/// in release while debug shouted about it, which is the worst of both.
///
/// No shipped example trips either guard, so nothing that works today starts
/// aborting; the survey that established this is in the commit message.
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
            " Load it in init! and keep the handle in your model; loading during a frame blocks it."
        else if (allowed.eql(during_render))
            " Drawing is only defined inside the frame scope the host opens around render!."
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
/// Outcome of the most recent serviced screenshot.
///
/// A screenshot is written at the end of the frame that asked for it, so the
/// effect cannot return the write's result. Latching it here lets the next
/// `Capture.screenshot!` report that the previous one failed rather than
/// letting the failure vanish.
var capture_screenshot_result: u8 = capture.err_none;
/// Id of the screenshot task that queued the pending request, if a task did.
///
/// A `Screenshot` task has somewhere to report to, so its outcome becomes a
/// completion on the next step instead of being latched for a later call.
var capture_screenshot_task_id: ?u64 = null;
/// A serviced screenshot task whose completion has not reached Roc yet.
var capture_screenshot_done: ?ScreenshotOutcome = null;
const ScreenshotOutcome = struct { id: u64, err: u8 };
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
/// A headless run reports a focused, non-minimized window. There is no window
/// to ask, and a constant keeps `--headless` output reproducible.
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

/// Bytes a finished `ReadFile` handed over, and the allocator that owns them.
///
/// The allocator travels with the buffer because the two paths that produce one
/// do not share one: the worker allocates from its own handle on the host
/// allocator, while a headless run reads on the frame thread through the Roc
/// environment's. Whoever allocated it is who frees it.
const BlobResource = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
};

fn destroyBlob(resource: *BlobResource) void {
    resource.allocator.free(resource.bytes);
    resource.bytes = &.{};
}

/// Blobs are the one host resource Roc does not hold a `Box` for.
///
/// The other seven heaps are driven by Roc's refcount: the app drops the value
/// and `nativeRocDealloc` routes the free back. A blob handle is a scalar the
/// app copies and drops silently, so there is no refcount to drive anything and
/// `File.Blob.release` is how the app says it is done. See `HostHandleTable`
/// for why that is the honest arrangement rather than a missing feature.
const BlobTable = host_resource.HostHandleTable(BlobResource, MAX_LIVE_BLOBS, 8, destroyBlob);
var blob_table: BlobTable = .{};

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
    capture_screenshot_task_id = null;
    capture_screenshot_done = null;
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

    const outer_target = storeRenderTexture(.headless, 160, 90).?;
    const inner_target = storeRenderTexture(.headless, 80, 45).?;
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginRenderTextureRaw(.{ .resource = outer_target }));
    try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginRenderTextureRaw(.{ .resource = inner_target }));
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

    const target = storeRenderTexture(.headless, 16, 16).?;
    abi.increfBox(@ptrCast(target), SCOPE_STACK_LIMIT);
    for (0..SCOPE_STACK_LIMIT) |_| try std.testing.expectEqual(SCOPE_OK, hostedDrawBeginRenderTextureRaw(.{ .resource = target }));
    try std.testing.expectEqual(SCOPE_LIMIT, hostedDrawBeginRenderTextureRaw(.{ .resource = target }));
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
    try std.testing.expectEqual(SCOPE_UNAVAILABLE, hostedDrawBeginRenderTextureRaw(.{ .resource = @ptrCast(shader) }));
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    const target = storeRenderTexture(.headless, 16, 16).?;
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
    try std.testing.expectEqual(@as(u64, 0), target.target.resource.handle);
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

    const texture = storeTexture(.{ .headless = .{ .width = 2, .height = 2 } }, 2, 2).?;
    hostedAssetsSetTextureFilterRaw(.{ .resource = texture }, 1);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());

    const font = storeFont(.headless).?;
    const loaded_font: abi.DefaultFontOrLoadedFont = .{ .payload = .{ .loaded_font = font }, .tag = .LoadedFont };
    _ = hostedDrawMeasureTextRaw(&roc_host, .{
        .font = loaded_font,
        .text = abi.RocStr.empty(),
        .size = 16,
        .spacing = 1,
    });
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), font_heap.active());

    const shader = storeShader(.headless).?;
    hostedDrawSetShaderFloatRaw(.{ .uniform = .{ .shader = shader, .location = 0 }, .value = 1 });
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());

    const sampler_shader = storeShader(.headless).?;
    const sampler_texture = storeTexture(.{ .headless = .{ .width = 1, .height = 1 } }, 1, 1).?;
    hostedDrawSetShaderTextureRaw(.{
        .texture = .{ .resource = sampler_texture },
        .uniform = .{ .shader = sampler_shader, .location = 0 },
    });
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), shader_heap.active());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
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
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
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
        // No frame loop here to end, so the retirement queue is drained by
        // hand -- and without a frame's budget, since there is no frame to
        // protect and anything left behind reads as a leak.
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
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
    const rejected_texture = storeTexture(.{ .headless = .{ .width = 16, .height = 8 } }, 16, 8).?;
    hostedTilemapDrawRaw(&roc_host, headlessTilemapRequest(&roc_host, rejected_texture, TILEMAP_SELECTOR_ROLE, TILEMAP_ROLE_HIDDEN, false));
    try std.testing.expectEqual(@as(usize, 0), headless_tilemap_tiles);

    const named_texture = storeTexture(.{ .headless = .{ .width = 16, .height = 8 } }, 16, 8).?;
    hostedTilemapDrawRaw(&roc_host, headlessTilemapRequest(&roc_host, named_texture, TILEMAP_SELECTOR_LAYER, 1, false));
    try std.testing.expectEqual(@as(usize, 6), headless_tilemap_tiles);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), texture_heap.active());
}

test "render target texture views report not mutable and release ownership" {
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

    const target = storeRenderTexture(.headless, 4, 4).?;
    const err = hostedAssetsUpdateTextureRaw(&roc_host, .{
        .pixels = abi.RocListWith(Color, false).empty(),
        .texture = .{ .resource = target },
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

test "a frame's texture uploads are metered, and startup's are not" {
    const budget_pixels = MAX_TEXTURE_UPLOAD_BYTES_PER_FRAME / @sizeOf(abi.ColorRgba);
    defer texture_upload_bytes_this_frame = 0;

    {
        // Startup is not a frame: there is nothing to stall, so an app is not
        // asked to split its initial uploads across imaginary ones.
        const scope = PhaseScope.enter(.startup);
        defer scope.leave();
        texture_upload_bytes_this_frame = 0;
        try std.testing.expect(chargeTextureUpload(budget_pixels * 4));
        try std.testing.expectEqual(@as(usize, 0), texture_upload_bytes_this_frame);
    }

    const scope = PhaseScope.enter(.commit);
    defer scope.leave();
    texture_upload_bytes_this_frame = 0;

    // Right up to the budget is fine...
    try std.testing.expect(chargeTextureUpload(budget_pixels));
    // ...and one pixel past it is refused rather than absorbed.
    try std.testing.expect(!chargeTextureUpload(1));
    try std.testing.expectEqual(MAX_TEXTURE_UPLOAD_BYTES_PER_FRAME, texture_upload_bytes_this_frame);

    // A refusal costs nothing, so the next frame starts clear.
    texture_upload_bytes_this_frame = 0;
    try std.testing.expect(chargeTextureUpload(1));
}

test "texture pixel count validates dimensions" {
    try std.testing.expectEqual(@as(?usize, 16), texturePixelCount(4, 4));
    try std.testing.expectEqual(@as(?usize, null), texturePixelCount(0, 4));
    try std.testing.expectEqual(@as(?usize, null), texturePixelCount(4, -1));
}

fn hostedAssetsLoadTextureRaw(host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.AssetsHostLoad_textureRetRecord {
    enforcePhase("Assets.Texture.load!", during_startup);
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
    enforcePhase("Assets.generate_color_texture!", during_startup);
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
    enforcePhase("Assets.generate_checked_texture!", during_startup);
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
    enforcePhase("Assets.Texture.update!", during_any_callback);
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
    if (!chargeTextureUpload(args.pixels.len())) return TEXTURE_UPDATE_BUDGET;
    switch (resource.*) {
        .headless => {},
        .native => |texture| if (!builtin.is_test) raylib.updateTexture(texture, args.pixels.items()),
    }
    return TEXTURE_UPDATE_OK;
}

/// Upload one rectangle of a texture, charged for what it actually covers.
///
/// The reason this exists rather than being a convenience: without it, changing
/// one pixel of an atlas means re-uploading the atlas, and a per-frame budget
/// on whole-texture uploads is just a smaller ceiling on the same waste.
fn hostedAssetsUpdateTextureRegionRaw(host: *RocHost, args: abi.AssetsHostUpdate_texture_regionArgs) callconv(.c) u8 {
    enforcePhase("Assets.Texture.update_region!", during_any_callback);
    defer args.pixels.decref(host);
    defer args.texture.decref(host);

    if (args.width <= 0 or args.height <= 0 or args.x < 0 or args.y < 0) return TEXTURE_UPDATE_OUT_OF_BOUNDS;

    const token = args.texture.resource.handle;
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
    if (!chargeTextureUpload(covered)) return TEXTURE_UPDATE_BUDGET;

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

/// Charge a texture upload against this frame's budget.
///
/// Startup is not metered: it is not a frame, there is nothing to stall, and
/// making an app split its initial uploads across imaginary frames would be
/// pure ceremony. Everywhere else, exceeding the budget is reported rather
/// than absorbed -- an upload the host performed anyway would show up as a
/// frame time nobody asked about.
fn chargeTextureUpload(pixels: usize) bool {
    if (active_phase == .startup) return true;
    const bytes = pixels * @sizeOf(abi.ColorRgba);
    if (texture_upload_bytes_this_frame + bytes > MAX_TEXTURE_UPLOAD_BYTES_PER_FRAME) return false;
    texture_upload_bytes_this_frame += bytes;
    return true;
}

fn exportedAssetsUpdateTextureRaw(args: abi.AssetsHostUpdate_textureArgs) callconv(.c) u8 {
    return hostedAssetsUpdateTextureRaw(activeHost(), args);
}

fn exportedAssetsUpdateTextureRegionRaw(args: abi.AssetsHostUpdate_texture_regionArgs) callconv(.c) u8 {
    return hostedAssetsUpdateTextureRegionRaw(activeHost(), args);
}

fn hostedAssetsSetTextureFilterRaw(texture_owner: abi.AssetsHostTexture, code: u8) callconv(.c) void {
    enforcePhase("Assets.Texture.set_filter!", during_commit);
    defer texture_owner.decref(activeHost());
    if (builtin.is_test) return;
    const texture = nativeTextureForToken(texture_owner.resource.handle) orelse return;
    raylib.setTextureFilter(texture, code);
}

fn hostedAssetsSetTextureWrapRaw(texture_owner: abi.AssetsHostTexture, code: u8) callconv(.c) void {
    enforcePhase("Assets.Texture.set_wrap!", during_commit);
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
    enforcePhase("Draw.RenderTexture.load!", during_startup);
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
    enforcePhase("Draw.Shader.load!", during_startup);
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
    enforcePhase("Draw.Shader.from_source!", during_startup);
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
    enforcePhase("Draw.with_render_texture!", during_render);
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
    enforcePhase("Draw.with_render_texture!", during_render);
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
    enforcePhase("Draw.Shader.uniform_*!", during_startup);
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
    const texture = nativeTextureForToken(args.texture.resource.handle) orelse return;
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

fn hostedDrawLoadFontRaw(host: *RocHost, args: abi.DrawHostLoad_fontArgs) callconv(.c) abi.DrawHostLoad_fontRetRecord {
    enforcePhase("Draw.load_font!", during_startup);
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
    enforcePhase("Draw.measure_text!", during_any_callback);
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
    enforcePhase("Text.prepare!", during_startup);
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
    const texture = nativeTextureForToken(args.texture.resource.handle) orelse return;
    raylib.drawTexture(texture, args);
}

fn hostedDrawTextureQuadRaw(args: abi.DrawHostDraw_texture_quadArgs) callconv(.c) void {
    enforcePhase("Draw.projective_texture!", during_render);
    defer args.texture.decref(activeHost());
    if (active_headless) return;
    const texture = nativeTextureForToken(args.texture.resource.handle) orelse return;
    raylib.drawTextureQuad(texture, args);
}

/// Global flag for deferred exit request (exit after current frame completes)
var exit_requested: ?i64 = null;

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

/// Resolve a blob handle, or null if it names no live buffer.
///
/// Null covers every way a handle can be wrong at once -- never valid, already
/// released, or naming a slot that has since been reused -- because the app has
/// the same thing to do about all of them, and because the alternative is
/// reading memory that has been freed.
fn blobBytes(handle: u64) ?[]const u8 {
    const resource = blob_table.get(handle) orelse return null;
    return resource.bytes;
}

fn blobSliceError(err: u8) abi.FileHostBlob_sliceRetRecord {
    return .{ .contents = abi.RocStr.empty(), .err = err };
}

/// Copy a bounded range of a blob into a Roc string.
///
/// The only place blob bytes are copied, and it copies exactly the range the
/// app named. The size limit is `MAX_INLINE_READ_BYTES` -- the same one
/// `ReadSmallFile` is held to, because this is the same cost on the same
/// thread. A range past the end is refused rather than clamped: a short read
/// that looks complete is worse than one that says so.
fn hostedFileBlobSlice(roc_host: *RocHost, args: abi.FileHostBlob_sliceArgs) callconv(.c) abi.FileHostBlob_sliceRetRecord {
    enforcePhase("File.Blob.slice_to_str!", during_any_callback);
    const bytes = blobBytes(args.handle) orelse return blobSliceError(BLOB_ERR_RELEASED);

    const end = std.math.add(u64, args.offset, args.count) catch return blobSliceError(BLOB_ERR_OUT_OF_BOUNDS);
    if (end > bytes.len) return blobSliceError(BLOB_ERR_OUT_OF_BOUNDS);
    if (args.count > MAX_INLINE_READ_BYTES) return blobSliceError(BLOB_ERR_TOO_LARGE);

    const slice = bytes[@intCast(args.offset)..@intCast(end)];
    // A blob is bytes; a `Str` is not. Handing Roc invalid UTF-8 would make
    // every later string operation on it undefined.
    if (!std.unicode.utf8ValidateSlice(slice)) return blobSliceError(BLOB_ERR_NOT_UTF8);

    return .{
        .contents = if (slice.len == 0) abi.RocStr.empty() else abi.RocStr.fromSlice(slice, roc_host),
        .err = 0,
    };
}

fn exportedFileBlobSlice(args: abi.FileHostBlob_sliceArgs) callconv(.c) abi.FileHostBlob_sliceRetRecord {
    return hostedFileBlobSlice(activeHost(), args);
}

/// Read one byte of a blob, leaving the rest where it is.
fn hostedFileBlobByte(args: abi.FileHostBlob_byteArgs) callconv(.c) abi.FileHostBlob_byteRetRecord {
    enforcePhase("File.Blob.byte!", during_any_callback);
    const bytes = blobBytes(args.handle) orelse return .{ .byte = 0, .err = BLOB_ERR_RELEASED };
    if (args.offset >= bytes.len) return .{ .byte = 0, .err = BLOB_ERR_OUT_OF_BOUNDS };
    return .{ .byte = bytes[@intCast(args.offset)], .err = 0 };
}

/// Free the buffer a handle names.
///
/// The slot's generation moves on, so the handle the app still holds -- and any
/// copy of it -- resolves to nothing from here on rather than to whatever read
/// is given the slot next. Releasing an unknown handle is not an error; the
/// app asked for these bytes to be gone, and they are.
fn hostedFileReleaseBlob(handle: u64) callconv(.c) void {
    enforcePhase("File.Blob.release!", during_any_callback);
    _ = blob_table.release(handle);
}

fn hostedTilemapLoadTmxRaw(roc_host: *RocHost, path_arg: abi.RocStr) callconv(.c) TilemapLoadTmxRawResult {
    enforcePhase("Tilemap.load_tmx!", during_startup);
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
    enforcePhase("Program.exit", during_commit);
    exit_requested = @as(i64, code);
}

fn hostedSetScreenSize(args: abi.HostHostSet_screen_sizeArgs) callconv(.c) u8 {
    enforcePhase("App.Startup.set_screen_size!", during_startup);
    if (active_headless) {
        headless_screen_width = positiveI32(args.width, headless_screen_width);
        headless_screen_height = positiveI32(args.height, headless_screen_height);
    } else {
        raylib.setWindowSize(args.width, args.height);
    }
    return TRY_TAG_OK;
}

fn hostedSetTargetFps(fps: i32) callconv(.c) void {
    enforcePhase("App.Startup.set_target_fps!", during_startup);
    if (active_headless) return;
    raylib.setTargetFps(fps);
}

fn hostedSetWindowMinSize(args: abi.HostHostSet_window_min_sizeArgs) callconv(.c) void {
    enforcePhase("Window.set_window_min_size", during_commit);
    if (active_headless) return;
    raylib.setWindowMinSize(nonNegativeCInt(args.width), nonNegativeCInt(args.height));
}

fn hostedSetExitKey(key_code: i32) callconv(.c) void {
    enforcePhase("Keys.set_exit_key", during_commit);
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
    enforcePhase("Capture.screenshot!", during_any_callback);
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
    enforcePhase("Capture.start!", during_any_callback);
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
    enforcePhase("Capture.set_virtual_mouse", during_any_callback);
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
    enforcePhase("Capture.stop!", during_any_callback);
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
    enforcePhase("Capture.status!", during_any_callback);
    return .{
        .status = capture_session.status,
        .err = capture_session.failure,
        .frames = capture_session.captured_frames,
        .dropped = capture_session.dropped_frames,
    };
}

/// The recording state sampled onto every step.
///
/// A pure `update` cannot ask for this, and asking would cost a host call on
/// every frame regardless of whether anything is recording. It is four scalars,
/// so it rides along on the step record instead.
fn captureStateForStep() CaptureFromHost {
    return .{
        .status = capture_session.status,
        .err = capture_session.failure,
        .frames = capture_session.captured_frames,
        .dropped = capture_session.dropped_frames,
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

fn hostedSetClipboardText(roc_host: *RocHost, text_arg: abi.RocStr) callconv(.c) void {
    enforcePhase("Window.set_clipboard_text", during_commit);
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
    enforcePhase("Mouse.set_cursor_mode", during_commit);
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
    enforcePhase("Mouse.set_cursor", during_commit);
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
    enforcePhase("Random.i32!", during_any_callback);
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
    enforcePhase("Audio.gen_tone!", during_startup);
    if (headlessMode()) {
        const sound = storeSound(.headless) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .sound = sound, .err = RESOURCE_ERR_NONE };
    }
    const sound = raylib.genTone(args.freq, args.ms) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeSound(.{ .native = sound }) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .sound = stored, .err = RESOURCE_ERR_NONE };
}

fn hostedAudioGenSound(args: abi.AudioHostGen_soundArgs) callconv(.c) abi.AudioHostGen_soundRetRecord {
    enforcePhase("Audio.gen_sound!", during_startup);
    if (headlessMode()) {
        const sound = storeSound(.headless) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
        return .{ .sound = sound, .err = RESOURCE_ERR_NONE };
    }
    const sound = raylib.genSound(args) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_FAILED };
    const stored = storeSound(.{ .native = sound }) orelse return .{ .sound = invalidResourceHandle(), .err = RESOURCE_ERR_LIMIT };
    return .{ .sound = stored, .err = RESOURCE_ERR_NONE };
}

fn hostedAudioLoadSound(host: *RocHost, path_arg: abi.RocStr) callconv(.c) abi.AudioHostLoad_soundRetRecord {
    enforcePhase("Audio.load_sound!", during_startup);
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
    enforcePhase("Audio.load_music!", during_startup);
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
    enforcePhase("Audio.Sound.play!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    if (builtin.is_test) return;
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.playSound(sound),
    }
}

fn hostedAudioStop(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.stop!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.stopSound(sound),
    }
}

fn hostedAudioPause(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.pause!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.pauseSound(sound),
    }
}

fn hostedAudioResume(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.resume!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.resumeSound(sound),
    }
}

fn hostedAudioIsPlaying(handle: *u64) callconv(.c) bool {
    enforcePhase("Audio.Sound.is_playing!", during_any_callback);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return false;
    return switch (resource.*) {
        .headless => false,
        .native => |sound| raylib.isSoundPlaying(sound),
    };
}

fn hostedAudioSetVolume(handle: *u64, volume: f32) callconv(.c) void {
    enforcePhase("Audio.Sound.set_volume!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.setSoundVolume(sound, volume),
    }
}

fn hostedAudioSetPitch(handle: *u64, pitch: f32) callconv(.c) void {
    enforcePhase("Audio.Sound.set_pitch!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.setSoundPitch(sound, pitch),
    }
}

fn hostedAudioSetPan(handle: *u64, pan: f32) callconv(.c) void {
    enforcePhase("Audio.Sound.set_pan!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| raylib.setSoundPan(sound, pan),
    }
}

fn hostedAudioPlayMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.play!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.playMusic(music),
    }
}

fn hostedAudioStopMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.stop!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.stopMusic(music),
    }
}

fn hostedAudioPauseMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.pause!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.pauseMusic(music),
    }
}

fn hostedAudioResumeMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.resume!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.resumeMusic(music),
    }
}

fn hostedAudioSetMusicVolume(handle: *u64, volume: f32) callconv(.c) void {
    enforcePhase("Audio.Music.set_volume!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.setMusicVolume(music, volume),
    }
}

fn hostedAudioSetMusicPitch(handle: *u64, pitch: f32) callconv(.c) void {
    enforcePhase("Audio.Music.set_pitch!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.setMusicPitch(music, pitch),
    }
}

fn hostedAudioSetMusicPan(handle: *u64, pan: f32) callconv(.c) void {
    enforcePhase("Audio.Music.set_pan!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.setMusicPan(music, pan),
    }
}

fn hostedAudioSetMusicLooping(handle: *u64, looping: bool) callconv(.c) void {
    enforcePhase("Audio.Music.set_looping!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |*music| raylib.setMusicLooping(music, looping),
    }
}

fn hostedAudioIsMusicPlaying(handle: *u64) callconv(.c) bool {
    enforcePhase("Audio.Music.is_playing!", during_any_callback);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return false;
    return switch (resource.*) {
        .headless => false,
        .native => |music| raylib.isMusicPlaying(music),
    };
}

fn hostedAudioSeekMusic(handle: *u64, seconds: f32) callconv(.c) void {
    enforcePhase("Audio.Music.seek!", during_commit);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| raylib.seekMusic(music, seconds),
    }
}

fn hostedAudioMusicLength(handle: *u64) callconv(.c) f32 {
    enforcePhase("Audio.Music.length!", during_any_callback);
    defer releaseResourceBox(activeHost(), handle);
    if (builtin.is_test) return 0;
    const resource = music_heap.get(handle.*) orelse return 0;
    return switch (resource.*) {
        .headless => 0,
        .native => |music| raylib.musicLength(music),
    };
}

fn hostedAudioMusicTimePlayed(handle: *u64) callconv(.c) f32 {
    enforcePhase("Audio.Music.time_played!", during_any_callback);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return 0;
    return switch (resource.*) {
        .headless => 0,
        .native => |music| raylib.musicTimePlayed(music),
    };
}

fn hostedAudioSetMasterVolume(volume: f32) callconv(.c) void {
    enforcePhase("Audio.set_master_volume!", during_commit);
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
    // driver calls. There is no frame left to protect, so no budget either.
    drainRetiredResourcesUpTo(std.math.maxInt(usize));

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
    // Deliberately not asserted. Every other heap is emptied by Roc dropping
    // its last reference, so a survivor there is a lifecycle bug; a blob is
    // released by hand, and an app that keeps one until it exits has done
    // nothing wrong. Freeing them here is what makes "release it later" a
    // choice rather than a leak -- but it is worth saying out loud, because
    // holding a blob is holding the whole file.
    if (blob_table.active() != 0) {
        std.log.warn(
            "roc-ray freed {d} blob(s) at shutdown that the app never released",
            .{blob_table.active()},
        );
    }
    blob_table.deinitAll();
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
        @export(&exportedFileBlobSlice, .{ .name = "roc_file_blob_slice" });
        @export(&hostedFileBlobByte, .{ .name = "roc_file_blob_byte" });
        @export(&hostedFileReleaseBlob, .{ .name = "roc_file_release_blob" });
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
/// rather than a raylib query -- `--headless` output has to be reproducible run
/// to run, and asking a window that does not exist would not be.
fn windowState() WindowSnapshot {
    if (active_headless) {
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
/// result installs a new owned model reference. `update` runs once per frame,
/// so this applies once per call rather than once per frame.
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
    // The actions `update` returns are applied by the platform before this
    // call returns, so they run inside this scope too -- which is why an
    // action's effect is checked against the update phase and not against idle.
    const phase = PhaseScope.enter(.commit);
    defer phase.leave();
    return update_for_host(takeModel(boxed_model), step);
}

/// Execute the tasks returned by one `update` call and release the list.
///
/// A read goes to the worker and is answered on a later step. If the worker is
/// absent or its slots are full the task is refused *immediately* with
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
/// A screenshot and a clipboard read are main-thread work by nature -- one
/// needs the framebuffer, the other the windowing backend -- so they are
/// serviced in this cycle and answered on the next. Neither is slow.
///
/// Every task in the list yields exactly one completion -- accepted or not --
/// so an app never waits forever for an id it will never see. Completions
/// staged here land on the *next* step, because this step's list has already
/// been handed to Roc.
///
/// Admission is the whole shape of this loop. A task is started only once a
/// reservation is in hand, so the host is never holding more deferred work than
/// it can report; and a task that cannot get one is refused rather than
/// silently dropped. Refusals are not reserved, so a saturated host answers a
/// list of any length.
fn dispatchTasks(staging: *CompletionStaging, roc_host: *RocHost, tasks: abi.RocList(TaskToHost)) void {
    defer {
        if (tasks.hasOneRef()) {
            for (tasks.allocationItems()) |item| item.decref(roc_host);
        }
        tasks.decref(roc_host);
    }

    for (tasks.items()) |task| {
        if (!staging.reserve()) {
            refuseTask(staging, roc_host, task);
            continue;
        }
        // The reservation is released here for anything answered in this
        // cycle, and by whichever stage delivers the completion otherwise.
        if (startTask(staging, roc_host, task)) staging.finish();
    }
}

/// Start one reserved task. Returns true when it was answered in this cycle.
fn startTask(staging: *CompletionStaging, roc_host: *RocHost, task: TaskToHost) bool {
    return switch (task.kind) {
        TASK_READ_SMALL_FILE => submitRead(staging, roc_host, task.id, task.path.asSlice(), false),
        TASK_READ_FILE => submitRead(staging, roc_host, task.id, task.path.asSlice(), true),
        TASK_DELAY => armTimer(task.id, task.millis),
        TASK_SCREENSHOT => blk: {
            const err = beginScreenshotTask(task.id, task.path.asSlice()) orelse break :blk false;
            staging.screenshotFinished(task.id, err);
            break :blk true;
        },
        TASK_READ_CLIPBOARD => blk: {
            stageClipboardRead(staging, roc_host, task.id);
            break :blk true;
        },
        // The host and the platform are built together, so this is not a newer
        // app talking to an older host -- it is transport disagreeing with
        // itself, and every id in this batch is now unaccounted for.
        else => std.debug.panic("roc-ray: unknown task kind {d}", .{task.kind}),
    };
}

/// Report a task the host would not start, in the completion it asked for.
///
/// Answering with the wrong kind would be worse than not answering at all: an
/// app waiting on `FileRead` must not have its id retired by a `SmallFileRead`.
fn refuseTask(staging: *CompletionStaging, roc_host: *RocHost, task: TaskToHost) void {
    switch (task.kind) {
        TASK_READ_SMALL_FILE => stageReadError(staging, roc_host, task.id, READ_ERR_BUSY, false),
        TASK_READ_FILE => stageReadError(staging, roc_host, task.id, READ_ERR_BUSY, true),
        TASK_DELAY => staging.delayElapsed(task.id, DELAY_ERR_BUSY),
        TASK_SCREENSHOT => staging.screenshotFinished(task.id, capture.err_already_recording),
        TASK_READ_CLIPBOARD => staging.clipboardRead(roc_host, task.id, READ_ERR_UNAVAILABLE, ""),
        else => std.debug.panic("roc-ray: unknown task kind {d}", .{task.kind}),
    }
}

/// Queue a screenshot, or refuse it with a capture error code.
///
/// Returns null when the request was accepted: the framebuffer is read at the
/// end of this frame -- the same instant `Capture.screenshot!` reads it -- so
/// the pixels are the ones the app just drew, and only the report waits for the
/// next step. The sandbox check is the same one the effect uses, so a path that
/// escapes the output directory is still refused rather than rewritten.
fn beginScreenshotTask(id: u64, path: []const u8) ?u8 {
    const validation = capture.validateRelativePath(path);
    if (validation != capture.err_none) return validation;

    // Headless runs have no framebuffer to read, so the request is validated
    // and then reported as done rather than writing a file of zeroes. Answering
    // in the same cycle also keeps CI output identical between runs.
    if (headlessMode()) return capture.err_none;

    // A request already queued this frame has not been serviced yet, and there
    // is only one slot. Refuse rather than silently discarding the first path.
    if (capture_screenshot_pending) return capture.err_already_recording;

    // Likewise a serviced request whose outcome has not been staged yet:
    // accepting now would overwrite the older result, and the app would hear
    // about one of its two screenshots twice and the other never.
    if (capture_screenshot_done != null) return capture.err_already_recording;

    if (!storeCapturePath(&capture_screenshot_path, &capture_screenshot_path_len, path)) {
        return capture.err_path_invalid;
    }
    capture_screenshot_pending = true;
    capture_screenshot_task_id = id;
    return null;
}

/// Stage the completion for a screenshot serviced at the end of a past frame.
///
/// Runs before this step's tasks are dispatched, so the single outcome slot is
/// always empty by the time a new screenshot can be accepted.
fn stageCaptureResults(staging: *CompletionStaging) void {
    const done = capture_screenshot_done orelse return;
    capture_screenshot_done = null;
    staging.screenshotFinished(done.id, done.err);
    staging.finish();
}

/// Record the outcome of the screenshot just serviced.
///
/// A task has somewhere to report to, so its outcome becomes a completion on
/// the next step. `Capture.screenshot!` has nowhere to report to until it is
/// called again, so its outcome is latched, as it always was.
fn reportScreenshotResult(err: u8) void {
    if (capture_screenshot_task_id) |id| {
        capture_screenshot_task_id = null;
        capture_screenshot_done = .{ .id = id, .err = err };
        return;
    }
    capture_screenshot_result = err;
}

/// Read the clipboard on the calling thread and stage the completion.
///
/// The windowing backend only answers on the thread that owns the window, and
/// the read is a pointer copy rather than I/O, so there is nothing to move off
/// the frame thread. One step of latency is the cost of `update` being pure.
fn stageClipboardRead(staging: *CompletionStaging, roc_host: *RocHost, id: u64) void {
    if (headlessMode()) {
        if (!headless_clipboard_set) {
            staging.clipboardRead(roc_host, id, READ_ERR_UNAVAILABLE, "");
            return;
        }
        staging.clipboardRead(roc_host, id, 0, headless_clipboard[0..headless_clipboard_len]);
        return;
    }

    // The pointer belongs to the windowing backend: it is null when the
    // clipboard is empty or holds non-text content, must never be freed, and is
    // invalidated by the next clipboard call -- so copy it out now.
    const text = raylib.getClipboardText() orelse {
        staging.clipboardRead(roc_host, id, READ_ERR_UNAVAILABLE, "");
        return;
    };

    // The clipboard is arbitrary content from outside the app -- another
    // process decides how big it is -- and turning it into a `Str` is a copy
    // and a UTF-8 scan on this thread. Cap it at the same size a small file
    // read is capped at, and for the same reason.
    const contents = std.mem.span(text);
    if (contents.len > MAX_INLINE_READ_BYTES) {
        staging.clipboardRead(roc_host, id, READ_ERR_TOO_LARGE, "");
        return;
    }
    staging.clipboardRead(roc_host, id, 0, contents);
}

/// Hand one read to the worker, or answer it in this cycle if it was refused.
///
/// `deliver_blob` decides which completion the app will be looking for, and a
/// refusal has to use the same one: an app waiting on `FileRead` must not be
/// answered with `SmallFileRead` because the request ring happened to be full.
/// Returns true when the read was answered in this cycle rather than queued.
fn submitRead(staging: *CompletionStaging, roc_host: *RocHost, id: u64, path: []const u8, deliver_blob: bool) bool {
    if (headlessMode()) {
        readFileNow(staging, roc_host, id, path, deliver_blob);
        return true;
    }
    switch (effect_worker.submitReadFile(id, path, deliver_blob)) {
        .accepted => return false,
        .busy => stageReadError(staging, roc_host, id, READ_ERR_BUSY, deliver_blob),
        .unavailable => stageReadError(staging, roc_host, id, READ_ERR_UNAVAILABLE, deliver_blob),
    }
    return true;
}

/// Report a read that produced no bytes, in whichever completion it asked for.
fn stageReadError(staging: *CompletionStaging, roc_host: *RocHost, id: u64, err: u8, deliver_blob: bool) void {
    if (deliver_blob) {
        staging.blobRead(id, err, 0, 0);
    } else {
        staging.fileRead(roc_host, id, err, "");
    }
}

/// Install a finished read's buffer as a blob and report the handle.
///
/// This is the operation the whole feature is about, and it is deliberately
/// this short: a slice moves into a slot. Nothing is copied, nothing is
/// allocated for Roc, and the cost does not depend on how big the file was.
///
/// Takes ownership of `bytes`. With no slot free the buffer is freed here and
/// the read is refused with `Busy` -- holding memory no handle names would be a
/// leak, and evicting a live blob would break a handle the app may still use.
fn stageBlobRead(staging: *CompletionStaging, id: u64, allocator: std.mem.Allocator, bytes: []u8) void {
    const token = blob_table.insert(.{ .allocator = allocator, .bytes = bytes }) orelse {
        allocator.free(bytes);
        staging.blobRead(id, READ_ERR_BUSY, 0, 0);
        return;
    };
    staging.blobRead(id, 0, token, bytes.len);
}

/// Read on the calling thread and stage the completion. Headless only.
///
/// The blob path runs here too, and installs exactly the same way, so a
/// headless run and a windowed one differ in which thread allocated the buffer
/// and in nothing else the app can observe.
fn readFileNow(staging: *CompletionStaging, roc_host: *RocHost, id: u64, path: []const u8, deliver_blob: bool) void {
    const allocator = allocatorFromHost(roc_host);
    const bytes = std.Io.Dir.cwd().readFileAlloc(mainThreadIo(), path, allocator, .limited(smallReadLimit(deliver_blob))) catch |err| {
        stageReadError(staging, roc_host, id, readErrorCode(err), deliver_blob);
        return;
    };
    if (deliver_blob) {
        stageBlobRead(staging, id, allocator, bytes);
        return;
    }
    defer allocator.free(bytes);
    staging.fileRead(roc_host, id, 0, bytes);
}

/// Record a delay so its result can be delivered once the deadline passes.
///
/// Never answers in this cycle, so it always returns false. The table is sized
/// to the reservation budget and the caller holds one, so it cannot be full --
/// a delay that got this far is always armed.
fn armTimer(id: u64, millis: u64) bool {
    std.debug.assert(pending_timer_count < pending_timers.len);
    // `millis` comes from the app, so saturate rather than wrap: a wrapped
    // deadline fires immediately, which looks like a delay that did not work.
    const delay_nanos = std.math.mul(u64, millis, std.time.ns_per_ms) catch std.math.maxInt(u64);
    pending_timers[pending_timer_count] = .{ .id = id, .due_nanos = last_frame_nanos +| delay_nanos };
    pending_timer_count += 1;
    return false;
}

/// Stage a completion for every timer whose deadline has passed.
fn expireTimers(staging: *CompletionStaging, now_nanos: u64) void {
    var index: usize = 0;
    while (index < pending_timer_count) {
        if (pending_timers[index].due_nanos <= now_nanos) {
            staging.delayElapsed(pending_timers[index].id, 0);
            staging.finish();
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
/// thread -- which is what keeps `roc_alloc` single-threaded. Drains everything
/// the worker has finished: each of those results is an accepted task holding a
/// reservation, and there are at most `MAX_TASKS_IN_FLIGHT` of those.
///
/// The two paths part company here, and the difference is the feature: a small
/// read is copied into a `RocStr` and its buffer freed, while a blob read moves
/// the worker's allocation into a slot and copies nothing. Only the first is
/// proportional to the file, which is why only the first is capped.
fn stageWorkerResults(staging: *CompletionStaging, roc_host: *RocHost) void {
    while (true) {
        const result = effect_worker.takeResult() orelse return;

        if (result.kind == .write_png) {
            // A screenshot asked for by the effect has no completion to go to;
            // it latches, exactly as it did when the write was inline. Set the
            // latch directly rather than through `reportScreenshotResult`,
            // which would hand this outcome to whichever task happens to be
            // queued now. Only the task path holds a reservation.
            if (!result.for_task) {
                capture_screenshot_result = result.err;
                continue;
            }
            staging.screenshotFinished(result.id, result.err);
            staging.finish();
            continue;
        }

        defer staging.finish();
        const bytes = result.bytes orelse {
            stageReadError(staging, roc_host, result.id, result.err, result.deliver_blob);
            continue;
        };
        if (result.deliver_blob) {
            stageBlobRead(staging, result.id, effect_worker.allocator, bytes);
            continue;
        }
        // The read stopped at the ceiling, so anything that arrives here fits.
        std.debug.assert(bytes.len <= MAX_INLINE_READ_BYTES);
        defer effect_worker.allocator.free(bytes);
        staging.fileRead(roc_host, result.id, 0, bytes);
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
    capture_screenshot_task_id = null;
    capture_screenshot_done = null;
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
        if (wants_screenshot) reportScreenshotResult(capture.err_out_of_memory);
        return;
    };
    defer image.deinit();

    if (wants_screenshot) {
        writeScreenshot(image, capture_screenshot_path[0..capture_screenshot_path_len]);
    }

    if (!wants_frame) return;

    if (capture_session.width != image.width() or capture_session.height != image.height()) {
        image.resize(capture_session.width, capture_session.height);
    }

    writeRecordingFrame(image);
    finishRecordingAtFrameCap();
}

/// Hand a screenshot to the worker, or write it here if there is no worker.
///
/// The readback above had to happen on this thread -- it is a GL operation, and
/// only inside the drawing scope. Everything after it is CPU work on a plain
/// byte buffer, so it goes to the worker: encoding a 1080p PNG is tens of
/// milliseconds, which is several dropped frames spent on a file the app is not
/// waiting for.
///
/// The pixels are copied rather than moved because the readback buffer belongs
/// to the graphics backend, which frees it on this thread. A memcpy is the
/// price of not having the worker call into raylib, and it is a small fraction
/// of the encode it replaces.
fn writeScreenshot(image: raylib.CaptureImage, path: []const u8) void {
    const task_id = capture_screenshot_task_id;

    var resolved_storage: [capture.path_capacity]u8 = undefined;
    const resolved = capture.joinOutputPath(&resolved_storage, captureOutputDir(), path) orelse {
        reportScreenshotResult(capture.err_write_failed);
        return;
    };

    const source = image.pixels();
    if (effect_worker.accepting) submit: {
        const pixels = effect_worker.allocator.alloc(u8, source.len) catch break :submit;
        @memcpy(pixels, source);
        switch (effect_worker.submitWritePng(
            task_id orelse 0,
            resolved,
            pixels,
            image.width(),
            image.height(),
            task_id != null,
        )) {
            .accepted => {
                // The outcome now arrives as a worker result. Clear the task id
                // so a second screenshot this frame is correlated to itself.
                capture_screenshot_task_id = null;
                return;
            },
            .busy, .unavailable => effect_worker.allocator.free(pixels),
        }
    }

    // No worker, or it would not take this: writing here is slow but correct,
    // and it is what headless runs and a failed thread spawn already do.
    reportScreenshotResult(writeCaptureImage(image, path, null));
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
/// Called at the end of a frame, which is the point of the whole arrangement:
/// releasing the final reference happens inside the pure `update`, and a GPU
/// unload there is an effect in a function that is supposed to have none.
fn drainRetiredResources() void {
    drainRetiredResourcesUpTo(MAX_RESOURCE_RETIREMENTS_PER_FRAME);
}

/// Destroy up to `limit` retired resources across every heap.
fn drainRetiredResourcesUpTo(limit: usize) void {
    var budget = limit;
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








test "staged completions become one Roc list, and an idle step allocates none" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    // The ordinary frame completes nothing, so it must allocate nothing.
    var idle = CompletionStaging.init(std.testing.allocator);
    defer idle.deinit();
    const empty = idle.toRocList(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), empty.items().len);
    empty.decref(&roc_host);

    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
    staging.fileRead(&roc_host, 7, 0, "a payload long enough to need the heap");
    staging.delayElapsed(9, 0);

    const list = staging.toRocList(&roc_host);
    try std.testing.expectEqual(@as(usize, 2), list.items().len);
    try std.testing.expectEqual(COMPLETION_SMALL_FILE_READ, list.items()[0].kind);
    try std.testing.expectEqual(@as(u64, 9), list.items()[1].id);

    // Roc consumes the list in the real loop; this stands in for that. A leak
    // reported by std.testing.allocator means a payload escaped.
    for (list.allocationItems()) |item| item.contents.decref(&roc_host);
    list.decref(&roc_host);
}

test "releasing staged completions frees payloads that never reach Roc" {
    // The path where update fails before the step is delivered.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
    staging.fileRead(&roc_host, 1, 0, "contents the staging area still owns");
    staging.fileRead(&roc_host, 2, 0, "and a second one for good measure");
    staging.release(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), staging.count());
}

test "the budget bounds what is accepted, not what is delivered" {
    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();

    var taken: usize = 0;
    while (taken < MAX_TASKS_IN_FLIGHT) : (taken += 1) {
        try std.testing.expect(staging.reserve());
    }
    // Saturated: the next task cannot be started...
    try std.testing.expect(!staging.reserve());

    // ...but the staging area still takes every refusal, because a refusal is
    // the only thing that stops an app waiting on that id forever.
    var refused: usize = 0;
    while (refused < MAX_TASKS_IN_FLIGHT + 8) : (refused += 1) {
        staging.delayElapsed(refused, DELAY_ERR_BUSY);
    }
    try std.testing.expectEqual(MAX_TASKS_IN_FLIGHT + 8, staging.count());
}

test "every task in an oversized batch is answered exactly once" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    pending_timer_count = 0;
    last_frame_nanos = 0;
    defer pending_timer_count = 0;

    // More delays than the host will hold at once.
    const batch_len = MAX_TASKS_IN_FLIGHT + 11;
    var tasks: [batch_len]TaskToHost = undefined;
    for (&tasks, 0..) |*task, index| {
        task.* = .{ .kind = TASK_DELAY, .id = index, .path = abi.RocStr.empty(), .millis = 1_000 };
    }

    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
    dispatchTasks(&staging, &roc_host, abi.RocList(TaskToHost).fromSlice(&tasks, &roc_host));

    // The excess is refused now; the rest is armed and will elapse later.
    try std.testing.expectEqual(MAX_TASKS_IN_FLIGHT, pending_timer_count);
    try std.testing.expectEqual(batch_len - MAX_TASKS_IN_FLIGHT, staging.count());
    try std.testing.expectEqual(MAX_TASKS_IN_FLIGHT, staging.in_flight);

    // Union the two sets: every id the app submitted is accounted for once.
    var seen = [_]bool{false} ** batch_len;
    for (staging.items.items) |item| {
        try std.testing.expectEqual(DELAY_ERR_BUSY, item.err);
        try std.testing.expect(!seen[item.id]);
        seen[item.id] = true;
    }
    for (pending_timers[0..pending_timer_count]) |timer| {
        try std.testing.expect(!seen[timer.id]);
        seen[timer.id] = true;
    }
    for (seen) |answered| try std.testing.expect(answered);

    staging.release(&roc_host);
}

test "timers expire once" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    pending_timer_count = 0;
    last_frame_nanos = 0;
    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
    // Arming is what dispatch does after reserving; expiry gives the
    // reservation back, so the two have to be paired here as well.
    try std.testing.expect(staging.reserve());
    _ = armTimer(1, 10);
    try std.testing.expect(staging.reserve());
    _ = armTimer(2, 30);

    expireTimers(&staging, 15 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), staging.count());
    try std.testing.expectEqual(@as(u64, 1), staging.items.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), pending_timer_count);

    expireTimers(&staging, 40 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), pending_timer_count);
    staging.release(&roc_host);
}

test "an absurd delay saturates its deadline instead of wrapping to the past" {
    pending_timer_count = 0;
    last_frame_nanos = 1_000;
    _ = armTimer(1, std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), pending_timers[0].due_nanos);
    pending_timer_count = 0;
}

test "a read above the inline cap is refused rather than copied on the frame thread" {
    // The worker reads off-thread, but turning bytes into a Str happens here.
    // Without the cap a 16 MiB read still costs a 16 MiB copy mid-frame, which
    // is most of what moving the read off-thread was supposed to buy.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    const oversized = try std.testing.allocator.alloc(u8, MAX_INLINE_READ_BYTES + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');

    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
    if (oversized.len > MAX_INLINE_READ_BYTES) {
        staging.fileRead(&roc_host, 1, READ_ERR_TOO_LARGE, "");
    } else {
        staging.fileRead(&roc_host, 1, 0, oversized);
    }

    try std.testing.expectEqual(READ_ERR_TOO_LARGE, staging.items.items[0].err);
    // Nothing was copied: the completion carries an empty string.
    try std.testing.expectEqual(@as(usize, 0), staging.items.items[0].contents.asSlice().len);
    staging.release(&roc_host);
}

/// An allocator that reports how many bytes it was asked for.
///
/// It wraps a real allocator rather than standing in for one: the memory is
/// genuinely allocated and genuinely freed, so `std.testing.allocator`
/// underneath still fails a leak, and the count is of work that actually
/// happened. Installed as the Roc environment's allocator, it measures exactly
/// the thing the blob path claims not to do.
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

test "completing a large read installs a handle instead of copying the file" {
    // The claim under test, stated as a measurement: finishing a 16 MiB read
    // costs the frame thread no allocation proportional to the file -- and, on
    // the same instrument, the small-file path costs exactly one.
    const file_bytes: usize = 16 * 1024 * 1024;

    var counter = CountingAllocator{ .inner = std.testing.allocator };
    var roc_env = abi.RocEnv{ .allocator = counter.allocator(), .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer blob_table.deinitAll();

    // Stands in for the worker thread, which allocates and fills the buffer
    // before the frame thread ever sees it. A different allocator on purpose:
    // whatever the frame thread does shows up in `counter` and nowhere else.
    const worker_bytes = try std.testing.allocator.alloc(u8, file_bytes);
    @memset(worker_bytes, 'z');
    const worker_ptr = worker_bytes.ptr;

    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
    counter.allocated_bytes = 0;
    stageBlobRead(&staging, 1, std.testing.allocator, worker_bytes);

    try std.testing.expectEqual(@as(usize, 0), counter.allocated_bytes);
    try std.testing.expectEqual(@as(u8, 0), staging.items.items[0].err);
    try std.testing.expectEqual(@as(u64, file_bytes), staging.items.items[0].blob_len);
    try std.testing.expectEqual(@as(usize, 0), staging.items.items[0].contents.asSlice().len);

    // Installed, not copied: what Roc's handle names is the worker's own
    // allocation, at the same address.
    const token = staging.items.items[0].blob;
    try std.testing.expectEqual(worker_ptr, blob_table.get(token).?.bytes.ptr);

    // The control. A 64 KiB small-file completion moves its payload through
    // the Roc allocator, so the zero above is a result and not a broken meter.
    const inline_bytes = try std.testing.allocator.alloc(u8, MAX_INLINE_READ_BYTES);
    defer std.testing.allocator.free(inline_bytes);
    @memset(inline_bytes, 'a');
    counter.allocated_bytes = 0;
    staging.fileRead(&roc_host, 2, 0, inline_bytes);
    try std.testing.expect(counter.allocated_bytes >= MAX_INLINE_READ_BYTES);

    staging.release(&roc_host);
    try std.testing.expect(blob_table.release(token));
    try std.testing.expectEqual(@as(usize, 0), blob_table.active());
}

test "a released blob answers Released rather than reading freed memory" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer blob_table.deinitAll();

    const payload = "bytes the host is holding for the app";
    const owned = try std.testing.allocator.dupe(u8, payload);

    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
    stageBlobRead(&staging, 1, std.testing.allocator, owned);
    const token = staging.items.items[0].blob;
    staging.release(&roc_host);

    const whole = hostedFileBlobSlice(&roc_host, .{ .handle = token, .offset = 0, .count = payload.len });
    try std.testing.expectEqual(@as(u8, 0), whole.err);
    try std.testing.expectEqualStrings(payload, whole.contents.asSlice());
    whole.contents.decref(&roc_host);

    // Releasing frees the storage now -- `std.testing.allocator` fails this
    // test if it did not -- and every later use of the handle is refused.
    hostedFileReleaseBlob(token);
    try std.testing.expectEqual(@as(usize, 0), blob_table.active());
    try std.testing.expectEqual(BLOB_ERR_RELEASED, hostedFileBlobSlice(&roc_host, .{ .handle = token, .offset = 0, .count = 1 }).err);
    try std.testing.expectEqual(BLOB_ERR_RELEASED, hostedFileBlobByte(.{ .handle = token, .offset = 0 }).err);

    // Releasing again is not an error, and must not disturb whatever has since
    // been given the slot.
    hostedFileReleaseBlob(token);

    const replacement = try std.testing.allocator.dupe(u8, "a different file entirely");
    var later = CompletionStaging.init(std.testing.allocator);
    defer later.deinit();
    stageBlobRead(&later, 2, std.testing.allocator, replacement);
    const fresh = later.items.items[0].blob;
    later.release(&roc_host);
    try std.testing.expect(fresh != token);

    // The stale handle names the same slot the replacement now occupies. The
    // generation is the only thing keeping the two apart.
    try std.testing.expectEqual(BLOB_ERR_RELEASED, hostedFileBlobSlice(&roc_host, .{ .handle = token, .offset = 0, .count = 1 }).err);
    try std.testing.expectEqual(@as(u8, 0), hostedFileBlobSlice(&roc_host, .{ .handle = fresh, .offset = 0, .count = 0 }).err);
    hostedFileReleaseBlob(fresh);
}

test "copying out of a blob is bounded, checked, and never silently short" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer blob_table.deinitAll();

    // Big enough to ask for more than the host will copy in one go, with a
    // stray byte near the front that is not valid UTF-8.
    const owned = try std.testing.allocator.alloc(u8, MAX_INLINE_READ_BYTES + 16);
    @memset(owned, 'a');
    owned[4] = 0xff;

    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
    stageBlobRead(&staging, 1, std.testing.allocator, owned);
    const token = staging.items.items[0].blob;
    staging.release(&roc_host);
    defer hostedFileReleaseBlob(token);

    // A range that runs past the end is refused rather than clamped: a short
    // read that looks complete is the failure that gets shipped.
    try std.testing.expectEqual(BLOB_ERR_OUT_OF_BOUNDS, hostedFileBlobSlice(&roc_host, .{ .handle = token, .offset = owned.len - 2, .count = 4 }).err);
    try std.testing.expectEqual(BLOB_ERR_OUT_OF_BOUNDS, hostedFileBlobSlice(&roc_host, .{ .handle = token, .offset = 8, .count = std.math.maxInt(u64) }).err);

    // Bounds first, then the copy limit: the whole blob is in range but larger
    // than the frame thread will copy at once.
    try std.testing.expectEqual(BLOB_ERR_TOO_LARGE, hostedFileBlobSlice(&roc_host, .{ .handle = token, .offset = 0, .count = owned.len }).err);

    // A `Str` has to be UTF-8, so a range that is not is refused rather than
    // handed over to be misinterpreted later.
    try std.testing.expectEqual(BLOB_ERR_NOT_UTF8, hostedFileBlobSlice(&roc_host, .{ .handle = token, .offset = 0, .count = 8 }).err);

    const preview = hostedFileBlobSlice(&roc_host, .{ .handle = token, .offset = 5, .count = 8 });
    try std.testing.expectEqual(@as(u8, 0), preview.err);
    try std.testing.expectEqualStrings("aaaaaaaa", preview.contents.asSlice());
    preview.contents.decref(&roc_host);

    // One byte, without copying anything else.
    const byte = hostedFileBlobByte(.{ .handle = token, .offset = 4 });
    try std.testing.expectEqual(@as(u8, 0), byte.err);
    try std.testing.expectEqual(@as(u8, 0xff), byte.byte);
    try std.testing.expectEqual(BLOB_ERR_OUT_OF_BOUNDS, hostedFileBlobByte(.{ .handle = token, .offset = owned.len }).err);
}

test "a full blob table refuses the read rather than holding what nothing names" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer blob_table.deinitAll();

    // One completion per read, and a step carries at most its own budget, so
    // each read gets a staging area of its own rather than sharing one.
    var filled: usize = 0;
    while (filled < MAX_LIVE_BLOBS) : (filled += 1) {
        const owned = try std.testing.allocator.dupe(u8, "held");
        var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
        stageBlobRead(&staging, filled, std.testing.allocator, owned);
        try std.testing.expectEqual(@as(u8, 0), staging.items.items[0].err);
        staging.release(&roc_host);
    }
    try std.testing.expectEqual(MAX_LIVE_BLOBS, blob_table.active());

    // The refused read's buffer is freed here rather than held by nothing:
    // `std.testing.allocator` is what proves it.
    const refused = try std.testing.allocator.dupe(u8, "no slot for this");
    var full = CompletionStaging.init(std.testing.allocator);
    defer full.deinit();
    stageBlobRead(&full, 999, std.testing.allocator, refused);
    try std.testing.expectEqual(COMPLETION_FILE_READ, full.items.items[0].kind);
    try std.testing.expectEqual(READ_ERR_BUSY, full.items.items[0].err);
    try std.testing.expectEqual(@as(u64, 0), full.items.items[0].blob);
    try std.testing.expectEqual(MAX_LIVE_BLOBS, blob_table.active());
    full.release(&roc_host);
}

test "a headless read delivers a blob by the same path a worker result does" {
    // Headless runs the read on this thread for determinism, but it must still
    // hand back a handle rather than a string, or CI would exercise a different
    // feature from the one a desktop run does.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer blob_table.deinitAll();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = "read on the frame thread, delivered as a handle";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blob.txt", .data = payload });

    var path_buffer: [capture.path_capacity]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, testing_tmp_prefix ++ "{s}/blob.txt", .{tmp.sub_path});

    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
    readFileNow(&staging, &roc_host, 3, path, true);
    try std.testing.expectEqual(COMPLETION_FILE_READ, staging.items.items[0].kind);
    try std.testing.expectEqual(@as(u8, 0), staging.items.items[0].err);
    try std.testing.expectEqual(@as(u64, payload.len), staging.items.items[0].blob_len);

    const token = staging.items.items[0].blob;
    try std.testing.expectEqualStrings(payload, blob_table.get(token).?.bytes);
    hostedFileReleaseBlob(token);

    // A read that fails still answers on the blob path -- an app waiting for
    // `FileRead` must never be answered with `SmallFileRead`.
    readFileNow(&staging, &roc_host, 4, testing_tmp_prefix ++ "definitely-not-here.txt", true);
    try std.testing.expectEqual(COMPLETION_FILE_READ, staging.items.items[1].kind);
    try std.testing.expectEqual(READ_ERR_NOT_FOUND, staging.items.items[1].err);
    staging.release(&roc_host);
}

test "taking a step's completions hands them over and empties the staging area" {
    // The list belongs to Roc after this, so releasing the staging area must
    // not free the same payloads a second time -- and anything staged after the
    // handover is a completion for the *next* step, not this one.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
    staging.fileRead(&roc_host, 1, 0, "contents long enough to reach the heap");

    const list = staging.take(&roc_host);
    try std.testing.expectEqual(@as(usize, 1), list.items().len);
    try std.testing.expectEqual(@as(usize, 0), staging.count());

    // Stands in for Roc consuming the step.
    for (list.allocationItems()) |item| item.contents.decref(&roc_host);
    list.decref(&roc_host);

    staging.delayElapsed(2, 0);
    try std.testing.expectEqual(@as(usize, 1), staging.count());
    staging.release(&roc_host);
}

test "a screenshot task that escapes the output directory is refused, not rewritten" {
    defer {
        capture_screenshot_task_id = null;
        capture_screenshot_pending = false;
    }

    // The sandbox check runs first, so the refusal becomes a completion rather
    // than a file appearing beside the example source.
    const refusal = beginScreenshotTask(4, "../escaped.png") orelse return error.TestExpectedRefusal;
    try std.testing.expectEqual(capture.err_path_escapes, refusal);
    try std.testing.expectEqual(@as(?u64, null), capture_screenshot_task_id);

    // A valid path is accepted. Tests run headless, where there is no
    // framebuffer to read, so it is answered at once instead of at frame end.
    const accepted = beginScreenshotTask(5, "scene.png") orelse return error.TestExpectedImmediateAnswer;
    try std.testing.expectEqual(capture.err_none, accepted);
    try std.testing.expectEqual(@as(?u64, null), capture_screenshot_task_id);
}

test "a serviced screenshot task answers on the next step" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer {
        capture_screenshot_task_id = null;
        capture_screenshot_done = null;
        capture_screenshot_result = capture.err_none;
    }

    // The frame that asked carries no completion for it: the write happens at
    // the end of that frame, after its step has already gone to Roc.
    capture_screenshot_task_id = 9;
    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
    // The accepted task holds a reservation until its outcome is staged.
    try std.testing.expect(staging.reserve());
    stageCaptureResults(&staging);
    try std.testing.expectEqual(@as(usize, 0), staging.count());

    reportScreenshotResult(capture.err_write_failed);
    // A task reports through its completion, so nothing is latched for the
    // `Capture.screenshot!` effect to pick up later.
    try std.testing.expectEqual(capture.err_none, capture_screenshot_result);

    stageCaptureResults(&staging);
    try std.testing.expectEqual(@as(usize, 1), staging.count());
    try std.testing.expectEqual(COMPLETION_SCREENSHOT_FINISHED, staging.items.items[0].kind);
    try std.testing.expectEqual(@as(u64, 9), staging.items.items[0].id);
    try std.testing.expectEqual(capture.err_write_failed, staging.items.items[0].err);

    // Exactly one completion per accepted task, so the next step reports none
    // and the reservation has been given back.
    stageCaptureResults(&staging);
    try std.testing.expectEqual(@as(usize, 1), staging.count());
    try std.testing.expectEqual(@as(usize, 0), staging.in_flight);
    staging.release(&roc_host);
}

test "a clipboard read is serviced in the cycle it was dispatched in" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer {
        headless_clipboard_len = 0;
        headless_clipboard_set = false;
    }

    headless_clipboard_len = 0;
    headless_clipboard_set = false;

    var empty = CompletionStaging.init(std.testing.allocator);
    defer empty.deinit();
    stageClipboardRead(&empty, &roc_host, 1);
    try std.testing.expectEqual(COMPLETION_CLIPBOARD_READ, empty.items.items[0].kind);
    try std.testing.expectEqual(READ_ERR_UNAVAILABLE, empty.items.items[0].err);
    empty.release(&roc_host);

    const text = "pasted from the scripted clipboard";
    @memcpy(headless_clipboard[0..text.len], text);
    headless_clipboard_len = text.len;
    headless_clipboard_set = true;

    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
    stageClipboardRead(&staging, &roc_host, 2);
    try std.testing.expectEqual(@as(u64, 2), staging.items.items[0].id);
    try std.testing.expectEqual(@as(u8, 0), staging.items.items[0].err);
    try std.testing.expectEqualStrings(text, staging.items.items[0].contents.asSlice());
    staging.release(&roc_host);
}

test "a saturated worker refuses with Busy rather than running work inline" {
    // Running it here would stall the frame, which is what the split exists to
    // prevent. A refusal is still a completion, so the app is never left
    // waiting for an id that will never come back.
    var worker = EffectWorker{};
    worker.allocator = std.testing.allocator;
    try std.testing.expectEqual(EffectWorker.Submission.unavailable, worker.submitReadFile(1, "x", false));

    worker.accepting = true;
    var accepted: usize = 0;
    while (accepted < EffectWorker.capacity) : (accepted += 1) {
        try std.testing.expectEqual(EffectWorker.Submission.accepted, worker.submitReadFile(accepted, "x", false));
    }
    try std.testing.expectEqual(EffectWorker.Submission.busy, worker.submitReadFile(9999, "x", false));
}

/// Where `std.testing.tmpDir` puts its directory, relative to the test's cwd.
///
/// The worker resolves paths against `cwd`, so a test file has to be named the
/// way the worker will look for it.
const testing_tmp_prefix = ".zig-cache/tmp/";

/// Spin until the worker answers, or give up.
///
/// The deadline is the assertion: with a lost wakeup the worker sleeps forever
/// and nothing ever arrives, so "it answered at all" is the property under test.
fn awaitWorkerResult(worker: *EffectWorker) !EffectWorker.Result {
    var waited: usize = 0;
    while (waited < 5_000) : (waited += 1) {
        if (worker.takeResult()) |result| return result;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    return error.WorkerNeverAnswered;
}

/// Spin until the worker has gone to sleep at least `count` times.
fn awaitWorkerParked(worker: *EffectWorker, count: u64) !void {
    var waited: usize = 0;
    while (waited < 5_000) : (waited += 1) {
        if (worker.parks.load(.acquire) >= count) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    return error.WorkerNeverParked;
}

test "a submission wakes a blocked worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A real file, so the result the worker posts owns real storage. A value
    // built with `std.mem.zeroes` would carry a null buffer and could not tell
    // a correct free from a missing one.
    const payload = "the frame thread never read this";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "read.txt", .data = payload });

    var path_buffer: [capture.path_capacity]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, testing_tmp_prefix ++ "{s}/read.txt", .{tmp.sub_path});

    var worker = EffectWorker{};
    worker.start(std.testing.allocator);
    defer worker.stop();
    try std.testing.expect(worker.thread != null);

    // Wait for the worker to be genuinely asleep first. Without this the
    // submission can land before the worker ever looks at the ring, and the
    // test would pass even with no wakeup at all.
    try awaitWorkerParked(&worker, 1);

    try std.testing.expectEqual(EffectWorker.Submission.accepted, worker.submitReadFile(7, path, false));

    const result = try awaitWorkerResult(&worker);
    defer std.testing.allocator.free(result.bytes.?);
    try std.testing.expectEqual(@as(u64, 7), result.id);
    try std.testing.expectEqual(@as(u8, 0), result.err);
    try std.testing.expectEqualStrings(payload, result.bytes.?);
}

test "a blob read is filled by the worker and installed by the frame thread" {
    // End to end across the thread boundary: the buffer Roc ends up with is
    // the one the worker allocated, and the frame thread only moved it.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer blob_table.deinitAll();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = "allocated off the frame thread and never copied onto it";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blob.txt", .data = payload });

    var path_buffer: [capture.path_capacity]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, testing_tmp_prefix ++ "{s}/blob.txt", .{tmp.sub_path});

    var worker = EffectWorker{};
    worker.start(std.testing.allocator);
    defer worker.stop();
    try std.testing.expectEqual(EffectWorker.Submission.accepted, worker.submitReadFile(11, path, true));

    const result = try awaitWorkerResult(&worker);
    try std.testing.expect(result.deliver_blob);
    try std.testing.expectEqualStrings(payload, result.bytes.?);
    const worker_ptr = result.bytes.?.ptr;

    var staging = CompletionStaging.init(std.testing.allocator);
    defer staging.deinit();
    stageBlobRead(&staging, result.id, worker.allocator, result.bytes.?);
    const token = staging.items.items[0].blob;
    staging.release(&roc_host);

    try std.testing.expectEqual(worker_ptr, blob_table.get(token).?.bytes.ptr);
    hostedFileReleaseBlob(token);
}

test "shutting down with work still queued terminates and frees what it produced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "read.txt", .data = "queued work" });

    var path_buffer: [capture.path_capacity]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, testing_tmp_prefix ++ "{s}/read.txt", .{tmp.sub_path});

    var worker = EffectWorker{};
    worker.start(std.testing.allocator);

    var queued: u64 = 0;
    while (queued < EffectWorker.capacity) : (queued += 1) {
        try std.testing.expectEqual(EffectWorker.Submission.accepted, worker.submitReadFile(queued, path, false));
    }

    // Wait for the first answer without consuming it, so the shutdown below has
    // finished buffers to release and not just an empty ring.
    var waited: usize = 0;
    while (worker.result_write.load(.acquire) == 0 and waited < 5_000) : (waited += 1) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(worker.result_write.load(.acquire) > 0);

    // Nothing was ever drained, so every buffer the worker allocated is still
    // owned here. `std.testing.allocator` fails this test if `stop` leaks one,
    // and hangs it if the worker misses the shutdown signal.
    worker.stop();
    try std.testing.expect(worker.thread == null);
    try std.testing.expect(worker.takeResult() == null);
}

test "phases restore what they interrupted rather than falling back to idle" {
    try std.testing.expectEqual(Phase.idle, active_phase);

    const startup = PhaseScope.enter(.startup);
    try std.testing.expectEqual(Phase.startup, active_phase);
    startup.leave();
    try std.testing.expectEqual(Phase.idle, active_phase);

    // Actions run inside the update call that produced them, so a nested scope
    // has to land back in update and not in idle -- otherwise the phase after
    // an action would be wrong for the rest of the call.
    const update = PhaseScope.enter(.commit);
    const nested = PhaseScope.enter(.render);
    try std.testing.expectEqual(Phase.render, active_phase);
    nested.leave();
    try std.testing.expectEqual(Phase.commit, active_phase);
    update.leave();
    try std.testing.expectEqual(Phase.idle, active_phase);
}

test "a startup-only loader called from render! is rejected" {
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
    try std.testing.expect(violation.allowed.eql(during_startup));
    try std.testing.expectEqual(Phase.render, violation.actual);
}

test "a drawing primitive called from update is rejected" {
    const phase = PhaseScope.enter(.commit);
    defer phase.leave();
    last_phase_violation = null;
    defer last_phase_violation = null;
    defer blend_scope_count = 0;

    _ = hostedDrawBeginBlendRaw(.{ .arg0 = 1 });

    const violation = last_phase_violation orelse return error.OperationWasNotRejected;
    try std.testing.expectEqualStrings("Draw.with_blend_mode!", violation.operation);
    try std.testing.expect(violation.allowed.eql(during_render));
    try std.testing.expectEqual(Phase.commit, violation.actual);
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
    try std.testing.expect(violation.allowed.eql(during_startup));
}

test "an operation allowed in several phases is accepted in each of them" {
    last_phase_violation = null;
    defer last_phase_violation = null;

    for ([_]Phase{ .startup, .commit }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        enforcePhase("Mouse.set_cursor", during_commit);
        try std.testing.expectEqual(@as(?PhaseViolation, null), last_phase_violation);
    }

    // ...and rejected everywhere else, including the phase it is nearest to.
    for ([_]Phase{ .idle, .render }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        last_phase_violation = null;
        enforcePhase("Mouse.set_cursor", during_commit);
        const violation = last_phase_violation orelse return error.OperationWasNotRejected;
        try std.testing.expectEqual(phase, violation.actual);
    }
}

test "a rejection names every phase the operation was allowed in" {
    var buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "init! or an action returned by update",
        describePhases(during_commit, &buffer),
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
/// seeds its model with `Input.empty` and waits for the first `Step`.
fn initModel() RocResult {
    if (TRACE_HOST) std.log.debug("[HOST] Calling init_for_host...", .{});
    const phase = PhaseScope.enter(.startup);
    defer phase.leave();
    const init_result = init_for_host();
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

    const init_result = initModel();
    if (init_result.isErr()) {
        const err_code = init_result.getErr();
        if (TRACE_HOST) std.log.debug("[HOST] init returned Err({d})", .{err_code});
        return initExitCode(err_code);
    }

    var boxed_model = init_result.getOk();
    var exit_code: i32 = 0;
    var frame_count: u64 = 0;

    // Outlives the frame: a task dispatched at the end of one cycle answers on
    // the next, so its completion waits here in between.
    var staging = CompletionStaging.init(allocatorFromHost(roc_host));
    defer staging.deinit();
    defer staging.release(roc_host);

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
        const input_snapshot = input.hostState(
            mouse_pos.x,
            mouse_pos.y,
            mouse_delta,
            mouse_wheel,
            text_input,
        );

        last_frame_nanos = now_ns;
        texture_upload_bytes_this_frame = 0;
        stageWorkerResults(&staging, roc_host);
        expireTimers(&staging, now_ns);
        stageCaptureResults(&staging);

        // One call, before the drawing scope opens. `update` is pure, so it
        // could not draw in any case; the platform applies its actions before
        // this returns, which is where the effects they replace used to run.
        const update_result = updateOnce(&boxed_model, .{
            .input = input_snapshot,
            .window = windowState(),
            .time = .{
                .frame_count = frame_count,
                .timestamp_nanos = now_ns,
                .elapsed_seconds = frame_time,
            },
            .completed = staging.take(roc_host),
            .capture = captureStateForStep(),
        });
        if (update_result.tag == .Err) {
            exit_code = @intCast(update_result.payload_err());
            if (TRACE_HOST) std.log.debug("[HOST] update returned Err({d})", .{exit_code});
            break;
        }
        const next = update_result.payload_ok();
        boxed_model = next.model;
        dispatchTasks(&staging, roc_host, next.tasks);

        const render_result = renderFrame(takeModelForRender(&boxed_model));
        if (render_result.isErr()) {
            exit_code = @intCast(render_result.getErr());
            if (TRACE_HOST) std.log.debug("[HOST] render returned Err({d})", .{exit_code});
            break;
        }

        boxed_model = render_result.getOk();
        drainRetiredResources();
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

    const init_result = initModel();
    if (init_result.isErr()) {
        const err_code = init_result.getErr();
        if (TRACE_HOST) std.log.debug("[HOST] init returned Err({d})", .{err_code});
        return initExitCode(err_code);
    }

    var boxed_model = init_result.getOk();
    var exit_code: i32 = 0;
    var frame_count: u64 = 0;

    // Outlives the frame: a task dispatched at the end of one cycle answers on
    // the next, so its completion waits here in between.
    var staging = CompletionStaging.init(allocatorFromHost(roc_host));
    defer staging.deinit();
    defer staging.release(roc_host);

    while (frame_count < frames) : (frame_count += 1) {
        const frame_time: f32 = if (frame_count == 0) 0 else HEADLESS_FRAME_TIME;
        const timestamp_nanos = frame_count * HEADLESS_FRAME_NANOS;
        const input_snapshot = input.hostState(
            0,
            0,
            .{ .x = 0, .y = 0 },
            .{ .x = 0, .y = 0 },
            &.{},
        );

        last_frame_nanos = timestamp_nanos;
        texture_upload_bytes_this_frame = 0;
        stageWorkerResults(&staging, roc_host);
        expireTimers(&staging, timestamp_nanos);
        stageCaptureResults(&staging);

        // One call, before the drawing scope opens. `update` is pure, so it
        // could not draw in any case; the platform applies its actions before
        // this returns, which is where the effects they replace used to run.
        const update_result = updateOnce(&boxed_model, .{
            .input = input_snapshot,
            .window = windowState(),
            .time = .{
                .frame_count = frame_count,
                .timestamp_nanos = timestamp_nanos,
                .elapsed_seconds = frame_time,
            },
            .completed = staging.take(roc_host),
            .capture = captureStateForStep(),
        });
        if (update_result.tag == .Err) {
            exit_code = @intCast(update_result.payload_err());
            if (TRACE_HOST) std.log.debug("[HOST] update returned Err({d})", .{exit_code});
            break;
        }
        const next = update_result.payload_ok();
        boxed_model = next.model;
        dispatchTasks(&staging, roc_host, next.tasks);

        const render_result = renderFrame(takeModelForRender(&boxed_model));
        if (render_result.isErr()) {
            exit_code = @intCast(render_result.getErr());
            if (TRACE_HOST) std.log.debug("[HOST] render returned Err({d})", .{exit_code});
            break;
        }

        boxed_model = render_result.getOk();
        drainRetiredResources();
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
        // No frame loop here to end, so the retirement queue is drained by
        // hand -- and without a frame's budget, since there is no frame to
        // protect and anything left behind reads as a leak.
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        active_headless = false;
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
