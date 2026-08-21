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
// boundary, so responses and the recording state arrive as flat records that
// Roc decodes.
const InputFromHost = abi.Update_for_hostArg1;
const UpdateResult = abi.Update_for_hostResult;
/// The raw, host-shaped terminal outcome. This crosses the worker boundary,
/// but contains no Roc callback or any other Roc-owned closure.
const RawResponse = abi.Update_for_hostArg1ResponsesRaw;
/// The Roc-only response bridge. `deliver` moves from the outgoing request,
/// through the main-thread pending table, and back to Roc in this envelope.
const ResponseEnvelope = abi.Update_for_hostArg1Responses;
const CaptureFromHost = abi.Update_for_hostArg1Capture;
// Commands never come here: `update` is pure, and the platform adapter applies
// them through hosted effects before returning. Only requests cross this ABI;
// accepted filesystem work becomes a genuine worker request afterward.
const RequestToHost = abi.Update_for_hostOkRequests;
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
// Value 4 was the obsolete upload-capacity refusal. Valid commands are never
// refused for host capacity now; keeping the remaining codes stable avoids needless
// transport churn for the structurally checkable errors.
const TRY_TAG_OK: u8 = 1;
const MAX_FILE_READ_BYTES: usize = 16 * 1024 * 1024;
const HEADLESS_CLIPBOARD_CAPACITY: usize = 4096;

extern fn app_config_for_host() callconv(.c) AppConfig;
extern fn init_for_host() callconv(.c) RocResult;
extern fn update_for_host(arg0: RocBox, arg1: InputFromHost) callconv(.c) UpdateResult;
extern fn render_for_host(arg0: RocBox) callconv(.c) RocResult;
extern fn drop_model_for_host(arg0: RocBox) callconv(.c) void;

/// `kind` codes for a response. Mirrored in the private App transport adapter.
const RESPONSE_SMALL_FILE_READ: u8 = 0;
const RESPONSE_DELAY: u8 = 1;
const RESPONSE_SCREENSHOT_FINISHED: u8 = 2;
const RESPONSE_CLIPBOARD_READ: u8 = 3;
const RESPONSE_FILE_READ: u8 = 4;
const RESPONSE_DIR_LISTED: u8 = 5;

/// `kind` codes for a request returned by `update`. Mirrored in the private App transport adapter.
const REQUEST_READ_SMALL_FILE: u8 = 0;
const REQUEST_DELAY: u8 = 1;
const REQUEST_SCREENSHOT: u8 = 2;
const REQUEST_READ_CLIPBOARD: u8 = 3;
const REQUEST_READ_FILE: u8 = 4;
const REQUEST_LIST_DIR: u8 = 5;

/// Read-error codes. Mirrored in the private App transport adapter.
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

/// Entry kinds in an encoded listing. Mirrored in the private App transport adapter.
const DIR_ENTRY_FILE: u8 = 1;
const DIR_ENTRY_DIR: u8 = 2;
const DIR_ENTRY_OTHER: u8 = 3;

/// The only way a delay fails: the host was already holding as many unanswered
/// requests as it will, so it never started this one. Mirrored in the private App transport adapter.
const DELAY_ERR_BUSY: u8 = 1;

/// The most the host will copy into a Roc string in one operation.
///
/// Converting worker-owned bytes into a `Str` allocates and copies on the frame
/// thread. `ReadSmallFile` reports `TooLarge` above this limit; `ReadFile`
/// transfers its native allocation as an owning Roc byte list without copying.
const MAX_INLINE_READ_BYTES: usize = 64 * 1024;

/// Total main-thread Roc-string-copy work admitted while submitting requests.
///
/// Clipboard reads share this budget. Requests beyond it receive `Busy`
/// immediately; they are never kept in a private host queue to surprise a
/// later frame. This does not cover windowed worker responses, which are
/// independently bounded by their at-most-32 resource reservations.
const MAX_SYNC_ROC_STRING_BYTES_PER_INPUT: usize = 1024 * 1024;

/// Main-thread request starts admitted while submitting one input's requests.
///
/// Clipboard reads can do meaningful metadata work even when they copy zero
/// bytes. Bound that work independently from the byte budget above. This is a
/// private admission budget, not a public request-list cap; every request beyond
/// it receives its typed `Busy` result now.
const MAX_SYNC_MAIN_THREAD_OPERATIONS_PER_INPUT: usize = 32;

/// Headless reads run on the frame thread for deterministic test output.
///
/// Unlike the windowed worker, they need explicit resource admission: no more
/// than 32 filesystem operations and 16 MiB of successfully-read bytes start
/// in an input. A read that would exceed the remaining byte credit receives
/// `Busy`; it is not held for a later frame.
const MAX_HEADLESS_READS_PER_INPUT: usize = 32;
const MAX_HEADLESS_READ_BYTES_PER_INPUT: usize = MAX_FILE_READ_BYTES;

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
/// How many bytes a read may take before it is refused as too large.
///
/// A byte-list read has no per-file ceiling below the host's own, because nothing
/// proportional to the file happens on the frame thread. A small read is
/// delivered as a `Str`, so it stops one byte past the largest string the frame
/// thread will build -- `readFileAlloc` refuses at the limit, and one past is
/// what makes a file of exactly that size succeed.
fn smallReadLimit(deliver_bytes: bool) usize {
    return if (deliver_bytes) MAX_FILE_READ_BYTES + 1 else MAX_INLINE_READ_BYTES + 1;
}

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

/// Blocking effects executed off the main thread.
///
/// The worker accepts and returns plain Zig values. It must not call Roc,
/// allocate or free Roc memory, read `active_roc_host`, or access resource
/// heaps. The main thread converts results to Roc values while draining the
/// result queue. The shared host allocator must be thread-safe.
///
/// Both rings are single-producer/single-consumer -- main writes requests and
/// reads results, the worker does the reverse -- so acquire/release on the
/// indices is all the *data* transfer needs, and neither ring is ever locked.
///
/// The mutex and condition variable only coordinate sleeping and waking; ring
/// data transfer remains lock-free. See `wake` and `awaitRequest`.
const EffectWorker = struct {
    /// Power of two so the index wrap is a mask.
    const capacity: usize = 64;
    const mask: usize = capacity - 1;

    /// What the worker was asked to do.
    ///
    /// The two share a ring because they share the property that matters: a
    /// bounded amount of plain-Zig state goes in, slow work happens on this
    /// thread, and a plain-Zig answer comes back.
    const Kind = enum(u8) { read_file, list_dir, write_png };

    const Request = struct {
        kind: Kind,
        /// Private host transport ticket. This is plain Zig data; callbacks
        /// remain exclusively in `pending_mappers` on the frame thread.
        ticket: u64,
        path: [capture.path_capacity]u8,
        path_len: usize,
        /// Whether the answer is an owning Roc byte list rather than a string.
        ///
        /// The worker reads a file the same way either way -- it allocates and
        /// fills native memory and knows nothing about Roc. This only says what
        /// the main thread will do with the buffer when it drains the result:
        /// install it into a typed file-byte slot, or copy it into a `RocStr`.
        deliver_bytes: bool = false,
        /// Which response the answer belongs in. A read and a listing share
        /// the byte-delivery path exactly, and differ only in the response
        /// the app is waiting on, so that is carried rather than re-derived.
        response: u8 = RESPONSE_FILE_READ,
        /// `write_png`: the framebuffer readback, owned by `allocator` and
        /// freed on this thread once it has been encoded.
        pixels: []u8 = &.{},
        width: u32 = 0,
        height: u32 = 0,
    };

    /// `bytes` is owned by `allocator` until the main thread takes it: either by
    /// copying it into a `RocStr` and freeing it, or -- for `ReadFile` -- by
    /// moving the allocation itself into a typed slot without touching it.
    const Result = struct {
        kind: Kind,
        ticket: u64,
        bytes: ?[]u8 = null,
        err: u8 = 0,
        deliver_bytes: bool = false,
        response: u8 = RESPONSE_FILE_READ,
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
            // already asleep is signalled. Queued *writes* are then flushed --
            // see `awaitRequest` -- so shutdown costs the screenshots the app
            // has already been promised, and nothing else.
            //
            // The flush cannot deadlock on a full result ring: `postResult`
            // stops waiting once `should_stop` is set, and by then the file it
            // was reporting on is already written.
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
    fn submitReadFile(self: *EffectWorker, ticket: u64, path: []const u8, deliver_bytes: bool) Submission {
        if (!self.accepting) return .unavailable;
        if (path.len > capture.path_capacity) return .unavailable;

        const write = self.request_write.load(.monotonic);
        if (write -% self.request_read.load(.acquire) >= capacity) return .busy;

        const slot = &self.requests[write & mask];
        slot.* = .{ .kind = .read_file, .ticket = ticket, .path = undefined, .path_len = path.len, .deliver_bytes = deliver_bytes };
        // The worker cannot borrow the Roc string the path arrived in.
        @memcpy(slot.path[0..path.len], path);
        self.request_write.store(write +% 1, .release);
        // Only after the request is visible; a refusal wakes nobody, which is
        // what keeps `Busy` and `Unavailable` pure refusals.
        self.wake();
        return .accepted;
    }

    /// Queue a directory listing. Frame thread only.
    ///
    /// The same ring, the same refusals and the same ownership as a read: the
    /// answer is a buffer this thread allocates and the frame thread moves into
    /// Roc without copying. Only what fills the buffer differs.
    fn submitListDir(self: *EffectWorker, ticket: u64, path: []const u8) Submission {
        if (!self.accepting) return .unavailable;
        if (path.len > capture.path_capacity) return .unavailable;

        const write = self.request_write.load(.monotonic);
        if (write -% self.request_read.load(.acquire) >= capacity) return .busy;

        const slot = &self.requests[write & mask];
        slot.* = .{
            .kind = .list_dir,
            .ticket = ticket,
            .path = undefined,
            .path_len = path.len,
            .deliver_bytes = true,
            .response = RESPONSE_DIR_LISTED,
        };
        @memcpy(slot.path[0..path.len], path);
        self.request_write.store(write +% 1, .release);
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
        ticket: u64,
        path: []const u8,
        pixels: []u8,
        width: u32,
        height: u32,
    ) Submission {
        if (!self.accepting) return .unavailable;
        if (path.len > capture.path_capacity) return .unavailable;

        const write = self.request_write.load(.monotonic);
        if (write -% self.request_read.load(.acquire) >= capacity) return .busy;

        const slot = &self.requests[write & mask];
        slot.* = .{
            .kind = .write_png,
            .ticket = ticket,
            .path = undefined,
            .path_len = path.len,
            .pixels = pixels,
            .width = width,
            .height = height,
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
        // only here means the cost is one signal per completed request rather than
        // one per frame.
        if (self.accepting) self.drained.signal(mainThreadIo());
        return result;
    }

    /// Publish a finished result, waiting for room if the ring is full.
    ///
    /// Worker thread only. Accepted requests guarantee one response, so a full
    /// result ring blocks this worker instead of discarding a result. The frame
    /// thread never waits on this condition.
    ///
    /// The ring is larger than the `MAX_REQUESTS_IN_FLIGHT` reservation budget, so
    /// the wait is unreachable under the current capacity invariant. Keeping
    /// the wait preserves correctness if either capacity changes.
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
            if (self.should_stop.load(.acquire)) {
                // Shutting down, but an accepted write is still finished. The
                // app was told the host had taken that screenshot -- it got a
                // response saying so -- and a file that never appears makes
                // that a lie. Reads are abandoned instead: their answer was
                // going to a model that is about to stop existing, and a
                // request holds no memory of its own, so nothing leaks.
                while (self.takeRequest()) |request| {
                    if (request.kind == .write_png) return request;
                }
                return null;
            }
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
                .list_dir => self.runListDir(io, request),
                .write_png => self.runWritePng(io, request),
            }
        }
    }

    /// Read a file whole. Worker thread only.
    fn runRead(self: *EffectWorker, io: std.Io, request: Request) void {
        const path = request.path[0..request.path_len];
        // The native allocation later owned by Roc's byte list is made and
        // filled here. The main thread moves that slice into its typed slot and
        // builds only the three-word List value around it.
        //
        // A small read stops one byte past what it could deliver rather than
        // reading up to the byte-list ceiling and then rejecting it: refusing a
        // 16 MiB file should not mean having read 16 MiB first.
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(smallReadLimit(request.deliver_bytes))) catch |err| {
            self.postResult(io, .{
                .kind = .read_file,
                .ticket = request.ticket,
                .err = readErrorCode(err),
                .deliver_bytes = request.deliver_bytes,
                .response = request.response,
            });
            return;
        };
        self.postResult(io, .{
            .kind = .read_file,
            .ticket = request.ticket,
            .bytes = bytes,
            .deliver_bytes = request.deliver_bytes,
            .response = request.response,
        });
    }

    /// List one directory into an encoded byte buffer. Worker thread only.
    ///
    /// Only one directory, never its children: recursion is the app's to drive,
    /// because only the app knows which subtrees are worth descending into and
    /// how fast it wants them. A host-side recursive walk would be one
    /// unbounded operation that no queue could pace.
    fn runListDir(self: *EffectWorker, io: std.Io, request: Request) void {
        const path = request.path[0..request.path_len];
        var encoded: ?[]u8 = null;
        const err = encodeListing(io, self.allocator, path, &encoded);
        self.postResult(io, .{
            .kind = .list_dir,
            .ticket = request.ticket,
            .bytes = if (err == 0) encoded else null,
            .err = err,
            .deliver_bytes = true,
            .response = RESPONSE_DIR_LISTED,
        });
    }

    /// Encode a framebuffer readback as a PNG and write it. Worker thread only.
    ///
    /// Performs PNG compression and file I/O without accessing raylib. The
    /// frame thread is responsible only for framebuffer readback.
    fn runWritePng(self: *EffectWorker, io: std.Io, request: Request) void {
        defer self.allocator.free(request.pixels);
        const path = request.path[0..request.path_len];

        const encoded = png.encodeRgba(self.allocator, request.pixels, request.width, request.height) catch |err| {
            self.postResult(io, .{
                .kind = .write_png,
                .ticket = request.ticket,
                .err = switch (err) {
                    error.OutOfMemory => capture.err_out_of_memory,
                    else => capture.err_write_failed,
                },
            });
            return;
        };
        defer self.allocator.free(encoded);

        self.postResult(io, .{
            .kind = .write_png,
            .ticket = request.ticket,
            .err = writeWholeFile(io, path, encoded),
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

/// The simulation clock this frame reported to Roc.
var last_frame_nanos: u64 = 0;

/// Real monotonic time at the start of this frame.
///
/// Separate from `last_frame_nanos` because a fixed-step recording makes the
/// simulation clock advance by an exact delta rather than by however long the
/// frame took. Delays are armed and expired against *this* one: `Delay(1000)`
/// means a second, and an app recording at a fixed step has not asked for its
/// timeouts to be re-scaled.
var last_wall_nanos: u64 = 0;

/// How many requests may be accepted but not yet answered.
///
/// Bounds *acceptance* rather than delivery. A request is accepted only if a
/// reservation is free, and it holds that reservation until its response is
/// staged. So the amount of deferred work the host is carrying is bounded
/// without any response ever being dropped -- which is what makes "every
/// accepted request yields exactly one response" a property of the code rather
/// than a hope.
const MAX_REQUESTS_IN_FLIGHT: usize = 32;

/// Windowed worker delivery happens before dispatch and has its own bound.
///
/// At most one small-file result fits each reservation, so a frame can copy at
/// most 32 × 64 KiB = 2 MiB from worker buffers into Roc strings. This is
/// intentionally separate from the 1 MiB synchronous request-admission budget.
const MAX_WORKER_SMALL_READ_DELIVERY_BYTES_PER_INPUT: usize = MAX_REQUESTS_IN_FLIGHT * MAX_INLINE_READ_BYTES;

/// Commands whose result is due once a deadline passes.
///
/// Sized to the pending-callback budget: an armed timer owns one callback, so
/// this table cannot fill after that callback was admitted.
const PendingTimer = struct { ticket: u64, due_nanos: u64 };
var pending_timers: [MAX_REQUESTS_IN_FLIGHT]PendingTimer = undefined;
var pending_timer_count: usize = 0;

/// A Roc continuation retained privately by the frame thread until one raw
/// terminal result is ready. Tickets are host transport details only: no app
/// value is ever used to correlate a result.
///
/// This is deliberately an array, not a map or growable allocation. It shares
/// the 32-operation admission limit, so lookup is at most 32 comparisons and
/// accepting an asynchronous request does not allocate. The worker sees only the
/// ticket; it can neither retain nor call a Roc closure.
const PendingMappers = struct {
    const Entry = struct {
        ticket: u64,
        deliver: abi.RocErasedCallable,
    };

    entries: [MAX_REQUESTS_IN_FLIGHT]Entry = undefined,
    count: usize = 0,
    /// Zero is kept invalid so an uninitialized native result cannot happen to
    /// match a callback. Exhaustion is not recoverable without reusing a
    /// ticket, which would violate the exactly-once transport invariant.
    next_ticket: u64 = 1,

    fn issueTicket(self: *PendingMappers) u64 {
        const ticket = self.next_ticket;
        if (ticket == 0) @panic("roc-ray: exhausted private request tickets");
        // Do not let the final valid ticket wrap the counter during the
        // increment. The following request sees the invalid zero sentinel and
        // terminates rather than reusing a ticket that could still be live.
        self.next_ticket = if (ticket == std.math.maxInt(u64)) 0 else ticket + 1;
        return ticket;
    }

    /// Take ownership of a callback for an accepted deferred request.
    fn insert(self: *PendingMappers, ticket: u64, deliver: abi.RocErasedCallable) bool {
        if (self.count == self.entries.len) return false;
        std.debug.assert(ticket != 0);
        std.debug.assert(deliver != null);
        self.entries[self.count] = .{ .ticket = ticket, .deliver = deliver };
        self.count += 1;
        return true;
    }

    /// Move the callback out of the table. A duplicate or forged ticket has no
    /// callback to deliver, and is rejected by the caller without disturbing a
    /// legitimate pending entry.
    fn take(self: *PendingMappers, ticket: u64) ?abi.RocErasedCallable {
        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            if (self.entries[index].ticket != ticket) continue;
            const deliver = self.entries[index].deliver;
            self.count -= 1;
            self.entries[index] = self.entries[self.count];
            return deliver;
        }
        return null;
    }

    /// Drop callbacks whose host work will never be delivered, such as process
    /// shutdown after a worker has stopped. Each entry is removed before its
    /// final decref, which makes this safe to call only once and makes a later
    /// accidental response an unknown ticket rather than a double drop.
    fn release(self: *PendingMappers, roc_host: *RocHost) void {
        while (self.count != 0) {
            self.count -= 1;
            abi.decrefErasedCallable(self.entries[self.count].deliver, roc_host);
        }
    }
};

var pending_mappers = PendingMappers{};

/// Start a fresh app lifetime. Every previous lifetime must have dropped its
/// callbacks and abandoned delivery reservations before this point; resetting
/// either would leak a Roc capture or let stale work collide with a new app.
fn beginPendingMappers() void {
    std.debug.assert(pending_mappers.count == 0);
    std.debug.assert(pending_timer_count == 0);
    std.debug.assert(file_bytes_delivery_reservations.count == 0);
    pending_mappers.next_ticket = 1;
    exit_requested = null;
}

/// End one app lifetime after no worker or frame callback can publish another
/// response. Discard timer producer records before dropping their callback
/// targets, so no retained ticket can ever name a callback as teardown runs or
/// before a future lifetime resets ticket numbering.
fn endPendingMappers(roc_host: *RocHost) void {
    pending_timer_count = 0;
    pending_mappers.release(roc_host);
}

/// Responses gathered for the input being assembled.
///
/// This is deliberately not tied to a request-count limit. An input may submit any
/// number of requests; the host admits only work for which it has a real resource
/// reservation and gives every other request a terminal `Busy` response.
///
/// The backing allocation grows geometrically and is retained until shutdown.
/// Thus an idle frame has no allocation, ordinary later frames reuse the same
/// storage, and a burst only pays while it establishes a larger high-water
/// mark. OOM cannot be converted into a missing response, so it terminates
/// rather than silently stranding an accepted request.
const ResponseStaging = struct {
    items: std.ArrayListUnmanaged(ResponseEnvelope) = .empty,

    fn count(self: *const ResponseStaging) usize {
        return self.items.items.len;
    }

    fn ensureOne(self: *ResponseStaging, roc_host: *RocHost) void {
        self.items.ensureUnusedCapacity(allocatorFromHost(roc_host), 1) catch
            @panic("roc-ray: out of memory while staging a request response");
    }

    /// Append an owned response after `ensureOne` has reserved its slot.
    fn appendAssumeCapacity(self: *ResponseStaging, item: ResponseEnvelope) void {
        self.items.appendAssumeCapacity(item);
    }

    /// Move a raw result and its mapper into the input being assembled.
    /// `deliver` is always an owned reference: it was either moved from a
    /// unique request list, incref'd from a shared one, or taken from the pending
    /// table. No callback invocation happens in Zig.
    fn completeDirect(
        self: *ResponseStaging,
        roc_host: *RocHost,
        raw: RawResponse,
        deliver: abi.RocErasedCallable,
    ) void {
        std.debug.assert(deliver != null);
        self.ensureOne(roc_host);
        self.appendAssumeCapacity(.{ .raw = raw, .deliver = deliver });
    }

    /// As `completeDirect`, when the caller already reserved the staging slot
    /// before constructing an owned Roc payload.
    fn completeDirectAssumeCapacity(
        self: *ResponseStaging,
        raw: RawResponse,
        deliver: abi.RocErasedCallable,
    ) void {
        std.debug.assert(deliver != null);
        self.appendAssumeCapacity(.{ .raw = raw, .deliver = deliver });
    }

    /// Finish one accepted request. Reserve space before removing its callback so
    /// allocation failure cannot strand an accepted request with its sole callback
    /// still hidden in the host table.
    fn completeTicket(self: *ResponseStaging, roc_host: *RocHost, raw: RawResponse) void {
        self.ensureOne(roc_host);
        self.completeTicketAssumeCapacity(roc_host, raw);
    }

    /// As `completeTicket`, with one slot already reserved by a caller that
    /// had to allocate a raw payload first. Keeping that allocation before the
    /// callback move avoids both a second capacity check and a result whose
    /// payload has nowhere to go on OOM.
    fn completeTicketAssumeCapacity(self: *ResponseStaging, roc_host: *RocHost, raw: RawResponse) void {
        const deliver = pending_mappers.take(raw.ticket) orelse {
            // This is an internal protocol violation (duplicate worker result,
            // stale result after shutdown, or a malformed ticket), never an
            // application-visible retry. Release any raw payload exactly once.
            if (builtin.is_test) {
                // Focused raw-result tests exercise the conversion and payload
                // ownership without setting up a callback table. Production
                // never takes this branch: every response must name an
                // accepted private ticket.
                self.appendAssumeCapacity(.{ .raw = raw, .deliver = null });
                return;
            }
            raw.decref(roc_host);
            std.debug.panic("roc-ray: response for unknown or duplicate ticket {d}", .{raw.ticket});
        };
        self.appendAssumeCapacity(.{ .raw = raw, .deliver = deliver });
    }

    /// A response that carries nothing Roc has to free.
    ///
    /// Every field the operation does not use is spelled out once here rather
    /// than at each call site, so adding one to the transport record does not
    /// mean editing five constructors that never fill it in.
    fn plain(kind: u8, ticket: u64, err: u8) RawResponse {
        return .{
            .kind = kind,
            .ticket = ticket,
            .err = err,
            .contents = abi.RocStr.empty(),
            .bytes = abi.RocListWith(u8, false).empty(),
        };
    }

    /// Report a read the app asked to have delivered as a string.
    ///
    /// The validation is here rather than at the call sites because this is the
    /// one place a file's bytes become a `Str`, and there are two ways in --
    /// the worker's result and the inline headless read. A `Str` is UTF-8 and a
    /// file is arbitrary bytes; `RocStr.fromSlice` only copies, so an invalid
    /// one would be built without complaint and every later string operation on
    /// it would be undefined. The same invariant applies to every byte source.
    fn fileRead(self: *ResponseStaging, roc_host: *RocHost, ticket: u64, err: u8, contents: []const u8) void {
        if (err == 0 and !std.unicode.utf8ValidateSlice(contents)) {
            self.completeTicket(roc_host, plain(RESPONSE_SMALL_FILE_READ, ticket, READ_ERR_NOT_UTF8));
            return;
        }
        // Reserve staging before allocating the payload. OOM therefore cannot
        // leave a newly built Roc value with nowhere safe to put it.
        self.ensureOne(roc_host);
        var item = plain(RESPONSE_SMALL_FILE_READ, ticket, err);
        if (contents.len != 0) item.contents = abi.RocStr.fromSlice(contents, roc_host);
        self.completeTicketAssumeCapacity(roc_host, item);
    }

    /// Report a byte-list operation that produced no bytes, in the response
    /// it asked for: a read and a listing share this path and differ only in
    /// which response the app is waiting on.
    fn byteListReadFailed(self: *ResponseStaging, roc_host: *RocHost, ticket: u64, response: u8, err: u8) void {
        std.debug.assert(err != 0);
        self.completeTicket(roc_host, plain(response, ticket, err));
    }

    /// Report a read by moving its existing typed file-byte heap reference into an owning
    /// seamless `List(U8)`. Its allocation pointer is the typed heap payload,
    /// one word after the slot refcount, exactly where Roc list ARC expects it.
    /// The seamless tag prevents reusing or resizing that backing allocation,
    /// but a unique List operation may still mutate visible elements in place.
    /// Safety comes from the complete transfer: the host never reads or shares
    /// these bytes after this move, while sublists retain the one allocation.
    fn byteListRead(self: *ResponseStaging, roc_host: *RocHost, ticket: u64, response: u8, bytes: abi.RocListWith(u8, false)) void {
        self.ensureOne(roc_host);
        var item = plain(response, ticket, 0);
        item.bytes = bytes;
        self.completeTicketAssumeCapacity(roc_host, item);
    }

    fn delayElapsed(self: *ResponseStaging, roc_host: *RocHost, ticket: u64, err: u8) void {
        self.completeTicket(roc_host, plain(RESPONSE_DELAY, ticket, err));
    }

    fn screenshotFinished(self: *ResponseStaging, roc_host: *RocHost, ticket: u64, err: u8) void {
        self.completeTicket(roc_host, plain(RESPONSE_SCREENSHOT_FINISHED, ticket, err));
    }

    fn clipboardRead(self: *ResponseStaging, roc_host: *RocHost, ticket: u64, err: u8, text: []const u8, deliver: ?abi.RocErasedCallable) void {
        self.ensureOne(roc_host);
        var item = plain(RESPONSE_CLIPBOARD_READ, ticket, err);
        if (text.len != 0) item.contents = abi.RocStr.fromSlice(text, roc_host);
        if (deliver) |owned| {
            self.completeDirectAssumeCapacity(item, owned);
        } else {
            self.completeTicketAssumeCapacity(roc_host, item);
        }
    }

    /// Hand the staged responses to Roc as one list, transferring ownership.
    fn toRocList(self: *ResponseStaging, roc_host: *RocHost) abi.RocList(ResponseEnvelope) {
        if (self.count() == 0) return abi.RocList(ResponseEnvelope).empty();
        return abi.RocList(ResponseEnvelope).fromSlice(self.items.items, roc_host);
    }

    /// Hand this input's responses to Roc and empty the staging area.
    ///
    /// The returned list owns its payloads. Clear staging without releasing them
    /// to avoid a double free. Results staged afterward are owned by staging and
    /// delivered on the next input.
    fn take(self: *ResponseStaging, roc_host: *RocHost) abi.RocList(ResponseEnvelope) {
        const list = self.toRocList(roc_host);
        self.items.clearRetainingCapacity();
        return list;
    }

    /// Release staged responses that never reached Roc.
    ///
    /// A handle staged but never delivered still owns its slot, so dropping it
    /// here is what frees the file behind a read that finished during the frame
    /// the app exited on.
    fn release(self: *ResponseStaging, roc_host: *RocHost) void {
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
    /// Inside `update_for_host`, applying the commands `update` returned.
    apply,
    /// Inside `render_for_host`.
    render,

    /// How the phase is named in a rejection, in the app's own vocabulary.
    fn label(self: Phase) []const u8 {
        return switch (self) {
            .idle => "outside any app callback",
            .startup => "init!",
            .apply => "a command returned by update",
            .render => "render!",
        };
    }
};

/// Callback phases in which an operation is valid.
const PhaseSet = std.EnumSet(Phase);

/// Loading, allocating or generating a resource. Startup only: all of these
/// block, allocate on the GPU, or both, and a frame is not the place for it.
const during_startup = PhaseSet.initOne(.startup);

/// Drawing, and anything that changes how the draws after it are interpreted.
/// Only defined inside the frame scope the host opens around `render!`.
const during_render = PhaseSet.initOne(.render);

/// Changing host state between frames: cursor, window, audio, releases.
/// Reachable while starting up and while applying a command, and nowhere else.
const during_apply = PhaseSet.initMany(&.{ .startup, .apply });

/// Constant-time operations with nothing to allocate and no I/O to do: reading
/// a font metric, asking whether a sound is still playing, taking a random
/// number. Valid in every callback, but not outside callbacks. Operations that
/// copy, allocate, write files, or access a driver do not belong in this set.
const constant_time_anywhere = PhaseSet.initMany(&.{ .startup, .apply, .render });

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
            " Load it in init! and keep the handle in your model; loading during a frame blocks it."
        else if (allowed.eql(during_render))
            " Drawing is only defined inside the frame scope the host opens around render!."
        else if (allowed.eql(during_apply))
            " Return it from update as a command; it changes host state rather than drawing, so it runs during apply before optional presentation."
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
/// Private ticket of the screenshot request that queued the pending request.
///
/// Set for every pending screenshot. The optional spans request acceptance and the
/// framebuffer readback performed later in the frame.
var capture_screenshot_ticket: ?u64 = null;
/// A serviced screenshot request whose response has not reached Roc yet.
var capture_screenshot_done: ?ScreenshotOutcome = null;
const ScreenshotOutcome = struct { ticket: u64, err: u8 };
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

/// Bytes a finished `ReadFile` handed over, and the allocator that owns them.
///
/// The allocator travels with the buffer because the two paths that produce one
/// do not share one: the worker allocates from its own handle on the host
/// allocator, while a headless run reads on the frame thread through the Roc
/// environment's. Whoever allocated it is who frees it.
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

/// Slots promised to reads which have been admitted but have not yet produced
/// their terminal response. A `ReadFile` has to reserve one before it starts
/// I/O: otherwise a full heap could let up to the worker limit of large buffers
/// be read only to discard each one when delivery finds no handle slot.
///
/// This is deliberately just a count. The worker holds only plain request
/// data, the frame thread is its sole reader/writer, and the pending-callback
/// table already bounds the count to 32. No read admission allocates.
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

    /// Shutdown has stopped the worker and freed its unreported result
    /// buffers. Their callbacks will never be invoked, so forget the matching
    /// delivery promises before another app lifetime can begin.
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
    capture_screenshot_ticket = null;
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

    // The window is asked, not remembered, so a `Window.suggest_size` applied
    // during the apply phase reaches the `render!` of the same cycle -- which
    // is what that command requests, and one cycle sooner than a size sampled
    // in `update` could report it.
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
        const scope = PhaseScope.enter(.apply);
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
        const scope = PhaseScope.enter(.apply);
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
    const phase = PhaseScope.enter(.apply);
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
    try std.testing.expectEqual(Phase.apply, violation.actual);
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
    const scope = PhaseScope.enter(.apply);
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
    const scope = PhaseScope.enter(.apply);
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
    enforcePhase("Assets.Store.open!", during_startup);
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
    enforcePhase("Assets.load_texture!", during_startup);
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
    enforcePhase("Assets.texture_from_bytes!", during_startup);
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
    enforcePhase("Assets.generate_color_texture!", during_startup);
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
    enforcePhase("Assets.generate_checked_texture!", during_startup);
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
    enforcePhase("Assets.update_texture!", during_apply);
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
/// one pixel of an atlas means re-uploading the atlas. Commands carry their
/// complete payload for this cycle, so a structurally valid upload is invoked
/// rather than silently refused for transient host capacity.
fn hostedAssetsUpdateTextureRegionRaw(host: *RocHost, args: abi.AssetsHostUpdate_texture_regionArgs) callconv(.c) u8 {
    enforcePhase("Assets.update_texture_region!", during_apply);
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
    enforcePhase("Assets.set_texture_filter!", during_apply);
    defer texture_owner.decref(activeHost());
    if (builtin.is_test) return;
    const texture = nativeTextureForToken(texture_owner.handle.*) orelse return;
    raylib.setTextureFilter(texture, code);
}

fn hostedAssetsSetTextureWrapRaw(texture_owner: abi.Texture, code: u8) callconv(.c) void {
    enforcePhase("Assets.set_texture_wrap!", during_apply);
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
    enforcePhase("Draw.RenderTexture.load!", during_startup);
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

fn hostedDrawLoadStoreShaderRaw(host: *RocHost, args: abi.DrawHostLoad_store_shaderArgs) callconv(.c) abi.DrawHostLoad_store_shaderRetRecord {
    enforcePhase("Draw.Shader.from_store!", during_startup);
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
    enforcePhase("Draw.Shader.uniform_*!", during_startup);
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
    enforcePhase("Draw.font_from_bytes!", during_startup);
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
    enforcePhase("Draw.load_store_font!", during_startup);
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
    enforcePhase("Draw font metric snapshot", during_startup);
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
    enforcePhase("App.Startup.args!", during_startup);

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
    enforcePhase("App.exit", during_apply);
    exit_requested = @as(i64, code);
}

/// Suggest a new logical window size.
///
/// Native window managers may adjust or ignore the hint. A later input's
/// window snapshot, and the active frame size during presentation, report the
/// geometry the backend actually established. The headless semantic backend
/// honors the hint deterministically.
fn hostedSuggestWindowSize(args: abi.HostHostSuggest_window_sizeArgs) callconv(.c) u8 {
    enforcePhase("Window.suggest_size", during_apply);
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
    enforcePhase("Window.set_target_fps", during_apply);
    if (headlessMode()) return;
    raylib.setTargetFps(fps);
}

fn hostedSuggestWindowMinSize(args: abi.HostHostSuggest_window_min_sizeArgs) callconv(.c) void {
    enforcePhase("Window.suggest_min_size", during_apply);
    if (headlessMode()) return;
    raylib.suggestWindowMinSize(nonNegativeCInt(args.width), nonNegativeCInt(args.height));
}

fn hostedSetExitKey(key_code: i32) callconv(.c) void {
    enforcePhase("Keys.set_exit_key", during_apply);
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

/// Apply a `Capture.start` command.
///
/// Refusals are latched in the session for the next `input.capture`. The return
/// code preserves the hosted ABI and supports direct tests.
fn hostedCaptureStartRecording(roc_host: *RocHost, args: abi.CaptureHostStart_recordingArgs) callconv(.c) u8 {
    enforcePhase("Capture.start", during_apply);
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
    enforcePhase("Mouse.set_source", during_apply);
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
    enforcePhase("Capture.stop", during_apply);
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
/// A pure `update` cannot ask for this, and there is no longer anything to ask:
/// starting and stopping are commands, so this is the only channel the outcome
/// has. It is five scalars, so it rides along on the input record rather than
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

fn hostedSetClipboardText(roc_host: *RocHost, text_arg: abi.RocStr) callconv(.c) void {
    enforcePhase("Window.set_clipboard_text", during_apply);
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
    enforcePhase("Mouse.set_cursor_mode", during_apply);
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
    enforcePhase("Mouse.set_cursor", during_apply);
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

// The audio entry points below guard their `.native` arm with `builtin.is_test`
// rather than returning early, the way the scoped drawing operations do. The
// guard exists only to keep raylib's audio symbols out of the test link -- a
// unit test never reaches a `.native` resource, since everything it stores is
// `.headless` -- and keeping it inside the arm leaves the handle lookup itself
// running, which is the part worth testing: an unresolvable token has to reach
// the `orelse return` and still release the reference it was handed.
fn hostedAudioPlay(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.play!", during_apply);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.playSound(sound),
    }
}

fn hostedAudioStop(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.stop!", during_apply);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.stopSound(sound),
    }
}

fn hostedAudioPause(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.pause!", during_apply);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.pauseSound(sound),
    }
}

fn hostedAudioResume(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Sound.resume!", during_apply);
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
    enforcePhase("Audio.Sound.set_volume!", during_apply);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.setSoundVolume(sound, volume),
    }
}

fn hostedAudioSetPitch(handle: *u64, pitch: f32) callconv(.c) void {
    enforcePhase("Audio.Sound.set_pitch!", during_apply);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.setSoundPitch(sound, pitch),
    }
}

fn hostedAudioSetPan(handle: *u64, pan: f32) callconv(.c) void {
    enforcePhase("Audio.Sound.set_pan!", during_apply);
    defer releaseResourceBox(activeHost(), handle);
    const resource = sound_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |sound| if (!builtin.is_test) raylib.setSoundPan(sound, pan),
    }
}

fn hostedAudioPlayMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.play!", during_apply);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.playMusic(music),
    }
}

fn hostedAudioStopMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.stop!", during_apply);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.stopMusic(music),
    }
}

fn hostedAudioPauseMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.pause!", during_apply);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.pauseMusic(music),
    }
}

fn hostedAudioResumeMusic(handle: *u64) callconv(.c) void {
    enforcePhase("Audio.Music.resume!", during_apply);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.resumeMusic(music),
    }
}

fn hostedAudioSetMusicVolume(handle: *u64, volume: f32) callconv(.c) void {
    enforcePhase("Audio.Music.set_volume!", during_apply);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.setMusicVolume(music, volume),
    }
}

fn hostedAudioSetMusicPitch(handle: *u64, pitch: f32) callconv(.c) void {
    enforcePhase("Audio.Music.set_pitch!", during_apply);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.setMusicPitch(music, pitch),
    }
}

fn hostedAudioSetMusicPan(handle: *u64, pan: f32) callconv(.c) void {
    enforcePhase("Audio.Music.set_pan!", during_apply);
    defer releaseResourceBox(activeHost(), handle);
    const resource = music_heap.get(handle.*) orelse return;
    switch (resource.*) {
        .headless => {},
        .native => |music| if (!builtin.is_test) raylib.setMusicPan(music, pan),
    }
}

fn hostedAudioSetMusicLooping(handle: *u64, looping: bool) callconv(.c) void {
    enforcePhase("Audio.Music.set_looping!", during_apply);
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
    enforcePhase("Audio.Music.seek!", during_apply);
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
    enforcePhase("Audio.set_master_volume!", during_apply);
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
    // Worker shutdown clears delivery promises before resource teardown. A
    // non-zero value here would make the next app lifetime under-admit reads.
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
        @export(&exportedGetClipboardText, .{ .name = "roc_host_get_clipboard_text" });
        @export(&hostedRandomI32, .{ .name = "roc_host_random_i32" });
        @export(if (builtin.os.tag == .windows) &exportedReadEnvWindows else &exportedReadEnvPosix, .{ .name = "roc_host_read_env" });
        @export(&exportedReadFileRaw, .{ .name = "roc_host_read_file_raw" });
        @export(&exportedSetClipboardText, .{ .name = "roc_host_set_clipboard_text" });
        @export(&hostedSetExitKey, .{ .name = "roc_host_set_exit_key" });
        @export(&exportedCaptureStartRecording, .{ .name = "roc_capture_start_recording" });
        @export(&hostedCaptureSetVirtualMouse, .{ .name = "roc_capture_set_virtual_mouse" });
        @export(&hostedCaptureStopRecording, .{ .name = "roc_capture_stop_recording" });
        @export(&hostedSuggestWindowSize, .{ .name = "roc_host_suggest_window_size" });
        @export(&hostedSetTargetFps, .{ .name = "roc_host_set_target_fps" });
        @export(&hostedSuggestWindowMinSize, .{ .name = "roc_host_suggest_window_min_size" });
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
    // The commands `update` returns are applied by the platform before this
    // call returns, so they run inside this scope too -- which is why an
    // command's effect is checked against apply and not against idle.
    const phase = PhaseScope.enter(.apply);
    defer phase.leave();
    // Off unless ROC_RAY_ALLOC_STATS asked for metering; one branch per frame.
    const metered = allocMeterMark();
    defer allocMeterRecordUpdate(metered);
    return update_for_host(takeModel(boxed_model), input);
}

/// Submit the requests returned by one `update` call and release the list.
///
/// Reads run on the worker and respond in a later input. An unavailable or full
/// worker refuses them immediately instead of running slow work on this thread.
///
/// Headless mode performs reads synchronously for deterministic response
/// ordering, but still reports them through the normal response path.
///
/// Screenshot and clipboard requests require main-thread APIs. They are serviced
/// in this cycle and reported in the next input.
///
/// Every request yields one terminal response, including refused requests.
/// Responses staged here land in the next input because the current input is
/// immutable.
///
/// Reservations bound genuinely asynchronous work; requests without a reservation
/// are refused, never dropped. Synchronous work has operation-specific byte
/// limits rather than a hidden request-count queue.
const HeadlessReadBudget = struct {
    operations: usize = 0,
    bytes: usize = 0,

    fn begin(self: *HeadlessReadBudget) bool {
        if (self.operations == MAX_HEADLESS_READS_PER_INPUT) return false;
        if (self.bytes == MAX_HEADLESS_READ_BYTES_PER_INPUT) return false;
        self.operations += 1;
        return true;
    }

    fn remainingBytes(self: *const HeadlessReadBudget) usize {
        return MAX_HEADLESS_READ_BYTES_PER_INPUT - self.bytes;
    }
};

fn submitRequests(staging: *ResponseStaging, roc_host: *RocHost, requests: abi.RocList(RequestToHost)) void {
    defer {
        if (requests.hasOneRef()) {
            for (requests.allocationItems()) |item| item.decref(roc_host);
        }
        requests.decref(roc_host);
    }

    const unique = requests.isUnique();
    const mutable_tasks: []RequestToHost = if (unique) @constCast(requests.items()) else &.{};
    var roc_string_bytes: usize = 0;
    var synchronous_tasks: usize = 0;
    var headless_reads = HeadlessReadBudget{};
    for (requests.items(), 0..) |request, index| {
        // A list returned directly from Roc is normally unique. Move the
        // callable out in that case, nulling its list slot before the generated
        // list decref runs. A shared list must retain one reference for this
        // dispatch, because the originating list still owns its callback.
        const deliver = if (unique) blk: {
            const moved = mutable_tasks[index].deliver;
            mutable_tasks[index].deliver = null;
            break :blk moved;
        } else blk: {
            abi.increfErasedCallable(request.deliver, 1);
            break :blk request.deliver;
        };
        std.debug.assert(deliver != null);

        const ticket = pending_mappers.issueTicket();
        // Clipboard work finishes during this dispatch. Keep its callback out
        // of the fixed pending table: that table is a reservation for work
        // which can outlive this frame.
        if (request.kind == REQUEST_READ_CLIPBOARD) {
            if (synchronous_tasks == MAX_SYNC_MAIN_THREAD_OPERATIONS_PER_INPUT) {
                refuseRequest(staging, roc_host, request, ticket, deliver);
                continue;
            }
            synchronous_tasks += 1;
            startSynchronousRequest(staging, roc_host, request, ticket, deliver, &roc_string_bytes);
            continue;
        }
        if (!pending_mappers.insert(ticket, deliver)) {
            // Capacity is a bound on deferred callbacks, not a public request
            // list limit. The callback moves straight into a terminal Busy
            // envelope, so the app receives exactly one typed result.
            refuseRequest(staging, roc_host, request, ticket, deliver);
            continue;
        }
        startRequest(staging, roc_host, request, ticket, &headless_reads);
    }
}

/// Start one request whose callback has already been retained in the private
/// table. Only work that can outlive this dispatch reaches here; it passes an
/// opaque ticket onward and returns the callback with its terminal envelope.
fn startRequest(staging: *ResponseStaging, roc_host: *RocHost, request: RequestToHost, ticket: u64, headless_reads: *HeadlessReadBudget) void {
    switch (request.kind) {
        REQUEST_READ_SMALL_FILE => submitRead(staging, roc_host, ticket, request.path.asSlice(), false, headless_reads),
        REQUEST_READ_FILE => submitRead(staging, roc_host, ticket, request.path.asSlice(), true, headless_reads),
        REQUEST_LIST_DIR => submitListing(staging, roc_host, ticket, request.path.asSlice(), headless_reads),
        REQUEST_DELAY => armTimer(ticket, request.millis),
        REQUEST_SCREENSHOT => blk: {
            const err = beginScreenshotTask(ticket, request.path.asSlice()) orelse break :blk;
            staging.screenshotFinished(roc_host, ticket, err);
        },
        REQUEST_READ_CLIPBOARD => unreachable,
        // The host and the platform are built together, so this is not a newer
        // app talking to an older host -- it is transport disagreeing with
        // itself. Drop the retained callback before terminating, rather than
        // leaking a closure on this internal error path.
        else => {
            abi.decrefErasedCallable(pending_mappers.take(ticket) orelse null, roc_host);
            std.debug.panic("roc-ray: unknown request kind {d}", .{request.kind});
        },
    }
}

/// Finish work that cannot outlive this dispatch, moving its callback directly
/// into the response envelope. This deliberately does not consume one of the
/// fixed deferred-operation reservations.
fn startSynchronousRequest(staging: *ResponseStaging, roc_host: *RocHost, request: RequestToHost, ticket: u64, deliver: abi.RocErasedCallable, roc_string_bytes: *usize) void {
    if (builtin.is_test) test_synchronous_task_starts += 1;
    switch (request.kind) {
        REQUEST_READ_CLIPBOARD => stageClipboardRead(staging, roc_host, ticket, roc_string_bytes, deliver),
        else => {
            abi.decrefErasedCallable(deliver, roc_host);
            std.debug.panic("roc-ray: request kind {d} cannot finish synchronously", .{request.kind});
        },
    }
}

/// Report a request the host would not start, in the response it asked for.
///
/// Preserve the request kind and use a fresh private ticket for its `Busy`
/// envelope, so the app can retry on a later cycle without seeing transport
/// correlation state.
fn refuseRequest(staging: *ResponseStaging, roc_host: *RocHost, request: RequestToHost, ticket: u64, deliver: abi.RocErasedCallable) void {
    const raw = switch (request.kind) {
        REQUEST_READ_SMALL_FILE => ResponseStaging.plain(RESPONSE_SMALL_FILE_READ, ticket, READ_ERR_BUSY),
        REQUEST_READ_FILE => ResponseStaging.plain(RESPONSE_FILE_READ, ticket, READ_ERR_BUSY),
        REQUEST_LIST_DIR => ResponseStaging.plain(RESPONSE_DIR_LISTED, ticket, READ_ERR_BUSY),
        REQUEST_DELAY => ResponseStaging.plain(RESPONSE_DELAY, ticket, DELAY_ERR_BUSY),
        REQUEST_SCREENSHOT => ResponseStaging.plain(RESPONSE_SCREENSHOT_FINISHED, ticket, capture.err_busy),
        REQUEST_READ_CLIPBOARD => ResponseStaging.plain(RESPONSE_CLIPBOARD_READ, ticket, READ_ERR_BUSY),
        else => {
            abi.decrefErasedCallable(deliver, roc_host);
            std.debug.panic("roc-ray: unknown request kind {d}", .{request.kind});
        },
    };
    staging.completeDirect(roc_host, raw, deliver);
}

/// Queue a screenshot, or refuse it with a capture error code.
///
/// Returns null when the request was accepted: the framebuffer is read at the
/// end of this frame -- the same instant `Capture.screenshot!` reads it -- so
/// the pixels are the ones the app just drew, and only the report waits for the
/// next input. The sandbox check is the same one the effect uses, so a path that
/// escapes the output directory is still refused rather than rewritten.
fn beginScreenshotTask(ticket: u64, path: []const u8) ?u8 {
    const validation = capture.validateRelativePath(path);
    if (validation != capture.err_none) return validation;

    // Headless runs have no framebuffer to read, so the request is completed
    // synchronously rather than writing a file of zeroes. It is still staged
    // here and delivered on the next input, like every other request response.
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
    capture_screenshot_ticket = ticket;
    return null;
}

/// Stage the response for a screenshot serviced at the end of a past frame.
///
/// Runs before this input's requests are submitted, so the single outcome slot is
/// always empty by the time a new screenshot can be accepted.
fn stageCaptureResults(staging: *ResponseStaging, roc_host: *RocHost) void {
    const done = capture_screenshot_done orelse return;
    capture_screenshot_done = null;
    staging.screenshotFinished(roc_host, done.ticket, done.err);
}

/// Record the outcome of the screenshot just serviced.
///
/// The outcome becomes a response on the next input. A missing private ticket
/// indicates inconsistent host state and aborts.
fn reportScreenshotResult(err: u8) void {
    const ticket = capture_screenshot_ticket orelse
        @panic("roc-ray: serviced a screenshot with no request to report it to");
    capture_screenshot_ticket = null;
    capture_screenshot_done = .{ .ticket = ticket, .err = err };
}

/// Read the clipboard on the calling thread and stage the response.
///
/// The windowing backend only answers on the thread that owns the window, and
/// the read is a pointer copy rather than I/O, so there is nothing to move off
/// the frame thread. One input of latency is the cost of `update` being pure.
fn stageClipboardRead(staging: *ResponseStaging, roc_host: *RocHost, ticket: u64, roc_string_bytes: *usize, deliver: ?abi.RocErasedCallable) void {
    if (headlessMode()) {
        if (!headless_clipboard_set) {
            staging.clipboardRead(roc_host, ticket, READ_ERR_UNAVAILABLE, "", deliver);
            return;
        }
        if (headless_clipboard_len > MAX_SYNC_ROC_STRING_BYTES_PER_INPUT -| roc_string_bytes.*) {
            staging.clipboardRead(roc_host, ticket, READ_ERR_BUSY, "", deliver);
            return;
        }
        roc_string_bytes.* += headless_clipboard_len;
        staging.clipboardRead(roc_host, ticket, 0, headless_clipboard[0..headless_clipboard_len], deliver);
        return;
    }

    // The pointer belongs to the windowing backend: it is null when the
    // clipboard is empty or holds non-text content, must never be freed, and is
    // invalidated by the next clipboard call -- so copy it out now.
    const text = raylib.getClipboardText() orelse {
        staging.clipboardRead(roc_host, ticket, READ_ERR_UNAVAILABLE, "", deliver);
        return;
    };

    // The clipboard is arbitrary content from outside the app -- another
    // process decides how big it is -- and turning it into a `Str` is a copy
    // and a UTF-8 scan on this thread. Cap it at the same size a small file
    // read is capped at, and for the same reason.
    const contents = std.mem.span(text);
    if (contents.len > MAX_INLINE_READ_BYTES) {
        staging.clipboardRead(roc_host, ticket, READ_ERR_TOO_LARGE, "", deliver);
        return;
    }
    if (contents.len > MAX_SYNC_ROC_STRING_BYTES_PER_INPUT -| roc_string_bytes.*) {
        staging.clipboardRead(roc_host, ticket, READ_ERR_BUSY, "", deliver);
        return;
    }
    roc_string_bytes.* += contents.len;
    staging.clipboardRead(roc_host, ticket, 0, contents, deliver);
}

/// Hand one read to the worker, or answer it in this cycle if it was refused.
///
/// `deliver_bytes` decides which response the app will be looking for, and a
/// refusal has to use the same one: an app waiting on `FileRead` must not be
/// answered with `SmallFileRead` because the request ring happened to be full.
/// Returns true when the read was answered in this cycle rather than queued.
fn submitRead(staging: *ResponseStaging, roc_host: *RocHost, ticket: u64, path: []const u8, deliver_bytes: bool, headless_reads: *HeadlessReadBudget) void {
    // Reserve before either branch can start reading or queue a worker request.
    // A terminal `Busy` here means precisely that no filesystem work started.
    if (deliver_bytes and !file_bytes_delivery_reservations.reserve()) {
        stageReadError(staging, roc_host, ticket, RESPONSE_FILE_READ, READ_ERR_BUSY, true);
        return;
    }
    if (headlessMode()) {
        if (!headless_reads.begin()) {
            if (deliver_bytes) {
                stageReservedReadError(staging, roc_host, ticket, RESPONSE_FILE_READ, READ_ERR_BUSY);
            } else {
                stageReadError(staging, roc_host, ticket, RESPONSE_FILE_READ, READ_ERR_BUSY, false);
            }
            return;
        }
        readFileNow(staging, roc_host, ticket, path, deliver_bytes, headless_reads, deliver_bytes);
        return;
    }
    switch (effect_worker.submitReadFile(ticket, path, deliver_bytes)) {
        .accepted => {},
        .busy => if (deliver_bytes)
            stageReservedReadError(staging, roc_host, ticket, RESPONSE_FILE_READ, READ_ERR_BUSY)
        else
            stageReadError(staging, roc_host, ticket, RESPONSE_FILE_READ, READ_ERR_BUSY, false),
        .unavailable => if (deliver_bytes)
            stageReservedReadError(staging, roc_host, ticket, RESPONSE_FILE_READ, READ_ERR_UNAVAILABLE)
        else
            stageReadError(staging, roc_host, ticket, RESPONSE_FILE_READ, READ_ERR_UNAVAILABLE, false),
    }
}

/// Ask for one directory's entries, with exactly the admission a byte-list read
/// gets: one delivery reservation, taken before any filesystem work starts and
/// released by whichever staging call answers the ticket.
///
/// A listing always delivers bytes, so unlike `submitRead` there is no
/// string-returning branch to keep straight.
fn submitListing(staging: *ResponseStaging, roc_host: *RocHost, ticket: u64, path: []const u8, headless_reads: *HeadlessReadBudget) void {
    if (!file_bytes_delivery_reservations.reserve()) {
        stageReadError(staging, roc_host, ticket, RESPONSE_DIR_LISTED, READ_ERR_BUSY, true);
        return;
    }
    if (headlessMode()) {
        if (!headless_reads.begin()) {
            stageReservedReadError(staging, roc_host, ticket, RESPONSE_DIR_LISTED, READ_ERR_BUSY);
            return;
        }
        listDirNow(staging, roc_host, ticket, path, headless_reads);
        return;
    }
    switch (effect_worker.submitListDir(ticket, path)) {
        .accepted => {},
        .busy => stageReservedReadError(staging, roc_host, ticket, RESPONSE_DIR_LISTED, READ_ERR_BUSY),
        .unavailable => stageReservedReadError(staging, roc_host, ticket, RESPONSE_DIR_LISTED, READ_ERR_UNAVAILABLE),
    }
}

/// List on the calling thread and stage the response. Headless only.
///
/// Installs through the same reserved byte-list path a worker listing does, so
/// a headless run and a windowed one differ in which thread allocated the
/// buffer and in nothing the app can observe.
fn listDirNow(staging: *ResponseStaging, roc_host: *RocHost, ticket: u64, path: []const u8, headless_reads: ?*HeadlessReadBudget) void {
    const allocator = allocatorFromHost(roc_host);
    var encoded: ?[]u8 = null;
    const err = encodeListing(mainThreadIo(), allocator, path, &encoded);
    const bytes = encoded orelse {
        stageReservedReadError(staging, roc_host, ticket, RESPONSE_DIR_LISTED, if (err == 0) READ_ERR_FAILED else err);
        return;
    };
    if (headless_reads) |budget| budget.bytes += bytes.len;
    stageReservedByteListRead(staging, roc_host, ticket, RESPONSE_DIR_LISTED, allocator, bytes);
}

/// Report a read that produced no bytes, in whichever response it asked for.
fn stageReadError(staging: *ResponseStaging, roc_host: *RocHost, ticket: u64, response: u8, err: u8, deliver_bytes: bool) void {
    if (deliver_bytes) {
        staging.byteListReadFailed(roc_host, ticket, response, err);
    } else {
        staging.fileRead(roc_host, ticket, err, "");
    }
}

/// Report an error for an already-admitted byte-list read, then return its
/// resource-slot promise. Every path after `FileBytesDeliveryReservations.reserve`
/// goes through this helper or `stageReservedByteListRead` exactly once.
fn stageReservedReadError(staging: *ResponseStaging, roc_host: *RocHost, ticket: u64, response: u8, err: u8) void {
    defer file_bytes_delivery_reservations.release();
    stageReadError(staging, roc_host, ticket, response, err, true);
}

/// Install a finished read's buffer in the typed ARC heap and transfer its sole
/// reference to an ordinary seamless `List(U8)`. No byte payload is copied or
/// allocated here. After this call, the host does not read or retain `bytes`:
/// it is exclusively Roc-owned until list ARC routes its final drop back here.
fn stageByteListRead(staging: *ResponseStaging, roc_host: *RocHost, ticket: u64, response: u8, allocator: std.mem.Allocator, bytes: []u8) void {
    if (bytes.len == 0) {
        allocator.free(bytes);
        staging.byteListRead(roc_host, ticket, response, abi.RocListWith(u8, false).empty());
        return;
    }
    const resource = file_bytes_heap.insert(
        0,
        .{ .allocator = allocator, .bytes = bytes },
    ) orelse {
        allocator.free(bytes);
        staging.byteListReadFailed(roc_host, ticket, response, READ_ERR_BUSY);
        return;
    };
    staging.byteListRead(roc_host, ticket, response, seamlessByteList(resource, bytes));
}

/// Finish an admitted byte-list read. Keep the low-level `stageByteListRead` fallback
/// defensive for direct callers, while this wrapper releases the admission
/// promise on both its successful install and its impossible-in-normal-use
/// late `Busy` fallback.
fn stageReservedByteListRead(staging: *ResponseStaging, roc_host: *RocHost, ticket: u64, response: u8, allocator: std.mem.Allocator, bytes: []u8) void {
    std.debug.assert(file_bytes_delivery_reservations.count != 0);
    defer file_bytes_delivery_reservations.release();
    stageByteListRead(staging, roc_host, ticket, response, allocator, bytes);
}

/// Read on the calling thread and stage the response. Headless only.
///
/// The byte-list path runs here too, and installs exactly the same way, so a
/// headless run and a windowed one differ in which thread allocated the buffer
/// and in nothing else the app can observe.
fn readFileNow(staging: *ResponseStaging, roc_host: *RocHost, ticket: u64, path: []const u8, deliver_bytes: bool, headless_reads: ?*HeadlessReadBudget, byte_list_delivery_reserved: bool) void {
    std.debug.assert(!byte_list_delivery_reserved or deliver_bytes);
    const allocator = allocatorFromHost(roc_host);
    const operation_limit = smallReadLimit(deliver_bytes);
    const limit = if (headless_reads) |budget|
        @min(operation_limit, budget.remainingBytes() + 1)
    else
        operation_limit;
    const budget_limited = limit < operation_limit;
    const bytes = std.Io.Dir.cwd().readFileAlloc(mainThreadIo(), path, allocator, .limited(limit)) catch |err| {
        const code = if (budget_limited) switch (err) {
            error.StreamTooLong => blk: {
                // `readFileAlloc` consumed the remaining credit plus its
                // overflow byte to discover this. Exhaust it so a hostile
                // batch cannot repeat that same partial read 32 times.
                if (headless_reads) |budget| budget.bytes = MAX_HEADLESS_READ_BYTES_PER_INPUT;
                break :blk READ_ERR_BUSY;
            },
            else => readErrorCode(err),
        } else readErrorCode(err);
        if (byte_list_delivery_reserved) {
            stageReservedReadError(staging, roc_host, ticket, RESPONSE_FILE_READ, code);
        } else {
            stageReadError(staging, roc_host, ticket, RESPONSE_FILE_READ, code, deliver_bytes);
        }
        return;
    };
    if (headless_reads) |budget| budget.bytes += bytes.len;
    if (deliver_bytes) {
        if (byte_list_delivery_reserved) {
            stageReservedByteListRead(staging, roc_host, ticket, RESPONSE_FILE_READ, allocator, bytes);
        } else {
            stageByteListRead(staging, roc_host, ticket, RESPONSE_FILE_READ, allocator, bytes);
        }
        return;
    }
    defer allocator.free(bytes);
    staging.fileRead(roc_host, ticket, 0, bytes);
}

/// Record a delay so its result can be delivered once the deadline passes.
///
/// Never answers in this cycle, so it always returns false. The table is sized
/// to the reservation budget and the caller holds one, so it cannot be full --
/// a delay that got this far is always armed.
fn armTimer(ticket: u64, millis: u64) void {
    std.debug.assert(pending_timer_count < pending_timers.len);
    // `millis` comes from the app, so saturate rather than wrap: a wrapped
    // deadline fires immediately, which looks like a delay that did not work.
    const delay_nanos = std.math.mul(u64, millis, std.time.ns_per_ms) catch std.math.maxInt(u64);
    pending_timers[pending_timer_count] = .{ .ticket = ticket, .due_nanos = last_wall_nanos +| delay_nanos };
    pending_timer_count += 1;
}

/// Stage a response for every timer whose deadline has passed.
fn expireTimers(staging: *ResponseStaging, roc_host: *RocHost, now_nanos: u64) void {
    var index: usize = 0;
    while (index < pending_timer_count) {
        if (pending_timers[index].due_nanos <= now_nanos) {
            staging.delayElapsed(roc_host, pending_timers[index].ticket, 0);
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
/// the worker has finished: each of those results is an accepted request holding a
/// reservation, and there are at most `MAX_REQUESTS_IN_FLIGHT` of those.
///
/// The two paths part company here, and the difference is the feature: a small
/// read is copied into a `RocStr` and its buffer freed, while a byte-list read
/// moves the worker's allocation into a typed slot and copies nothing. Only the
/// first is proportional to the file, which is why only the first is capped.
fn stageWorkerResults(staging: *ResponseStaging, roc_host: *RocHost) void {
    var small_read_bytes: usize = 0;
    while (true) {
        const result = effect_worker.takeResult() orelse return;

        if (result.kind == .write_png) {
            staging.screenshotFinished(roc_host, result.ticket, result.err);
            continue;
        }

        const bytes = result.bytes orelse {
            if (result.deliver_bytes) {
                stageReservedReadError(staging, roc_host, result.ticket, result.response, result.err);
            } else {
                stageReadError(staging, roc_host, result.ticket, result.response, result.err, false);
            }
            continue;
        };
        if (result.deliver_bytes) {
            stageReservedByteListRead(staging, roc_host, result.ticket, result.response, effect_worker.allocator, bytes);
            continue;
        }
        // The read stopped at the ceiling, so anything that arrives here fits.
        std.debug.assert(bytes.len <= MAX_INLINE_READ_BYTES);
        small_read_bytes += bytes.len;
        std.debug.assert(small_read_bytes <= MAX_WORKER_SMALL_READ_DELIVERY_BYTES_PER_INPUT);
        defer effect_worker.allocator.free(bytes);
        staging.fileRead(roc_host, result.ticket, 0, bytes);
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
    capture_screenshot_ticket = null;
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

/// Hand a screenshot to the worker, or refuse it.
///
/// The readback above had to happen on this thread -- it is a GL operation, and
/// only inside the drawing scope. Everything after it is CPU work on a plain
/// byte buffer, so it goes to the worker: encoding a 1080p PNG is tens of
/// milliseconds, which is several dropped frames spent on a file the app is not
/// waiting for.
///
/// **There is deliberately no inline fallback.** Encoding here when the worker
/// is full is the exact behaviour that turns a busy host into a stalled one:
/// the queue backs up, so the frame thread takes on the most expensive work in
/// the system, so frames get longer, so the queue drains slower. An app that is
/// told `Busy` can ask again next frame; an app whose frame rate collapsed
/// cannot do anything at all.
///
/// Headless is not this path -- `beginScreenshotTask` answers a headless
/// request without a framebuffer to read -- so nothing here has to make an
/// exception for a run with no frame deadline.
///
/// The pixels are copied rather than moved because the readback buffer belongs
/// to the graphics backend, which frees it on this thread. A memcpy is the
/// price of not having the worker call into raylib, and it is a small fraction
/// of the encode it replaces.
fn writeScreenshot(image: raylib.CaptureImage, path: []const u8) void {
    const ticket = capture_screenshot_ticket orelse
        @panic("roc-ray: writing a screenshot with no private request ticket");

    var resolved_storage: [capture.path_capacity]u8 = undefined;
    const resolved = capture.joinOutputPath(&resolved_storage, captureOutputDir(), path) orelse {
        reportScreenshotResult(capture.err_write_failed);
        return;
    };

    // No worker at all -- the thread would not spawn -- so there is nowhere for
    // this to go except here. Retrying will not change that, which is what
    // `Unavailable` says and `Busy` would not.
    if (!effect_worker.accepting) {
        reportScreenshotResult(capture.err_unavailable);
        return;
    }

    const source = image.pixels();
    const pixels = effect_worker.allocator.alloc(u8, source.len) catch {
        reportScreenshotResult(capture.err_out_of_memory);
        return;
    };

    @memcpy(pixels, source);
    switch (effect_worker.submitWritePng(
        ticket,
        resolved,
        pixels,
        image.width(),
        image.height(),
    )) {
        .accepted => {
            // The outcome now arrives as a worker result. Clear the ticket
            // so a second screenshot this frame is correlated to itself.
            capture_screenshot_ticket = null;
        },
        .busy => {
            effect_worker.allocator.free(pixels);
            reportScreenshotResult(capture.err_busy);
        },
        .unavailable => {
            effect_worker.allocator.free(pixels);
            reportScreenshotResult(capture.err_unavailable);
        },
    }
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
var test_synchronous_task_starts: usize = 0;

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

fn testRequest(roc_host: *RocHost, kind: u8) RequestToHost {
    return .{
        .kind = kind,
        .path = abi.RocStr.empty(),
        .millis = 0,
        .deliver = testCallback(roc_host),
    };
}

fn resetPendingMappersForTest(roc_host: *RocHost) void {
    endPendingMappers(roc_host);
    pending_mappers.next_ticket = 1;
}

test "staged responses become one Roc list, and an idle input allocates none" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    // The ordinary frame completes nothing, so it must allocate nothing.
    var idle = ResponseStaging{};
    const empty = idle.toRocList(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), empty.items().len);
    empty.decref(&roc_host);

    var staging = ResponseStaging{};
    staging.fileRead(&roc_host, 7, 0, "a payload long enough to need the heap");
    staging.delayElapsed(&roc_host, 9, 0);

    const list = staging.take(&roc_host);
    try std.testing.expectEqual(@as(usize, 2), list.items().len);
    try std.testing.expectEqual(RESPONSE_SMALL_FILE_READ, list.items()[0].raw.kind);
    try std.testing.expectEqual(@as(u64, 9), list.items()[1].raw.ticket);

    // Roc consumes the list in the real loop; this stands in for that. A leak
    // reported by std.testing.allocator means a payload escaped.
    for (list.allocationItems()) |item| item.decref(&roc_host);
    list.decref(&roc_host);
    staging.release(&roc_host);
}

test "releasing staged responses frees payloads that never reach Roc" {
    // The path where update fails before the input is delivered.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    var staging = ResponseStaging{};
    staging.fileRead(&roc_host, 1, 0, "contents the staging area still owns");
    staging.fileRead(&roc_host, 2, 0, "and a second one for good measure");
    staging.release(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), staging.count());
}

test "response staging grows past the former request cap and retains capacity" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    var staging = ResponseStaging{};

    // Nine is deliberately the first size the former public batch rejected.
    // A larger burst proves the backing store grows rather than asserting.
    var id: usize = 0;
    while (id < 65) : (id += 1) staging.delayElapsed(&roc_host, id, DELAY_ERR_BUSY);
    const capacity_after_burst = staging.items.capacity;
    try std.testing.expectEqual(@as(usize, 65), staging.count());
    try std.testing.expect(capacity_after_burst >= staging.count());

    const list = staging.take(&roc_host);
    for (list.allocationItems()) |item| item.decref(&roc_host);
    list.decref(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), staging.count());

    // The common warm frame appends without allocating or growing again.
    staging.delayElapsed(&roc_host, 99, 0);
    try std.testing.expectEqual(capacity_after_burst, staging.items.capacity);
    staging.release(&roc_host);
}

test "submission accepts nine requests without a request-count admission limit" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    pending_timer_count = 0;
    last_wall_nanos = 0;
    defer {
        pending_timer_count = 0;
        resetPendingMappersForTest(&roc_host);
    }

    var requests: [9]RequestToHost = undefined;
    for (&requests) |*request| {
        request.* = testRequest(&roc_host, REQUEST_DELAY);
        request.millis = 1;
    }
    var staging = ResponseStaging{};
    submitRequests(&staging, &roc_host, abi.RocList(RequestToHost).fromSlice(&requests, &roc_host));
    try std.testing.expectEqual(@as(usize, 9), pending_timer_count);
    try std.testing.expectEqual(@as(usize, 9), pending_mappers.count);

    expireTimers(&staging, &roc_host, std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 9), staging.count());
    try std.testing.expectEqual(@as(usize, 0), pending_mappers.count);
    staging.release(&roc_host);
}

test "unique request lists move callbacks while shared lists retain them" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    pending_timer_count = 0;
    last_wall_nanos = 0;
    defer {
        pending_timer_count = 0;
        resetPendingMappersForTest(&roc_host);
    }
    test_callback_drops = 0;

    // The ordinary path is unique: dispatch nulls its list slot and moves the
    // one callback reference into the table without an ARC round trip.
    {
        var requests = [_]RequestToHost{testRequest(&roc_host, REQUEST_DELAY)};
        requests[0].millis = 1;
        var staging = ResponseStaging{};
        submitRequests(&staging, &roc_host, abi.RocList(RequestToHost).fromSlice(&requests, &roc_host));
        expireTimers(&staging, &roc_host, std.time.ns_per_ms);
        staging.release(&roc_host);
        try std.testing.expectEqual(@as(usize, 1), test_callback_drops);
    }

    // A shared list keeps its own element alive. Dispatch takes exactly one
    // additional callback ref for the pending table, then the caller releases
    // the original list after its independent use is complete.
    {
        var requests = [_]RequestToHost{testRequest(&roc_host, REQUEST_DELAY)};
        requests[0].millis = 1;
        const shared = abi.RocList(RequestToHost).fromSlice(&requests, &roc_host);
        shared.incref(1);
        var staging = ResponseStaging{};
        submitRequests(&staging, &roc_host, shared);
        expireTimers(&staging, &roc_host, std.time.ns_per_ms);
        staging.release(&roc_host);
        try std.testing.expectEqual(@as(usize, 1), test_callback_drops);

        // The caller's shared reference owns the original callback until here.
        for (shared.allocationItems()) |request| request.decref(&roc_host);
        shared.decref(&roc_host);
        try std.testing.expectEqual(@as(usize, 2), test_callback_drops);
    }
}

test "a shared synchronous request list retains its callback independently" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer resetPendingMappersForTest(&roc_host);
    test_callback_drops = 0;

    var requests = [_]RequestToHost{testRequest(&roc_host, REQUEST_READ_CLIPBOARD)};
    const shared = abi.RocList(RequestToHost).fromSlice(&requests, &roc_host);
    shared.incref(1);
    var staging = ResponseStaging{};
    submitRequests(&staging, &roc_host, shared);
    try std.testing.expectEqual(@as(usize, 0), pending_mappers.count);
    staging.release(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), test_callback_drops);

    // The caller's retained list reference owns the original callback until it
    // independently releases that list.
    for (shared.allocationItems()) |request| request.decref(&roc_host);
    shared.decref(&roc_host);
    try std.testing.expectEqual(@as(usize, 1), test_callback_drops);
}

test "more than 32 requests receive terminal envelopes without a public request cap" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    pending_timer_count = 0;
    last_wall_nanos = 0;
    defer {
        pending_timer_count = 0;
        resetPendingMappersForTest(&roc_host);
    }

    var staging = ResponseStaging{};

    const request_count = MAX_REQUESTS_IN_FLIGHT * 2 + 1;
    var requests: [request_count]RequestToHost = undefined;
    for (&requests) |*request| {
        request.* = testRequest(&roc_host, REQUEST_DELAY);
        request.millis = 1;
    }
    submitRequests(&staging, &roc_host, abi.RocList(RequestToHost).fromSlice(&requests, &roc_host));
    try std.testing.expectEqual(MAX_REQUESTS_IN_FLIGHT, pending_timer_count);
    try std.testing.expectEqual(MAX_REQUESTS_IN_FLIGHT, pending_mappers.count);
    try std.testing.expectEqual(request_count - MAX_REQUESTS_IN_FLIGHT, staging.count());
    for (staging.items.items) |item| {
        try std.testing.expectEqual(RESPONSE_DELAY, item.raw.kind);
        try std.testing.expectEqual(DELAY_ERR_BUSY, item.raw.err);
    }
    expireTimers(&staging, &roc_host, std.time.ns_per_ms);
    try std.testing.expectEqual(request_count, staging.count());
    try std.testing.expectEqual(@as(usize, 0), pending_mappers.count);
    staging.release(&roc_host);
}

test "synchronous clipboard bypasses a full deferred callback table" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        pending_timer_count = 0;
        resetPendingMappersForTest(&roc_host);
    }
    test_callback_drops = 0;
    last_wall_nanos = 0;

    // Keep every deferred reservation occupied. Clipboard remains admissible
    // because it completes immediately and never enters that table.
    var held: usize = 0;
    while (held < MAX_REQUESTS_IN_FLIGHT) : (held += 1) {
        const ticket = pending_mappers.issueTicket();
        try std.testing.expect(pending_mappers.insert(ticket, testCallback(&roc_host)));
        armTimer(ticket, 1);
    }

    const clipboard_text = "clipboard text";
    @memcpy(headless_clipboard[0..clipboard_text.len], clipboard_text);
    headless_clipboard_len = clipboard_text.len;
    headless_clipboard_set = true;
    defer {
        headless_clipboard_len = 0;
        headless_clipboard_set = false;
    }

    var requests = [_]RequestToHost{testRequest(&roc_host, REQUEST_READ_CLIPBOARD)};

    var staging = ResponseStaging{};
    submitRequests(&staging, &roc_host, abi.RocList(RequestToHost).fromSlice(&requests, &roc_host));
    try std.testing.expectEqual(MAX_REQUESTS_IN_FLIGHT, pending_mappers.count);
    try std.testing.expectEqual(MAX_REQUESTS_IN_FLIGHT, pending_timer_count);
    try std.testing.expectEqual(@as(usize, 1), staging.count());
    try std.testing.expectEqual(RESPONSE_CLIPBOARD_READ, staging.items.items[0].raw.kind);
    try std.testing.expectEqual(@as(u8, 0), staging.items.items[0].raw.err);
    try std.testing.expectEqualStrings(clipboard_text, staging.items.items[0].raw.contents.asSlice());
    staging.release(&roc_host);
    try std.testing.expectEqual(@as(usize, 1), test_callback_drops);
    resetPendingMappersForTest(&roc_host);
    try std.testing.expectEqual(MAX_REQUESTS_IN_FLIGHT + 1, test_callback_drops);
}

test "private tickets use their last value without wrapping" {
    var callbacks = PendingMappers{ .next_ticket = std.math.maxInt(u64) - 1 };
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, callbacks.issueTicket());
    try std.testing.expectEqual(std.math.maxInt(u64), callbacks.issueTicket());
    try std.testing.expectEqual(@as(u64, 0), callbacks.next_ticket);
}

test "a direct Busy response moves its mapper into staging" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer resetPendingMappersForTest(&roc_host);
    test_callback_drops = 0;

    var staging = ResponseStaging{};
    var held: usize = 0;
    while (held < MAX_REQUESTS_IN_FLIGHT) : (held += 1) {
        const ticket = pending_mappers.issueTicket();
        try std.testing.expect(pending_mappers.insert(ticket, testCallback(&roc_host)));
    }
    const request = testRequest(&roc_host, REQUEST_DELAY);
    const ticket = pending_mappers.issueTicket();
    refuseRequest(&staging, &roc_host, request, ticket, request.deliver);
    try std.testing.expectEqual(@as(usize, 1), staging.count());
    try std.testing.expectEqual(DELAY_ERR_BUSY, staging.items.items[0].raw.err);
    try std.testing.expect(staging.items.items[0].deliver != null);
    staging.release(&roc_host);
    try std.testing.expectEqual(@as(usize, 1), test_callback_drops);
}

test "timers complete with their private callback in observed order" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    pending_timer_count = 0;
    last_wall_nanos = 0;
    defer {
        pending_timer_count = 0;
        resetPendingMappersForTest(&roc_host);
    }
    var staging = ResponseStaging{};
    const first = pending_mappers.issueTicket();
    const second = pending_mappers.issueTicket();
    try std.testing.expect(pending_mappers.insert(first, testCallback(&roc_host)));
    try std.testing.expect(pending_mappers.insert(second, testCallback(&roc_host)));
    armTimer(first, 10);
    armTimer(second, 30);
    expireTimers(&staging, &roc_host, 40 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 2), staging.count());
    try std.testing.expectEqual(first, staging.items.items[0].raw.ticket);
    try std.testing.expectEqual(second, staging.items.items[1].raw.ticket);
    try std.testing.expectEqual(@as(usize, 0), pending_mappers.count);
    staging.release(&roc_host);
}

test "independent requests preserve observed response order" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer resetPendingMappersForTest(&roc_host);

    const first_submitted = pending_mappers.issueTicket();
    const second_submitted = pending_mappers.issueTicket();
    try std.testing.expect(pending_mappers.insert(first_submitted, testCallback(&roc_host)));
    try std.testing.expect(pending_mappers.insert(second_submitted, testCallback(&roc_host)));

    var staging = ResponseStaging{};
    // Independent host work is allowed to finish in either order. Staging
    // preserves observation order; it does not reorder by submission ticket.
    staging.completeTicket(&roc_host, ResponseStaging.plain(RESPONSE_DELAY, second_submitted, 0));
    staging.completeTicket(&roc_host, ResponseStaging.plain(RESPONSE_DELAY, first_submitted, 0));
    try std.testing.expectEqual(second_submitted, staging.items.items[0].raw.ticket);
    try std.testing.expectEqual(first_submitted, staging.items.items[1].raw.ticket);
    try std.testing.expectEqual(@as(usize, 0), pending_mappers.count);
    staging.release(&roc_host);
}

test "unknown and duplicate tickets do not consume another callback" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer resetPendingMappersForTest(&roc_host);
    test_callback_drops = 0;
    var staging = ResponseStaging{};
    const ticket = pending_mappers.issueTicket();
    try std.testing.expect(pending_mappers.insert(ticket, testCallback(&roc_host)));
    const deliver = pending_mappers.take(ticket) orelse return error.CallbackWasNotRetained;
    staging.completeDirect(&roc_host, ResponseStaging.plain(RESPONSE_DELAY, ticket, 0), deliver);
    try std.testing.expectEqual(@as(?abi.RocErasedCallable, null), pending_mappers.take(ticket));
    try std.testing.expectEqual(@as(?abi.RocErasedCallable, null), pending_mappers.take(ticket + 99));
    try std.testing.expectEqual(@as(usize, 1), staging.count());
    try std.testing.expectEqual(ticket, staging.items.items[0].raw.ticket);
    staging.release(&roc_host);
    try std.testing.expectEqual(@as(usize, 1), test_callback_drops);
}

test "pending response mappers are dropped once on shutdown" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer resetPendingMappersForTest(&roc_host);
    test_callback_drops = 0;
    var count: usize = 0;
    while (count < MAX_REQUESTS_IN_FLIGHT) : (count += 1) {
        const ticket = pending_mappers.issueTicket();
        try std.testing.expect(pending_mappers.insert(ticket, testCallback(&roc_host)));
    }
    pending_mappers.release(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), pending_mappers.count);
    try std.testing.expectEqual(MAX_REQUESTS_IN_FLIGHT, test_callback_drops);
}

test "ending an app lifetime clears timers before ticket numbering resets" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer resetPendingMappersForTest(&roc_host);
    test_callback_drops = 0;
    last_wall_nanos = 0;

    // A delayed request from the first lifetime uses the first private ticket.
    // Ending that lifetime must remove both its timer and callback.
    exit_requested = 99;
    beginPendingMappers();
    try std.testing.expectEqual(@as(?i64, null), exit_requested);
    const first = pending_mappers.issueTicket();
    try std.testing.expectEqual(@as(u64, 1), first);
    try std.testing.expect(pending_mappers.insert(first, testCallback(&roc_host)));
    armTimer(first, std.math.maxInt(u64));
    endPendingMappers(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), pending_mappers.count);
    try std.testing.expectEqual(@as(usize, 0), pending_timer_count);
    try std.testing.expectEqual(@as(usize, 1), test_callback_drops);

    // The next lifetime legitimately reuses ticket one. A stale timer would
    // consume this new callback (or trip the duplicate-ticket assertion) here.
    beginPendingMappers();
    const second = pending_mappers.issueTicket();
    try std.testing.expectEqual(@as(u64, 1), second);
    try std.testing.expect(pending_mappers.insert(second, testCallback(&roc_host)));
    var staging = ResponseStaging{};
    expireTimers(&staging, &roc_host, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 0), staging.count());
    try std.testing.expectEqual(@as(usize, 1), pending_mappers.count);
    endPendingMappers(&roc_host);
    try std.testing.expectEqual(@as(usize, 2), test_callback_drops);
    staging.release(&roc_host);
}

test "a delay is a real second even while the simulation clock is fixed-step" {
    pending_timer_count = 0;
    capture_clock_offset_ns = 0;
    capture_clock_last_real_ns = 0;
    defer {
        pending_timer_count = 0;
        capture_clock_offset_ns = 0;
        capture_clock_last_real_ns = 0;
    }

    // A 30fps recording of a frame that really took 100ms. The simulation clock
    // is told the frame was 1/30s, so it falls behind the wall clock -- which
    // is the point: the captured animation plays at the rate it asked for.
    const real_ns: u64 = 100 * std.time.ns_per_ms;
    const simulated = captureAdjustedClock(real_ns, 1.0 / 30.0);
    try std.testing.expect(simulated < real_ns);

    // A delay armed on that frame is still due one real second later. Arming it
    // off the simulation clock would have made `Delay(1000)` mean whatever the
    // recording's step happened to add up to.
    last_frame_nanos = simulated;
    last_wall_nanos = real_ns;
    _ = armTimer(1, 1_000);
    try std.testing.expectEqual(real_ns + std.time.ns_per_s, pending_timers[0].due_nanos);
}

test "an absurd delay saturates its deadline instead of wrapping to the past" {
    pending_timer_count = 0;
    last_wall_nanos = 1_000;
    _ = armTimer(1, std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), pending_timers[0].due_nanos);
    pending_timer_count = 0;
}

test "a file that is not text is refused rather than made into a Str" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    var staging = ResponseStaging{};
    defer staging.release(&roc_host);

    // A lone continuation byte: short, well inside every limit, and not UTF-8.
    // `RocStr.fromSlice` would have copied it without complaint, and every
    // later string operation on the result would have been undefined.
    staging.fileRead(&roc_host, 1, 0, "\x80 not text");
    try std.testing.expectEqual(RESPONSE_SMALL_FILE_READ, staging.items.items[0].raw.kind);
    try std.testing.expectEqual(READ_ERR_NOT_UTF8, staging.items.items[0].raw.err);
    try std.testing.expectEqual(@as(usize, 0), staging.items.items[0].raw.contents.asSlice().len);

    // Valid text still arrives as text, including the empty file.
    staging.fileRead(&roc_host, 2, 0, "caf\u{e9}");
    try std.testing.expectEqual(@as(u8, 0), staging.items.items[1].raw.err);
    try std.testing.expectEqualStrings("caf\u{e9}", staging.items.items[1].raw.contents.asSlice());

    staging.fileRead(&roc_host, 3, 0, "");
    try std.testing.expectEqual(@as(u8, 0), staging.items.items[2].raw.err);
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

    var staging = ResponseStaging{};
    if (oversized.len > MAX_INLINE_READ_BYTES) {
        staging.fileRead(&roc_host, 1, READ_ERR_TOO_LARGE, "");
    } else {
        staging.fileRead(&roc_host, 1, 0, oversized);
    }

    try std.testing.expectEqual(READ_ERR_TOO_LARGE, staging.items.items[0].raw.err);
    // Nothing was copied: the response carries an empty string.
    try std.testing.expectEqual(@as(usize, 0), staging.items.items[0].raw.contents.asSlice().len);
    staging.release(&roc_host);
}

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

/// The owning byte list a staged `ReadFile` response is carrying.
fn stagedBytes(item: RawResponse) abi.RocListWith(u8, false) {
    return item.bytes;
}

test "completing a large read transfers the worker allocation without copying" {
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

    // Stands in for the worker thread, which allocates and fills the buffer
    // before the frame thread ever sees it. A different allocator on purpose:
    // whatever the frame thread does shows up in `counter` and nowhere else.
    const worker_bytes = try std.testing.allocator.alloc(u8, file_bytes);
    @memset(worker_bytes, 'z');
    const worker_ptr = worker_bytes.ptr;

    var staging = ResponseStaging{};
    // Staging is persistent runtime bookkeeping, not a per-file-byte cost. Warm
    // it before measuring the two delivery paths below.
    staging.delayElapsed(&roc_host, 0, 0);
    staging.items.clearRetainingCapacity();
    counter.allocated_bytes = 0;
    stageByteListRead(&staging, &roc_host, 1, RESPONSE_FILE_READ, std.testing.allocator, worker_bytes);
    const large_cost = counter.allocated_bytes;

    try std.testing.expectEqual(@as(u8, 0), staging.items.items[0].raw.err);
    try std.testing.expectEqual(@as(usize, file_bytes), stagedBytes(staging.items.items[0].raw).len());
    try std.testing.expectEqual(@as(usize, 0), staging.items.items[0].raw.contents.asSlice().len);

    // Installed, not copied: the List reads the worker's own allocation at the
    // same address, and has a tagged typed-heap allocation owner.
    const delivered = stagedBytes(staging.items.items[0].raw);
    try std.testing.expectEqual(worker_ptr, delivered.elements_ptr.?);
    try std.testing.expect(delivered.isSeamlessSlice());

    // The same delivery for a file four million times smaller costs the frame
    // thread exactly the same, which is the property being claimed.
    const small_bytes = try std.testing.allocator.dupe(u8, "four bytes worth, near enough");
    counter.allocated_bytes = 0;
    stageByteListRead(&staging, &roc_host, 2, RESPONSE_FILE_READ, std.testing.allocator, small_bytes);
    try std.testing.expectEqual(large_cost, counter.allocated_bytes);

    // The control. A 64 KiB small-file response moves its payload through
    // the Roc allocator, so the number above is a result and not a broken meter.
    const inline_bytes = try std.testing.allocator.alloc(u8, MAX_INLINE_READ_BYTES);
    defer std.testing.allocator.free(inline_bytes);
    @memset(inline_bytes, 'a');
    counter.allocated_bytes = 0;
    staging.fileRead(&roc_host, 3, 0, inline_bytes);
    try std.testing.expect(counter.allocated_bytes >= MAX_INLINE_READ_BYTES);

    staging.release(&roc_host);
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
        var staging = ResponseStaging{};
        stageByteListRead(&staging, &roc_host, 1, RESPONSE_FILE_READ, std.testing.allocator, owned);
        const whole = stagedBytes(staging.items.items[0].raw);

        // The staged response owns the first list reference. Give the three
        // aliases below their own references before that response drops.
        whole.incref(3);
        try std.testing.expectEqual(owned.ptr, whole.elements_ptr.?);
        try std.testing.expect(whole.isSeamlessSlice());
        try std.testing.expectEqualStrings(payload, whole.items());

        // Completing the original read leaves the List aliases as the sole
        // owners of the typed resource slot.
        staging.release(&roc_host);
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
    var staging = ResponseStaging{};
    stageByteListRead(&staging, &roc_host, 1, RESPONSE_FILE_READ, std.testing.allocator, owned);
    const empty = stagedBytes(staging.items.items[0].raw);
    try std.testing.expect(empty.isEmpty());
    try std.testing.expect(!empty.isSeamlessSlice());

    // Canonical empties do not retain a typed resource slot.
    staging.release(&roc_host);
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

test "a full byte-list heap refuses ReadFile before it opens the path" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        file_bytes_delivery_reservations.clearAfterWorkStops();
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        file_bytes_heap.deinitAll();
    }

    // One response per read, and an input carries at most its own budget, so
    // each read gets a staging area of its own rather than sharing one. The
    // responses are kept rather than released, because releasing one is now
    // what frees its bytes -- the heap only fills while the app is still holding.
    var held: [MAX_LIVE_FILE_BYTE_LISTS]RawResponse = undefined;
    var filled: usize = 0;
    while (filled < MAX_LIVE_FILE_BYTE_LISTS) : (filled += 1) {
        const owned = try std.testing.allocator.dupe(u8, "held");
        var staging = ResponseStaging{};
        stageByteListRead(&staging, &roc_host, filled, RESPONSE_FILE_READ, std.testing.allocator, owned);
        try std.testing.expectEqual(@as(u8, 0), staging.items.items[0].raw.err);
        held[filled] = staging.items.items[0].raw;
        staging.items.clearRetainingCapacity();
        staging.items.deinit(allocatorFromHost(&roc_host));
    }
    try std.testing.expectEqual(MAX_LIVE_FILE_BYTE_LISTS, file_bytes_heap.active());

    // This must report `Busy`, not `NotFound`, and must not consume headless
    // operation credit: admission happens before either I/O path can begin.
    var headless_reads = HeadlessReadBudget{};
    var before_open = ResponseStaging{};
    submitRead(&before_open, &roc_host, 998, testing_tmp_prefix ++ "definitely-not-here.txt", true, &headless_reads);
    try std.testing.expectEqual(READ_ERR_BUSY, before_open.items.items[0].raw.err);
    try std.testing.expectEqual(@as(usize, 0), headless_reads.operations);
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);
    before_open.release(&roc_host);

    // Low-level installation remains defensive for callers which already own
    // bytes. The normal `submitRead` path above never starts this doomed read.
    const refused = try std.testing.allocator.dupe(u8, "no slot for this");
    var full = ResponseStaging{};
    stageByteListRead(&full, &roc_host, 999, RESPONSE_FILE_READ, std.testing.allocator, refused);
    try std.testing.expectEqual(RESPONSE_FILE_READ, full.items.items[0].raw.kind);
    try std.testing.expectEqual(READ_ERR_BUSY, full.items.items[0].raw.err);
    try std.testing.expectEqual(@as(usize, 0), full.items.items[0].raw.bytes.len());
    try std.testing.expectEqual(MAX_LIVE_FILE_BYTE_LISTS, file_bytes_heap.active());
    full.release(&roc_host);

    for (held) |item| item.decref(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
}

test "a headless read delivers bytes by the same path a worker result does" {
    // Headless runs the read on this thread for determinism, but it must still
    // hand back bytes rather than a string, or CI would exercise a different
    // feature from the one a desktop run does.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        file_bytes_heap.deinitAll();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = "read on the frame thread, delivered as bytes";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bytes.txt", .data = payload });

    var path_buffer: [capture.path_capacity]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, testing_tmp_prefix ++ "{s}/bytes.txt", .{tmp.sub_path});

    var staging = ResponseStaging{};
    readFileNow(&staging, &roc_host, 3, path, true, null, false);
    try std.testing.expectEqual(RESPONSE_FILE_READ, staging.items.items[0].raw.kind);
    try std.testing.expectEqual(@as(u8, 0), staging.items.items[0].raw.err);
    try std.testing.expectEqual(@as(usize, payload.len), stagedBytes(staging.items.items[0].raw).len());
    try std.testing.expectEqualStrings(payload, stagedBytes(staging.items.items[0].raw).items());

    // A read that fails still answers on the byte-list path -- an app waiting for
    // `FileRead` must never be answered with `SmallFileRead`.
    readFileNow(&staging, &roc_host, 4, testing_tmp_prefix ++ "definitely-not-here.txt", true, null, false);
    try std.testing.expectEqual(RESPONSE_FILE_READ, staging.items.items[1].raw.kind);
    try std.testing.expectEqual(READ_ERR_NOT_FOUND, staging.items.items[1].raw.err);

    staging.release(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
}

test "headless ReadFile releases its delivery reservation on success and NotFound" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        file_bytes_delivery_reservations.clearAfterWorkStops();
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        file_bytes_heap.deinitAll();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bytes.txt", .data = "inline result" });
    var path_buffer: [capture.path_capacity]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, testing_tmp_prefix ++ "{s}/bytes.txt", .{tmp.sub_path});

    var budget = HeadlessReadBudget{};
    var staging = ResponseStaging{};
    submitRead(&staging, &roc_host, 1, path, true, &budget);
    try std.testing.expectEqual(@as(u8, 0), staging.items.items[0].raw.err);
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);

    submitRead(&staging, &roc_host, 2, testing_tmp_prefix ++ "definitely-not-here.txt", true, &budget);
    try std.testing.expectEqual(READ_ERR_NOT_FOUND, staging.items.items[1].raw.err);
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);

    staging.release(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
}

test "headless reads admit 32 mixed filesystem operations and terminally refuse the rest" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        resetPendingMappersForTest(&roc_host);
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        file_bytes_heap.deinitAll();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tiny.txt", .data = "tiny" });
    var path_buffer: [capture.path_capacity]u8 = undefined;
    const present = try std.fmt.bufPrint(&path_buffer, testing_tmp_prefix ++ "{s}/tiny.txt", .{tmp.sub_path});
    const missing = testing_tmp_prefix ++ "definitely-not-here.txt";

    const request_count = MAX_HEADLESS_READS_PER_INPUT + 3;
    var requests: [request_count]RequestToHost = undefined;
    for (&requests, 0..) |*request, id| {
        const path = if (id % 3 == 0) present else missing;
        request.* = .{
            .kind = if (id % 2 == 0) REQUEST_READ_FILE else REQUEST_READ_SMALL_FILE,
            .path = abi.RocStr.fromSlice(path, &roc_host),
            .millis = 0,
            .deliver = testCallback(&roc_host),
        };
    }

    var staging = ResponseStaging{};
    submitRequests(&staging, &roc_host, abi.RocList(RequestToHost).fromSlice(&requests, &roc_host));
    try std.testing.expectEqual(request_count, staging.count());
    for (staging.items.items[0..MAX_HEADLESS_READS_PER_INPUT]) |item| {
        try std.testing.expect(item.raw.err == 0 or item.raw.err == READ_ERR_NOT_FOUND);
    }
    for (staging.items.items[MAX_HEADLESS_READS_PER_INPUT..]) |item| {
        try std.testing.expectEqual(READ_ERR_BUSY, item.raw.err);
    }
    staging.release(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
}

test "headless read byte credit admits one 16 MiB byte list then reports Busy" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        file_bytes_heap.deinitAll();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = try std.testing.allocator.alloc(u8, MAX_HEADLESS_READ_BYTES_PER_INPUT);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'b');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "largest-allowed.bin", .data = payload });
    var path_buffer: [capture.path_capacity]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, testing_tmp_prefix ++ "{s}/largest-allowed.bin", .{tmp.sub_path});

    var budget = HeadlessReadBudget{};
    try std.testing.expect(budget.begin());
    var staging = ResponseStaging{};
    readFileNow(&staging, &roc_host, 1, path, true, &budget, false);
    try std.testing.expectEqual(@as(u8, 0), staging.items.items[0].raw.err);
    try std.testing.expectEqual(MAX_HEADLESS_READ_BYTES_PER_INPUT, budget.bytes);

    // The next request is refused before opening the file. It still gets the
    // same typed terminal response the app would receive in a real frame.
    submitRead(&staging, &roc_host, 2, path, true, &budget);
    try std.testing.expectEqual(READ_ERR_BUSY, staging.items.items[1].raw.err);
    staging.release(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
}

test "a budget-limited headless read exhausts its credit before later retries" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "larger-than-credit.txt", .data = "0123456789" });
    var path_buffer: [capture.path_capacity]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, testing_tmp_prefix ++ "{s}/larger-than-credit.txt", .{tmp.sub_path});

    var budget = HeadlessReadBudget{ .bytes = MAX_HEADLESS_READ_BYTES_PER_INPUT - 4 };
    try std.testing.expect(budget.begin());
    var staging = ResponseStaging{};
    readFileNow(&staging, &roc_host, 1, path, false, &budget, false);
    try std.testing.expectEqual(READ_ERR_BUSY, staging.items.items[0].raw.err);
    try std.testing.expectEqual(MAX_HEADLESS_READ_BYTES_PER_INPUT, budget.bytes);

    // This cannot perform a second partial read: exhausted byte credit is
    // admitted as a terminal Busy before the path is opened.
    submitRead(&staging, &roc_host, 2, path, false, &budget);
    try std.testing.expectEqual(READ_ERR_BUSY, staging.items.items[1].raw.err);
    try std.testing.expectEqual(@as(usize, 1), budget.operations);
    staging.release(&roc_host);
}

test "taking an input's responses hands them over and empties the staging area" {
    // The list belongs to Roc after this, so releasing the staging area must
    // not free the same payloads a second time -- and anything staged after the
    // handover is a response for the *next* input, not this one.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);

    var staging = ResponseStaging{};
    staging.fileRead(&roc_host, 1, 0, "contents long enough to reach the heap");

    const list = staging.take(&roc_host);
    try std.testing.expectEqual(@as(usize, 1), list.items().len);
    try std.testing.expectEqual(@as(usize, 0), staging.count());

    // Stands in for Roc consuming the input.
    for (list.allocationItems()) |item| item.decref(&roc_host);
    list.decref(&roc_host);

    staging.delayElapsed(&roc_host, 2, 0);
    try std.testing.expectEqual(@as(usize, 1), staging.count());
    staging.release(&roc_host);
}

test "a screenshot request that escapes the output directory is refused, not rewritten" {
    defer {
        capture_screenshot_ticket = null;
        capture_screenshot_pending = false;
    }

    // The sandbox check runs first, so the refusal becomes a response rather
    // than a file appearing beside the example source.
    const refusal = beginScreenshotTask(4, "../escaped.png") orelse return error.TestExpectedRefusal;
    try std.testing.expectEqual(capture.err_path_escapes, refusal);
    try std.testing.expectEqual(@as(?u64, null), capture_screenshot_ticket);

    // A valid path is accepted. Tests run headless, where there is no
    // framebuffer to read, so it is answered at once instead of at frame end.
    const accepted = beginScreenshotTask(5, "scene.png") orelse return error.TestExpectedImmediateAnswer;
    try std.testing.expectEqual(capture.err_none, accepted);
    try std.testing.expectEqual(@as(?u64, null), capture_screenshot_ticket);
}

test "a serviced screenshot request answers on the next input" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = abi.makeRocHost(&roc_env);
    defer {
        capture_screenshot_ticket = null;
        capture_screenshot_done = null;
        resetPendingMappersForTest(&roc_host);
    }

    // The frame that asked carries no response for it: the write happens at
    // the end of that frame, after its input has already gone to Roc.
    capture_screenshot_ticket = 9;
    var staging = ResponseStaging{};
    try std.testing.expect(pending_mappers.insert(9, testCallback(&roc_host)));
    stageCaptureResults(&staging, &roc_host);
    try std.testing.expectEqual(@as(usize, 0), staging.count());

    reportScreenshotResult(capture.err_write_failed);
    stageCaptureResults(&staging, &roc_host);
    try std.testing.expectEqual(@as(usize, 1), staging.count());
    try std.testing.expectEqual(RESPONSE_SCREENSHOT_FINISHED, staging.items.items[0].raw.kind);
    try std.testing.expectEqual(@as(u64, 9), staging.items.items[0].raw.ticket);
    try std.testing.expectEqual(capture.err_write_failed, staging.items.items[0].raw.err);

    // Exactly one response per accepted request, so the next input reports none
    // and the callback has been given back to Roc.
    stageCaptureResults(&staging, &roc_host);
    try std.testing.expectEqual(@as(usize, 1), staging.count());
    try std.testing.expectEqual(@as(usize, 0), pending_mappers.count);
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

    var empty = ResponseStaging{};
    var roc_string_bytes: usize = 0;
    stageClipboardRead(&empty, &roc_host, 1, &roc_string_bytes, null);
    try std.testing.expectEqual(RESPONSE_CLIPBOARD_READ, empty.items.items[0].raw.kind);
    try std.testing.expectEqual(READ_ERR_UNAVAILABLE, empty.items.items[0].raw.err);
    empty.release(&roc_host);

    const text = "pasted from the scripted clipboard";
    @memcpy(headless_clipboard[0..text.len], text);
    headless_clipboard_len = text.len;
    headless_clipboard_set = true;

    var staging = ResponseStaging{};
    stageClipboardRead(&staging, &roc_host, 2, &roc_string_bytes, null);
    try std.testing.expectEqual(@as(u64, 2), staging.items.items[0].raw.ticket);
    try std.testing.expectEqual(@as(u8, 0), staging.items.items[0].raw.err);
    try std.testing.expectEqualStrings(text, staging.items.items[0].raw.contents.asSlice());
    staging.release(&roc_host);

    // A valid clipboard remains valid when the frame's shared string-copy
    // budget is spent; it is deferred to the app as Busy, not copied anyway.
    var exhausted = ResponseStaging{};
    roc_string_bytes = MAX_SYNC_ROC_STRING_BYTES_PER_INPUT - text.len + 1;
    stageClipboardRead(&exhausted, &roc_host, 3, &roc_string_bytes, null);
    try std.testing.expectEqual(READ_ERR_BUSY, exhausted.items.items[0].raw.err);
    exhausted.release(&roc_host);
}

test "a saturated worker refuses with Busy rather than running work inline" {
    // Running it here would stall the frame, which is what the split exists to
    // prevent. A refusal is still a response, so the app is never left
    // waiting for a callback result that will never arrive.
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

test "worker small-read delivery is independently bounded by reservations" {
    // Worker responses are drained before dispatch. The request submission string-copy
    // budget must not be used to silently drop them; their separate bound is
    // the worker/reservation capacity times the per-read string cap.
    try std.testing.expectEqual(
        MAX_REQUESTS_IN_FLIGHT * MAX_INLINE_READ_BYTES,
        MAX_WORKER_SMALL_READ_DELIVERY_BYTES_PER_INPUT,
    );
}

test "worker queues carry only native tickets and data" {
    // This compile-time check protects the thread boundary: callbacks are Roc
    // values and belong only in the frame-thread pending table and response
    // envelope, never in a request/result that can cross to the worker.
    try std.testing.expect(@hasField(EffectWorker.Request, "ticket"));
    try std.testing.expect(@hasField(EffectWorker.Result, "ticket"));
    try std.testing.expect(!@hasField(EffectWorker.Request, "deliver"));
    try std.testing.expect(!@hasField(EffectWorker.Result, "deliver"));
    try std.testing.expect(!@hasField(RequestToHost, "id"));
    try std.testing.expect(!@hasField(RequestToHost, "ticket"));
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

test "shutdown flushes accepted writes and abandons pending reads" {
    var worker = EffectWorker{};
    worker.allocator = std.testing.allocator;
    worker.accepting = true;

    // Interleaved on purpose: the flush has to walk past the reads rather than
    // stopping at the first one it does not want.
    const pixels = try std.testing.allocator.alloc(u8, 4);
    @memset(pixels, 0xff);
    try std.testing.expectEqual(EffectWorker.Submission.accepted, worker.submitReadFile(1, "a", false));
    try std.testing.expectEqual(EffectWorker.Submission.accepted, worker.submitWritePng(2, "shot.png", pixels, 1, 1));
    try std.testing.expectEqual(EffectWorker.Submission.accepted, worker.submitReadFile(3, "b", false));

    worker.should_stop.store(true, .release);
    const io = mainThreadIo();

    // The app was told the host had taken this screenshot, so the write is
    // still handed out to be done. Nothing else is.
    const flushed = worker.awaitRequest(io) orelse return error.WriteWasAbandoned;
    try std.testing.expectEqual(EffectWorker.Kind.write_png, flushed.kind);
    try std.testing.expectEqual(@as(u64, 2), flushed.ticket);
    try std.testing.expectEqual(@as(?EffectWorker.Request, null), worker.awaitRequest(io));

    // A read owns no memory of its own, so abandoning it leaks nothing; the
    // write's pixels belong to whoever runs it, which here is this test.
    std.testing.allocator.free(flushed.pixels);
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
    try std.testing.expectEqual(@as(u64, 7), result.ticket);
    try std.testing.expectEqual(@as(u8, 0), result.err);
    try std.testing.expectEqualStrings(payload, result.bytes.?);
}

test "worker byte-list terminal results release their delivery reservations" {
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    effect_worker = .{ .allocator = std.testing.allocator, .accepting = true };
    defer {
        effect_worker.stop();
        effect_worker = .{};
        file_bytes_delivery_reservations.clearAfterWorkStops();
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        file_bytes_heap.deinitAll();
    }

    // One successful worker result moves its buffer into a slot; a failed one
    // has no buffer. Both were admitted `ReadFile`s, so each has to return one
    // promised delivery slot when its terminal response is staged.
    try std.testing.expect(file_bytes_delivery_reservations.reserve());
    try std.testing.expect(file_bytes_delivery_reservations.reserve());
    const bytes = try std.testing.allocator.dupe(u8, "worker-owned byte-list bytes");
    effect_worker.results[0] = .{
        .kind = .read_file,
        .ticket = 1,
        .bytes = bytes,
        .deliver_bytes = true,
    };
    effect_worker.results[1] = .{
        .kind = .read_file,
        .ticket = 2,
        .err = READ_ERR_NOT_FOUND,
        .deliver_bytes = true,
    };
    effect_worker.result_write.store(2, .release);

    var staging = ResponseStaging{};
    stageWorkerResults(&staging, &roc_host);
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);
    try std.testing.expectEqual(@as(usize, 2), staging.count());
    try std.testing.expectEqual(@as(u8, 0), staging.items.items[0].raw.err);
    try std.testing.expectEqual(READ_ERR_NOT_FOUND, staging.items.items[1].raw.err);

    // Worker-ring refusal and the exhausted-headless-budget refusal take this
    // same terminal path after reserving but before a result can exist.
    try std.testing.expect(file_bytes_delivery_reservations.reserve());
    stageReservedReadError(&staging, &roc_host, 3, RESPONSE_FILE_READ, READ_ERR_BUSY);
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);
    try std.testing.expectEqual(READ_ERR_BUSY, staging.items.items[2].raw.err);

    staging.release(&roc_host);
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
}

test "worker shutdown clears abandoned byte-list delivery reservations" {
    effect_worker = .{ .allocator = std.testing.allocator, .accepting = true };
    defer {
        effect_worker.stop();
        effect_worker = .{};
        file_bytes_delivery_reservations.clearAfterWorkStops();
    }

    try std.testing.expect(file_bytes_delivery_reservations.reserve());
    try std.testing.expectEqual(
        EffectWorker.Submission.accepted,
        effect_worker.submitReadFile(1, "a read abandoned at shutdown", true),
    );
    try std.testing.expectEqual(@as(usize, 1), file_bytes_delivery_reservations.count);

    // This is the same order as `runNormalApp`: stopping first frees every
    // unreported result, then the next app lifetime is allowed to start fresh.
    effect_worker.stop();
    file_bytes_delivery_reservations.clearAfterWorkStops();
    try std.testing.expectEqual(@as(usize, 0), file_bytes_delivery_reservations.count);
    beginPendingMappers();
}

test "a byte-list read is filled by the worker and installed by the frame thread" {
    // End to end across the thread boundary: the buffer Roc ends up with is
    // the one the worker allocated, and the frame thread only moves it through
    // the pending callback and the Roc response list.
    var roc_env = abi.RocEnv{ .allocator = std.testing.allocator, .roc_io = abi.RocIo.freestanding() };
    var roc_host = routingTestHost(&roc_env);
    defer {
        endPendingMappers(&roc_host);
        drainRetiredResourcesUpTo(std.math.maxInt(usize));
        file_bytes_heap.deinitAll();
    }
    resetPendingMappersForTest(&roc_host);
    beginPendingMappers();
    test_callback_drops = 0;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = "allocated off the frame thread and never copied onto it";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bytes.txt", .data = payload });

    var path_buffer: [capture.path_capacity]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, testing_tmp_prefix ++ "{s}/bytes.txt", .{tmp.sub_path});

    var worker = EffectWorker{};
    worker.start(std.testing.allocator);
    defer worker.stop();
    try std.testing.expectEqual(EffectWorker.Submission.accepted, worker.submitReadFile(11, path, true));

    const result = try awaitWorkerResult(&worker);
    try std.testing.expect(result.deliver_bytes);
    try std.testing.expectEqualStrings(payload, result.bytes.?);
    const worker_ptr = result.bytes.?.ptr;

    var staging = ResponseStaging{};
    try std.testing.expect(pending_mappers.insert(result.ticket, testCallback(&roc_host)));
    stageByteListRead(&staging, &roc_host, result.ticket, RESPONSE_FILE_READ, worker.allocator, result.bytes.?);
    try std.testing.expectEqual(@as(usize, 0), pending_mappers.count);
    try std.testing.expect(staging.items.items[0].deliver != null);

    const responses = staging.take(&roc_host);
    try std.testing.expectEqual(@as(usize, 0), staging.count());
    try std.testing.expectEqual(@as(usize, 1), responses.items().len);
    const delivered = stagedBytes(responses.items()[0].raw);

    // This is the List a callback retains in the app's model. Give it its own
    // ARC owner before Roc consumes the returned response envelope.
    delivered.incref(1);

    // This mirrors the platform adapter: it consumes every response envelope
    // and then its containing Roc list. The callback drops exactly once; the
    // model's retained List remains the sole file-byte owner.
    for (responses.allocationItems()) |item| item.decref(&roc_host);
    responses.decref(&roc_host);
    staging.release(&roc_host);

    // The retained model owner survives the full response transfer and still
    // reads the worker's allocation. The exhaustive alias/drop-order test above
    // covers sublists and Str conversions.
    try std.testing.expectEqual(@as(usize, 1), test_callback_drops);
    try std.testing.expectEqual(@as(usize, 1), file_bytes_heap.active());
    try std.testing.expectEqual(worker_ptr, delivered.elements_ptr.?);
    try std.testing.expect(delivered.isSeamlessSlice());
    try std.testing.expectEqualStrings(payload, delivered.items());

    delivered.decref(&roc_host);
    try std.testing.expectEqual(@as(usize, 1), file_bytes_heap.retiredCount());
    drainRetiredResourcesUpTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), file_bytes_heap.active());
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

    // Commands run inside the update call that produced them, so a nested scope
    // has to land back in update and not in idle -- otherwise the phase after
    // a command would be wrong for the rest of the call.
    const update = PhaseScope.enter(.apply);
    const nested = PhaseScope.enter(.render);
    try std.testing.expectEqual(Phase.render, active_phase);
    nested.leave();
    try std.testing.expectEqual(Phase.apply, active_phase);
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
    const phase = PhaseScope.enter(.apply);
    defer phase.leave();
    last_phase_violation = null;
    defer last_phase_violation = null;
    defer blend_scope_count = 0;

    _ = hostedDrawBeginBlendRaw(.{ .arg0 = 1 });

    const violation = last_phase_violation orelse return error.OperationWasNotRejected;
    try std.testing.expectEqualStrings("Draw.with_blend_mode!", violation.operation);
    try std.testing.expect(violation.allowed.eql(during_render));
    try std.testing.expectEqual(Phase.apply, violation.actual);
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

test "asking how big the drawing surface is is refused outside the frame" {
    // The answer is only defined while a surface is open, and admitting the
    // read anywhere else would make it a back door for `update` to observe the
    // window outside the input.
    last_phase_violation = null;
    defer last_phase_violation = null;

    for ([_]Phase{ .idle, .startup, .apply }) |phase| {
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

    for ([_]Phase{ .startup, .apply }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        enforcePhase("Mouse.set_cursor", during_apply);
        try std.testing.expectEqual(@as(?PhaseViolation, null), last_phase_violation);
    }

    // ...and rejected everywhere else, including the phase it is nearest to.
    for ([_]Phase{ .idle, .render }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        last_phase_violation = null;
        enforcePhase("Mouse.set_cursor", during_apply);
        const violation = last_phase_violation orelse return error.OperationWasNotRejected;
        try std.testing.expectEqual(phase, violation.actual);
    }
}

test "uploading pixels is refused from render, and taken while applying" {
    last_phase_violation = null;
    defer last_phase_violation = null;

    // An upload mutates a resource and may enter the graphics driver. It is
    // not drawing, and being allowed here is what let an app pay for a
    // full-texture upload in the middle of a frame it was already behind on.
    {
        const scope = PhaseScope.enter(.render);
        defer scope.leave();
        enforcePhase("Assets.update_texture!", during_apply);
        const violation = last_phase_violation orelse return error.UploadWasNotRejected;
        try std.testing.expectEqual(Phase.render, violation.actual);
    }

    // Startup and apply both have authority to upload. Neither path may turn a
    // structurally valid command into a capacity-based no-op.
    for ([_]Phase{ .startup, .apply }) |phase| {
        const scope = PhaseScope.enter(phase);
        defer scope.leave();
        last_phase_violation = null;
        enforcePhase("Assets.update_texture!", during_apply);
        try std.testing.expectEqual(@as(?PhaseViolation, null), last_phase_violation);
    }
}

test "window-size suggestions and frame-rate caps are taken while applying" {
    // Both of these used to be startup-only, so an app could neither resize
    // itself in response to its own layout nor drop its frame cap while
    // running. raylib resizes a live window and re-caps a running loop as
    // readily as it does before the first frame, so the restriction bought
    // nothing and cost two commands. Headless keeps the calls off raylib while
    // still exercising the guard and the size bookkeeping.
    last_phase_violation = null;
    defer last_phase_violation = null;
    const restore_width = headless_screen_width;
    const restore_height = headless_screen_height;
    defer headless_screen_width = restore_width;
    defer headless_screen_height = restore_height;

    for ([_]Phase{ .startup, .apply }) |phase| {
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
    try std.testing.expectEqualStrings("Window.set_target_fps", violation.operation);
    try std.testing.expect(violation.allowed.eql(during_apply));
}

test "a rejection names every phase the operation was allowed in" {
    var buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "init! or a command returned by update",
        describePhases(during_apply, &buffer),
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
/// Counters are plain integers, not atomics. Only the frame thread's allocator
/// is metered -- the effect worker keeps the unwrapped allocator it was started
/// with -- and this is a diagnostic, so a skewed count is the worst a stray
/// cross-thread allocation could cost.
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
    beginPendingMappers();
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

    // Only the windowed host runs a worker: headless executes every effect
    // inline so its output stays bit-identical run to run for CI. A stopped
    // worker cannot publish another result, so release callbacks immediately
    // afterwards and before capture/resource teardown touches their captures.
    effect_worker.start(allocator);
    defer {
        effect_worker.stop();
        file_bytes_delivery_reservations.clearAfterWorkStops();
        endPendingMappers(roc_host);
    }

    const init_result = initModel();
    if (init_result.isErr()) {
        const err_code = init_result.getErr();
        if (TRACE_HOST) std.log.debug("[HOST] init returned Err({d})", .{err_code});
        return initExitCode(err_code);
    }

    var boxed_model = init_result.getOk();
    var exit_code: i32 = 0;
    var cycle_count: u64 = 0;

    // Outlives the cycle: a request submitted at the end of one input answers in
    // the next, so its response waits here in between.
    var staging = ResponseStaging{};
    defer staging.release(roc_host);

    reportStartupAllocStats();
    while (!raylib.windowShouldClose()) {
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
        stageWorkerResults(&staging, roc_host);
        expireTimers(&staging, roc_host, real_ns);
        stageCaptureResults(&staging, roc_host);

        // One call, before the drawing scope opens. `update` is pure, so it
        // could not draw in any case; the platform applies its commands before
        // this returns, which is where the effects they replace used to run.
        const update_result = updateOnce(&boxed_model, .{
            .devices = input_snapshot,
            .window = windowState(),
            .time = .{
                .cycle_count = cycle_count,
                .simulation_nanos = now_ns,
                .monotonic_nanos = real_ns,
                .elapsed_seconds = frame_time,
            },
            .responses = staging.take(roc_host),
            .capture = captureStateForStep(),
        });
        if (update_result.tag == .Err) {
            exit_code = @intCast(update_result.payload_err());
            if (TRACE_HOST) std.log.debug("[HOST] update returned Err({d})", .{exit_code});
            break;
        }
        const next = update_result.payload_ok();
        boxed_model = next.model;
        submitRequests(&staging, roc_host, next.requests);

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
    beginPendingMappers();
    resetHeadlessRuntime(app_config);
    defer deinitResources();
    defer {
        // Headless reads finish inline, but keep the same lifetime cleanup as
        // the worker path so a failed or early-exiting run cannot poison the
        // next app lifetime.
        file_bytes_delivery_reservations.clearAfterWorkStops();
        endPendingMappers(roc_host);
    }

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
    var cycle_count: u64 = 0;

    // Outlives the cycle: a request submitted at the end of one input answers in
    // the next, so its response waits here in between.
    var staging = ResponseStaging{};
    defer staging.release(roc_host);

    reportStartupAllocStats();
    while (cycle_count < frames) : (cycle_count += 1) {
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
        stageWorkerResults(&staging, roc_host);
        expireTimers(&staging, roc_host, timestamp_nanos);
        stageCaptureResults(&staging, roc_host);

        // One call, before the drawing scope opens. `update` is pure, so it
        // could not draw in any case; the platform applies its commands before
        // this returns, which is where the effects they replace used to run.
        const update_result = updateOnce(&boxed_model, .{
            .devices = input_snapshot,
            .window = windowState(),
            .time = .{
                .cycle_count = cycle_count,
                .simulation_nanos = timestamp_nanos,
                .monotonic_nanos = timestamp_nanos,
                .elapsed_seconds = frame_time,
            },
            .responses = staging.take(roc_host),
            .capture = captureStateForStep(),
        });
        if (update_result.tag == .Err) {
            exit_code = @intCast(update_result.payload_err());
            if (TRACE_HOST) std.log.debug("[HOST] update returned Err({d})", .{exit_code});
            break;
        }
        const next = update_result.payload_ok();
        boxed_model = next.model;
        submitRequests(&staging, roc_host, next.requests);

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
    // allocator, so a normal run has no wrapper and no counters. The effect
    // worker keeps the unwrapped `allocator`, so only frame-thread traffic is
    // counted.
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

test "a submitted listing carries the response its answer belongs in" {
    var worker: EffectWorker = .{ .allocator = std.testing.allocator, .accepting = true };
    try std.testing.expectEqual(EffectWorker.Submission.accepted, worker.submitListDir(7, "src"));

    // The submission is what is under test here; the request is drained rather
    // than run, because running it needs the worker thread's own IO. What
    // matters is that it is queued as a byte-delivering operation whose answer
    // is routed to `DirListed` rather than to `FileRead`.
    const request = worker.takeRequest().?;
    try std.testing.expectEqual(EffectWorker.Kind.list_dir, request.kind);
    try std.testing.expectEqual(@as(u64, 7), request.ticket);
    try std.testing.expect(request.deliver_bytes);
    try std.testing.expectEqual(RESPONSE_DIR_LISTED, request.response);
}
