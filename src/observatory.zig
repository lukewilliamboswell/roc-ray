//! Bounded host-owned storage for Observatory events.
//!
//! The frame thread reserves a chunk, writes host-owned bytes into it, and
//! submits it to the recorder writer. The writer takes submitted chunks and
//! releases them after inserting their contents. No allocation occurs between
//! reservation and release.
//!
//! Detail is best-effort. It may only consume chunks above the summary reserve,
//! leaving known capacity for the low-volume cycle summaries. Every refused
//! admission is counted by family and can be drained as an explicit recording
//! gap. Summary refusal is counted too: reservation makes it less likely, but
//! cannot make an undrained bounded recorder unbounded.
const std = @import("std");
const builtin = @import("builtin");

/// Payload capacity of every preallocated recorder chunk.
pub const chunk_bytes: usize = 4096;

/// Event families have separate loss counts so a recording can say what was
/// omitted instead of presenting an incomplete interval as complete.
pub const Family = enum(u8) {
    cycle_summary,
    annotation,
    hosted_effect,
    task_lifecycle,
    allocation_lifecycle,
    resource_lifecycle,
    queue_pressure,
    draw_observation,
    structural_latency,
    backend_fact,
    callback_summary,
};

/// Number of independently accounted event families.
pub const family_count = @typeInfo(Family).@"enum".fields.len;

/// Admission class used to protect summary capacity from detail traffic.
pub const Priority = enum { summary, detail };

/// Fixed storage transferred from the frame thread to the writer.
pub const Chunk = struct {
    bytes: [chunk_bytes]u8 = undefined,
    len: usize = 0,
    family: Family = .cycle_summary,
    priority: Priority = .detail,

    pub fn slice(self: *Chunk) []u8 {
        return self.bytes[0..];
    }

    pub fn written(self: *const Chunk) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A producer-owned reservation. Its index is deliberately opaque to callers;
/// only `submit` or `cancel` returns ownership to the pool.
pub const Reservation = struct {
    index: usize,

    pub fn chunk(self: Reservation, pool: *Pool) *Chunk {
        return &pool.chunks[self.index];
    }
};

/// A writer-owned submitted chunk. The writer must call `release` exactly once.
pub const Submitted = struct {
    index: usize,

    pub fn chunk(self: Submitted, pool: *Pool) *const Chunk {
        return &pool.chunks[self.index];
    }
};

/// Refused admissions accumulated since the preceding snapshot.
pub const LossSnapshot = struct {
    counts: [family_count]u64 = [_]u64{0} ** family_count,
    first_cycles: [family_count]u64 = [_]u64{0} ** family_count,
    last_cycles: [family_count]u64 = [_]u64{0} ** family_count,
    started_ns: [family_count]u64 = [_]u64{0} ** family_count,
    ended_ns: [family_count]u64 = [_]u64{0} ** family_count,
    producers: [family_count]Producer = [_]Producer{.unknown} ** family_count,

    pub fn count(self: LossSnapshot, family: Family) u64 {
        return self.counts[@intFromEnum(family)];
    }

    pub fn total(self: LossSnapshot) u64 {
        var result: u64 = 0;
        for (self.counts) |n| result +|= n;
        return result;
    }
};

/// Host execution context that attempted to admit an event. This is recorder
/// attribution only; it never contains a Roc value or application payload.
pub const Producer = enum(u8) { unknown, frame_thread, host_worker, multiple };

const LossContext = struct {
    cycle: u64 = 0,
    timestamp_ns: u64 = 0,
    producer: Producer = .unknown,
};

/// Errors possible while allocating a bounded pool.
pub const InitError = error{ InvalidCapacity, OutOfMemory };

/// The producer and SQLite writer are ordinary OS threads, so the pool uses a
/// small runtime-independent lock rather than an `std.Io.Mutex` tied to an I/O
/// implementation. Critical sections only move indices and counters.
const Lock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(self: *Lock) void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Lock) void {
        self.held.store(false, .release);
    }
};

/// Preallocated producer-to-writer chunk pool.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    chunks: []Chunk,
    free: []usize,
    ready: []usize,
    free_len: usize,
    ready_head: usize = 0,
    ready_len: usize = 0,
    summary_reserve: usize,
    losses: [family_count]u64 = [_]u64{0} ** family_count,
    loss_first_cycles: [family_count]u64 = [_]u64{0} ** family_count,
    loss_last_cycles: [family_count]u64 = [_]u64{0} ** family_count,
    loss_started_ns: [family_count]u64 = [_]u64{0} ** family_count,
    loss_ended_ns: [family_count]u64 = [_]u64{0} ** family_count,
    loss_producers: [family_count]Producer = [_]Producer{.unknown} ** family_count,
    refused_total: u64 = 0,
    ready_high_water: usize = 0,
    mutex: Lock = .{},

    /// Allocate the complete recorder memory bound up front.
    pub fn init(allocator: std.mem.Allocator, capacity: usize, summary_reserve: usize) InitError!Pool {
        if (capacity == 0 or summary_reserve > capacity) return error.InvalidCapacity;
        const chunks = allocator.alloc(Chunk, capacity) catch return error.OutOfMemory;
        errdefer allocator.free(chunks);
        const free = allocator.alloc(usize, capacity) catch return error.OutOfMemory;
        errdefer allocator.free(free);
        const ready = allocator.alloc(usize, capacity) catch return error.OutOfMemory;
        for (free, 0..) |*slot, index| slot.* = index;
        return .{
            .allocator = allocator,
            .chunks = chunks,
            .free = free,
            .ready = ready,
            .free_len = capacity,
            .summary_reserve = summary_reserve,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.allocator.free(self.ready);
        self.allocator.free(self.free);
        self.allocator.free(self.chunks);
        self.* = undefined;
    }

    /// Reserve one chunk without waiting. Detail cannot consume the configured
    /// summary reserve. A refusal increments the requested family's loss count.
    pub fn reserve(self: *Pool, priority: Priority, family: Family) ?Reservation {
        return self.reserveAt(priority, family, .{});
    }

    fn reserveAt(self: *Pool, priority: Priority, family: Family, context: LossContext) ?Reservation {
        self.mutex.lock();
        defer self.mutex.unlock();

        const admitted = switch (priority) {
            .summary => self.free_len != 0,
            .detail => self.free_len > self.summary_reserve,
        };
        if (!admitted) {
            const index = @intFromEnum(family);
            const loss = &self.losses[index];
            if (loss.* == 0) {
                self.loss_first_cycles[index] = context.cycle;
                self.loss_started_ns[index] = context.timestamp_ns;
                self.loss_producers[index] = context.producer;
            } else if (self.loss_producers[index] != context.producer) {
                self.loss_producers[index] = .multiple;
            }
            self.loss_last_cycles[index] = context.cycle;
            self.loss_ended_ns[index] = context.timestamp_ns;
            loss.* +|= 1;
            self.refused_total +|= 1;
            return null;
        }

        self.free_len -= 1;
        const index = self.free[self.free_len];
        self.chunks[index].len = 0;
        self.chunks[index].family = family;
        self.chunks[index].priority = priority;
        return .{ .index = index };
    }

    /// Publish a filled reservation to the writer queue. `len` is validated
    /// before ownership changes, making an oversized internal event a bug.
    pub fn submit(self: *Pool, reservation: Reservation, len: usize) void {
        std.debug.assert(len <= chunk_bytes);
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.ready_len < self.ready.len);
        self.chunks[reservation.index].len = len;
        const tail = (self.ready_head + self.ready_len) % self.ready.len;
        self.ready[tail] = reservation.index;
        self.ready_len += 1;
        self.ready_high_water = @max(self.ready_high_water, self.ready_len);
    }

    /// Append one encoded event to the newest queued chunk when possible.
    /// Events are length-prefixed so a 4 KiB chunk carries many ordinary
    /// records instead of reserving 4 KiB for every small event.
    fn appendEncoded(self: *Pool, priority: Priority, family: Family, bytes: []const u8, context: LossContext) bool {
        std.debug.assert(bytes.len + 2 <= chunk_bytes);
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.ready_len != 0) {
            const tail = (self.ready_head + self.ready_len - 1) % self.ready.len;
            const index = self.ready[tail];
            const chunk = &self.chunks[index];
            if (chunk.priority == priority and chunk.len + 2 + bytes.len <= chunk_bytes) {
                std.mem.writeInt(u16, chunk.bytes[chunk.len..][0..2], @intCast(bytes.len), .little);
                @memcpy(chunk.bytes[chunk.len + 2 ..][0..bytes.len], bytes);
                chunk.len += 2 + bytes.len;
                return true;
            }
        }

        const admitted = switch (priority) {
            .summary => self.free_len != 0,
            .detail => self.free_len > self.summary_reserve,
        };
        if (!admitted) {
            self.noteLossLocked(family, 1, context);
            return false;
        }
        self.free_len -= 1;
        const index = self.free[self.free_len];
        const chunk = &self.chunks[index];
        chunk.family = family;
        chunk.priority = priority;
        std.mem.writeInt(u16, chunk.bytes[0..2], @intCast(bytes.len), .little);
        @memcpy(chunk.bytes[2..][0..bytes.len], bytes);
        chunk.len = 2 + bytes.len;
        const tail = (self.ready_head + self.ready_len) % self.ready.len;
        self.ready[tail] = index;
        self.ready_len += 1;
        self.ready_high_water = @max(self.ready_high_water, self.ready_len);
        return true;
    }

    /// Abandon a reservation that could not be encoded. This is not a
    /// saturation loss: no event was admitted, so the caller decides whether
    /// it represents a programmer error or should be counted separately.
    pub fn cancel(self: *Pool, reservation: Reservation) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.free_len < self.free.len);
        self.free[self.free_len] = reservation.index;
        self.free_len += 1;
    }

    /// Take the oldest submitted chunk without waiting.
    pub fn take(self: *Pool) ?Submitted {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.ready_len == 0) return null;
        const index = self.ready[self.ready_head];
        self.ready_head = (self.ready_head + 1) % self.ready.len;
        self.ready_len -= 1;
        return .{ .index = index };
    }

    /// Return one writer-owned chunk to producer capacity.
    pub fn release(self: *Pool, submitted: Submitted) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.free_len < self.free.len);
        self.free[self.free_len] = submitted.index;
        self.free_len += 1;
    }

    /// Atomically take and clear loss counts for one explicit gap row.
    pub fn takeLosses(self: *Pool) LossSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const snapshot = LossSnapshot{
            .counts = self.losses,
            .first_cycles = self.loss_first_cycles,
            .last_cycles = self.loss_last_cycles,
            .started_ns = self.loss_started_ns,
            .ended_ns = self.loss_ended_ns,
            .producers = self.loss_producers,
        };
        self.losses = [_]u64{0} ** family_count;
        self.loss_first_cycles = [_]u64{0} ** family_count;
        self.loss_last_cycles = [_]u64{0} ** family_count;
        self.loss_started_ns = [_]u64{0} ** family_count;
        self.loss_ended_ns = [_]u64{0} ** family_count;
        self.loss_producers = [_]Producer{.unknown} ** family_count;
        return snapshot;
    }

    pub fn available(self: *Pool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.free_len;
    }

    pub fn queued(self: *Pool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.ready_len;
    }

    /// Peak number of submitted chunks awaiting the writer.
    pub fn queueHighWater(self: *Pool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.ready_high_water;
    }

    /// Total refused events, including counts already emitted as gap rows.
    pub fn refusedTotal(self: *Pool) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.refused_total;
    }

    fn noteLoss(self: *Pool, family: Family, count: u64, context: LossContext) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.noteLossLocked(family, count, context);
    }

    fn noteLossLocked(self: *Pool, family: Family, count: u64, context: LossContext) void {
        const index = @intFromEnum(family);
        if (self.losses[index] == 0) {
            self.loss_first_cycles[index] = context.cycle;
            self.loss_started_ns[index] = context.timestamp_ns;
            self.loss_producers[index] = context.producer;
        } else if (self.loss_producers[index] != context.producer) {
            self.loss_producers[index] = .multiple;
        }
        self.loss_last_cycles[index] = context.cycle;
        self.loss_ended_ns[index] = context.timestamp_ns;
        self.losses[index] +|= count;
        self.refused_total +|= count;
    }
};

const SQLITE_OK = 0;
const SQLITE_DONE = 101;

extern fn rocray_sqlite_init() c_int;
extern fn rocray_sqlite_sleep(milliseconds: c_int) c_int;
extern fn rocray_sqlite_wall_time_ms() i64;
extern fn rocray_sqlite_open(path: [*:0]const u8, mode: c_int, busy_timeout_ms: c_int, out_db: *?*anyopaque) c_int;
extern fn rocray_sqlite_close(db: ?*anyopaque) c_int;
extern fn rocray_sqlite_prepare(db: ?*anyopaque, sql: [*:0]const u8, out_stmt: *?*anyopaque, out_tail_used: *c_int) c_int;
extern fn rocray_sqlite_finalize(stmt: ?*anyopaque) c_int;
extern fn rocray_sqlite_reset(stmt: ?*anyopaque) c_int;
extern fn rocray_sqlite_clear_bindings(stmt: ?*anyopaque) c_int;
extern fn rocray_sqlite_bind_int64(stmt: ?*anyopaque, index: c_int, value: i64) c_int;
extern fn rocray_sqlite_bind_double(stmt: ?*anyopaque, index: c_int, value: f64) c_int;
extern fn rocray_sqlite_bind_null(stmt: ?*anyopaque, index: c_int) c_int;
extern fn rocray_sqlite_bind_text(stmt: ?*anyopaque, index: c_int, bytes: [*]const u8, len: i64) c_int;
extern fn rocray_sqlite_step(stmt: ?*anyopaque) c_int;
extern fn rocray_sqlite_column_int64(stmt: ?*anyopaque, index: c_int) i64;
extern fn rocray_sqlite_exec(db: ?*anyopaque, sql: [*:0]const u8) c_int;
extern fn rocray_sqlite_storage_size(db: ?*anyopaque) i64;

/// Version of the SQLite schema created by this recorder.
pub const schema_version: u32 = 11;

/// Low-volume timing and allocation facts recorded for every admitted cycle.
pub const CycleSummary = struct {
    cycle: u64,
    start_ns: u64,
    duration_ns: u64,
    update_ns: u64,
    /// Time inside the application's render callback. This excludes backend
    /// submission, presentation, and pacing.
    render_callback_ns: u64,
    /// Wall time inside executor pumps. This may include event-loop polling or
    /// deliberate headless pacing and is not synonymous with Roc task work.
    task_executor_ns: u64,
    /// Cycle wall time outside update!, render!, and executor pumps.
    host_other_ns: u64,
    alloc_bytes: u64 = 0,
    alloc_calls: u64 = 0,
    free_bytes: u64 = 0,
    free_calls: u64 = 0,
    live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,
    update_alloc_bytes: u64 = 0,
    update_alloc_calls: u64 = 0,
    task_events: u64 = 0,
    effect_calls: u64 = 0,
    draw_calls: u64 = 0,
    resource_events: u64 = 0,
    queue_events: u64 = 0,
};

/// Version-one application annotation operations.
pub const AnnotationKind = enum(u8) { mark, zone_begin, zone_end, sample_i64, sample_f64, zone_abort };

/// One application annotation after its label has been copied into host memory.
pub const Annotation = struct {
    cycle: u64,
    timestamp_ns: u64,
    phase: u8,
    kind: AnnotationKind,
    name: []const u8,
    integer: i64 = 0,
    real: f64 = 0,
    unit: u8 = 0,
    wall_ns: u64 = 0,
    active_ns: u64 = 0,
    parked_ns: u64 = 0,
};

/// Privacy-preserving detail shared by lifecycle and pressure event families.
/// Identifiers are recorder-private; `name` is a bounded class name, never a
/// payload, pointer, path, input value, or task message.
pub const DetailEvent = struct {
    cycle: u64,
    timestamp_ns: u64,
    kind: u8,
    subject_id: u64 = 0,
    parent_id: u64 = 0,
    duration_ns: u64 = 0,
    value_a: u64 = 0,
    value_b: u64 = 0,
    name: []const u8 = "",
    producer: Producer = .frame_thread,
};

/// Task lifecycle, turn, wait, cancellation, and delivery facts.
pub const TaskEvent = DetailEvent;
/// Hosted-effect timing, phase, copy-size, and outcome facts.
pub const EffectEvent = struct {
    cycle: u64,
    timestamp_ns: u64,
    kind: u8,
    effect_id: u64,
    correlation_id: u64,
    duration_ns: u64,
    outcome: EffectOutcome,
    inbound_copied_bytes: u64 = 0,
    outbound_copied_bytes: u64 = 0,
    ownership_transfer_bytes: u64 = 0,
    validation_ns: ?u64 = null,
    conversion_ns: ?u64 = null,
    worker_ns: ?u64 = null,
    external_ns: ?u64 = null,
    name: []const u8,
    producer: Producer = .frame_thread,
};
/// Stable `EffectEvent.kind` phase values stored by schema version 2.
pub const EffectPhase = enum(u8) { init = 1, update = 2, render = 3, task = 4 };
/// Stable effect result categories stored in `EffectEvent.value_b`.
pub const EffectOutcome = enum(u8) { success = 0, runtime_error = 1, refused = 2, cancelled = 3 };
/// Bounded queue occupancy, capacity, age, and saturation facts.
pub const QueueEvent = DetailEvent;
/// Typed resource creation, retirement, destruction, and reuse facts.
pub const ResourceEvent = DetailEvent;
/// Structural input and task-message latency facts without payload contents.
pub const LatencyEvent = DetailEvent;
/// Draw batch, instance, primitive, upload, and state-change summaries.
pub const DrawEvent = DetailEvent;
/// Allocation, reallocation, move, and deallocation lifecycle facts.
pub const AllocationEvent = DetailEvent;
/// Backend, presentation, pacing, or honestly available GPU fact.
pub const GpuEvent = DetailEvent;
/// Automatic application callback timing with an explicit callback phase.
pub const CallbackEvent = DetailEvent;
/// Stable `CallbackEvent.kind` phase values.
pub const CallbackPhase = enum(u8) { init = 0, update = 1, render = 2, task_turn = 3 };
/// Stable `CallbackEvent.value_a` outcome values.
pub const CallbackOutcome = enum(u8) { success = 0, application_error = 1, cancelled = 2 };

/// Requested and effective recording detail stored in capture metadata.
pub const Detail = enum(u8) { summary, standard, full };

const TestFault = enum { none, block_after_start, abrupt_after_first_commit, fail_after_first_commit, unresolved_relationship };

/// Startup policy and explicit recorder resource bounds.
pub const SessionOptions = struct {
    path: []const u8,
    chunk_count: usize = 256,
    summary_reserve: usize = 8,
    max_output_bytes: u64 = 256 * 1024 * 1024,
    transaction_chunks: usize = 64,
    /// Operator-requested detail. `effective_detail` may honestly downgrade it.
    detail: Detail = .standard,
    /// Highest detail the selected host can actually emit.
    effective_detail: ?Detail = null,
    rocray_version: []const u8 = "unavailable",
    roc_compiler_pin: []const u8 = "unavailable",
    target_profile: []const u8 = "unavailable",
    backend: []const u8 = "unavailable",
    executable_name: []const u8 = "unavailable",
    app_name: []const u8 = "unavailable",
    /// Monotonic clock used for every host timestamp in this recording.
    clock_source: []const u8 = "std.Io.Clock.awake",
    /// Best resolution reported by the host clock, in nanoseconds. Zero means
    /// the platform could not report a resolution honestly.
    clock_resolution_ns: u64 = 0,
    /// UTC correlation captured when recorder startup began. Durations never
    /// use this wall clock.
    utc_origin_unix_ns: u64 = 0,
    /// Comma-separated measurements the host cannot honestly provide.
    unavailable_sources: []const u8 = "gpu_timing,zio_worker_queue_timing,writer_thread_cpu_time",
    /// Benchmark-only delay injected before each writer transaction. Ordinary
    /// host startup leaves this zero.
    benchmark_writer_delay_ms: u32 = 0,
    test_fault: TestFault = .none,
};

/// Failures reported synchronously before application startup continues.
pub const StartError = error{ InvalidCapacity, OutOfMemory, PathTooLong, ThreadStartFailed, SqliteUnavailable, AlreadyExists, OpenFailed, SchemaFailed };

const EventKind = enum(u8) { cycle, annotation, gap, detail };
const DetailFamily = enum(u8) { task, effect, queue, resource, latency, draw, allocation, gpu, callback };

const Shared = struct {
    allocator: std.mem.Allocator,
    pool: Pool,
    path: [:0]u8,
    max_output_bytes: u64,
    transaction_chunks: usize,
    requested_detail: Detail,
    effective_detail: Detail,
    rocray_version: []const u8,
    roc_compiler_pin: []const u8,
    target_profile: []const u8,
    backend: []const u8,
    executable_name: []const u8,
    app_name: []const u8,
    clock_source: []const u8 = "std.Io.Clock.awake",
    clock_resolution_ns: u64 = 0,
    utc_origin_unix_ns: u64 = 0,
    unavailable_sources: []const u8,
    benchmark_writer_delay_ms: u32 = 0,
    stop: std.atomic.Value(bool) = .init(false),
    accepting: std.atomic.Value(bool) = .init(true),
    startup: std.atomic.Value(u8) = .init(0), // 0 pending, 1 ready, 2 failed
    startup_error: StartError = error.OpenFailed,
    output_limited: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    finalized: std.atomic.Value(bool) = .init(false),
    rows_written: std.atomic.Value(u64) = .init(0),
    last_producer_cycle: std.atomic.Value(u64) = .init(0),
    last_producer_timestamp_ns: std.atomic.Value(u64) = .init(0),
    transactions: std.atomic.Value(u64) = .init(0),
    checkpoints: std.atomic.Value(u64) = .init(0),
    writer_active_wall_ns: u64 = 0,
    writer_idle_wall_ns: u64 = 0,
    shutdown_started_ms: std.atomic.Value(u64) = .init(0),
    drain_duration_ns: u64 = 0,
    application_outcome: []const u8 = "host_returned",
    test_writer_gate: std.atomic.Value(bool) = .init(false),
    test_fault: TestFault,
};

/// An active capture. The frame thread only appends to its bounded pool; the
/// dedicated writer owns the SQLite connection for its entire lifetime.
pub const Session = struct {
    shared: *Shared,
    thread: std.Thread,

    pub fn start(allocator: std.mem.Allocator, options: SessionOptions) StartError!Session {
        if (options.transaction_chunks == 0) return error.InvalidCapacity;
        const shared = allocator.create(Shared) catch return error.OutOfMemory;
        errdefer allocator.destroy(shared);
        var pool = Pool.init(allocator, options.chunk_count, options.summary_reserve) catch |err| return switch (err) {
            error.InvalidCapacity => error.InvalidCapacity,
            error.OutOfMemory => error.OutOfMemory,
        };
        errdefer pool.deinit();
        const path = allocator.dupeZ(u8, options.path) catch return error.OutOfMemory;
        errdefer allocator.free(path);
        shared.* = .{
            .allocator = allocator,
            .pool = pool,
            .path = path,
            .max_output_bytes = options.max_output_bytes,
            .transaction_chunks = options.transaction_chunks,
            .requested_detail = options.detail,
            .effective_detail = options.effective_detail orelse options.detail,
            .rocray_version = options.rocray_version,
            .roc_compiler_pin = options.roc_compiler_pin,
            .target_profile = options.target_profile,
            .backend = options.backend,
            .executable_name = options.executable_name,
            .app_name = options.app_name,
            .clock_source = options.clock_source,
            .clock_resolution_ns = options.clock_resolution_ns,
            .utc_origin_unix_ns = options.utc_origin_unix_ns,
            .unavailable_sources = options.unavailable_sources,
            .benchmark_writer_delay_ms = options.benchmark_writer_delay_ms,
            .test_fault = options.test_fault,
        };
        const thread = std.Thread.spawn(.{}, writerMain, .{shared}) catch return error.ThreadStartFailed;
        while (shared.startup.load(.acquire) == 0) std.Thread.yield() catch std.atomic.spinLoopHint();
        if (shared.startup.load(.acquire) == 2) {
            thread.join();
            return shared.startup_error;
        }
        return .{ .shared = shared, .thread = thread };
    }

    pub fn recordCycle(self: *Session, value: CycleSummary) bool {
        self.noteProducerPosition(value.cycle, value.start_ns +| value.duration_ns);
        if (!self.shared.accepting.load(.acquire)) return false;
        var encoded: [chunk_bytes - 2]u8 = undefined;
        const out = encoded[0..];
        out[0] = @intFromEnum(EventKind.cycle);
        var at: usize = 1;
        inline for (.{ value.cycle, value.start_ns, value.duration_ns, value.update_ns, value.render_callback_ns, value.task_executor_ns, value.host_other_ns, value.alloc_bytes, value.alloc_calls, value.free_bytes, value.free_calls, value.live_bytes, value.peak_live_bytes, value.update_alloc_bytes, value.update_alloc_calls, value.task_events, value.effect_calls, value.draw_calls, value.resource_events, value.queue_events }) |field| {
            std.mem.writeInt(u64, out[at..][0..8], field, .little);
            at += 8;
        }
        return self.shared.pool.appendEncoded(.summary, .cycle_summary, out[0..at], .{
            .cycle = value.cycle,
            .timestamp_ns = value.start_ns +| value.duration_ns,
            .producer = .frame_thread,
        });
    }

    pub fn recordAnnotation(self: *Session, value: Annotation) bool {
        self.noteProducerPosition(value.cycle, value.timestamp_ns);
        if (!self.shared.accepting.load(.acquire)) return false;
        var encoded: [chunk_bytes - 2]u8 = undefined;
        const out = encoded[0..];
        const kept = @min(value.name.len, encoded.len - 62);
        out[0] = @intFromEnum(EventKind.annotation);
        std.mem.writeInt(u64, out[1..9], value.cycle, .little);
        std.mem.writeInt(u64, out[9..17], value.timestamp_ns, .little);
        out[17] = value.phase;
        out[18] = @intFromEnum(value.kind);
        out[19] = value.unit;
        std.mem.writeInt(i64, out[20..28], value.integer, .little);
        std.mem.writeInt(u16, out[28..30], @intCast(kept), .little);
        @memcpy(out[30 .. 30 + kept], value.name[0..kept]);
        // Preserve the f64 bit pattern without alignment assumptions.
        std.mem.writeInt(u64, out[30 + kept ..][0..8], @bitCast(value.real), .little);
        var durations_at = 38 + kept;
        inline for (.{ value.wall_ns, value.active_ns, value.parked_ns }) |duration| {
            std.mem.writeInt(u64, out[durations_at..][0..8], duration, .little);
            durations_at += 8;
        }
        return self.shared.pool.appendEncoded(.detail, .annotation, out[0..durations_at], .{
            .cycle = value.cycle,
            .timestamp_ns = value.timestamp_ns,
            .producer = .frame_thread,
        });
    }

    fn recordDetail(self: *Session, family: DetailFamily, loss_family: Family, value: DetailEvent) bool {
        return self.recordDetailWithPriority(family, loss_family, .detail, value);
    }

    fn recordDetailWithPriority(self: *Session, family: DetailFamily, loss_family: Family, priority: Priority, value: DetailEvent) bool {
        self.noteProducerPosition(value.cycle, value.timestamp_ns);
        if (!self.shared.accepting.load(.acquire)) return false;
        if (!detailAdmits(self.shared.effective_detail, family)) return false;
        var encoded: [chunk_bytes - 2]u8 = undefined;
        const out = encoded[0..];
        const kept = @min(value.name.len, encoded.len - 61);
        out[0] = @intFromEnum(EventKind.detail);
        out[1] = @intFromEnum(family);
        out[2] = value.kind;
        var at: usize = 3;
        inline for (.{ value.cycle, value.timestamp_ns, value.subject_id, value.parent_id, value.duration_ns, value.value_a, value.value_b }) |field| {
            std.mem.writeInt(u64, out[at..][0..8], field, .little);
            at += 8;
        }
        std.mem.writeInt(u16, out[at..][0..2], @intCast(kept), .little);
        at += 2;
        @memcpy(out[at .. at + kept], value.name[0..kept]);
        return self.shared.pool.appendEncoded(priority, loss_family, out[0 .. at + kept], .{
            .cycle = value.cycle,
            .timestamp_ns = value.timestamp_ns,
            .producer = value.producer,
        });
    }

    pub fn recordTask(self: *Session, value: TaskEvent) bool {
        return self.recordDetail(.task, .task_lifecycle, value);
    }
    pub fn recordEffect(self: *Session, value: EffectEvent) bool {
        if (!self.shared.accepting.load(.acquire) or self.shared.effective_detail == .summary) return false;
        self.noteProducerPosition(value.cycle, value.timestamp_ns);
        var encoded: [chunk_bytes - 2]u8 = undefined;
        const out = encoded[0..];
        const kept = @min(value.name.len, encoded.len - 117);
        out[0] = @intFromEnum(EventKind.detail);
        out[1] = @intFromEnum(DetailFamily.effect);
        out[2] = value.kind;
        var at: usize = 3;
        inline for (.{ value.cycle, value.timestamp_ns, value.effect_id, value.correlation_id, value.duration_ns, value.inbound_copied_bytes, @intFromEnum(value.outcome) }) |field| {
            std.mem.writeInt(u64, out[at..][0..8], field, .little);
            at += 8;
        }
        std.mem.writeInt(u16, out[at..][0..2], @intCast(kept), .little);
        at += 2;
        @memcpy(out[at .. at + kept], value.name[0..kept]);
        at += kept;
        var mask: u64 = 0;
        inline for (.{ value.validation_ns, value.conversion_ns, value.worker_ns, value.external_ns }, 0..) |interval, bit| if (interval != null) {
            mask |= @as(u64, 1) << bit;
        };
        inline for (.{ value.outbound_copied_bytes, value.ownership_transfer_bytes, value.validation_ns orelse 0, value.conversion_ns orelse 0, value.worker_ns orelse 0, value.external_ns orelse 0, mask }) |field| {
            std.mem.writeInt(u64, out[at..][0..8], field, .little);
            at += 8;
        }
        return self.shared.pool.appendEncoded(.detail, .hosted_effect, out[0..at], .{
            .cycle = value.cycle,
            .timestamp_ns = value.timestamp_ns,
            .producer = value.producer,
        });
    }
    pub fn recordQueue(self: *Session, value: QueueEvent) bool {
        return self.recordDetail(.queue, .queue_pressure, value);
    }
    pub fn recordResource(self: *Session, value: ResourceEvent) bool {
        return self.recordDetail(.resource, .resource_lifecycle, value);
    }
    pub fn recordLatency(self: *Session, value: LatencyEvent) bool {
        return self.recordDetail(.latency, .structural_latency, value);
    }
    pub fn recordDraw(self: *Session, value: DrawEvent) bool {
        return self.recordDetail(.draw, .draw_observation, value);
    }
    pub fn recordAllocation(self: *Session, value: AllocationEvent) bool {
        return self.recordDetail(.allocation, .allocation_lifecycle, value);
    }
    pub fn recordGpu(self: *Session, value: GpuEvent) bool {
        return self.recordDetail(.gpu, .backend_fact, value);
    }

    /// Record one automatic callback interval. It contains timing and outcome
    /// only; the opaque model and callback result payload never cross here.
    pub fn recordCallback(self: *Session, value: CallbackEvent) bool {
        return self.recordDetailWithPriority(.callback, .callback_summary, .summary, value);
    }

    /// Account for detail omitted before it could reserve an event chunk.
    pub fn noteLoss(self: *Session, family: Family, count: u64) void {
        self.shared.pool.noteLoss(family, count, .{
            .cycle = self.shared.last_producer_cycle.load(.monotonic),
            .timestamp_ns = self.shared.last_producer_timestamp_ns.load(.monotonic),
            .producer = .frame_thread,
        });
    }

    fn noteProducerPosition(self: *Session, cycle: u64, timestamp_ns: u64) void {
        self.shared.last_producer_cycle.store(cycle, .monotonic);
        self.shared.last_producer_timestamp_ns.store(timestamp_ns, .monotonic);
    }

    /// Convert accumulated refusal counts into reserved, explicit gap events.
    /// If even summary capacity is exhausted, counts are restored for retry.
    pub fn flushGaps(self: *Session, cycle: u64, timestamp_ns: u64) bool {
        const losses = self.shared.pool.takeLosses();
        if (losses.total() == 0) return true;
        var all_written = true;
        for (losses.counts, 0..) |lost, family_index| {
            if (lost == 0) continue;
            var encoded: [59]u8 = undefined;
            const out = encoded[0..];
            out[0] = @intFromEnum(EventKind.gap);
            std.mem.writeInt(u64, out[1..9], losses.last_cycles[family_index], .little);
            std.mem.writeInt(u64, out[9..17], losses.ended_ns[family_index], .little);
            out[17] = @intCast(family_index);
            std.mem.writeInt(u64, out[18..26], lost, .little);
            std.mem.writeInt(u64, out[26..34], losses.first_cycles[family_index], .little);
            std.mem.writeInt(u64, out[34..42], losses.last_cycles[family_index], .little);
            std.mem.writeInt(u64, out[42..50], losses.started_ns[family_index], .little);
            std.mem.writeInt(u64, out[50..58], losses.ended_ns[family_index], .little);
            out[58] = @intFromEnum(losses.producers[family_index]);
            if (!self.shared.pool.appendEncoded(.summary, @enumFromInt(family_index), out, .{
                .cycle = cycle,
                .timestamp_ns = timestamp_ns,
                .producer = .frame_thread,
            })) {
                restoreLoss(&self.shared.pool, @enumFromInt(family_index), losses, family_index);
                all_written = false;
            }
        }
        return all_written;
    }

    pub fn outputLimited(self: *const Session) bool {
        return self.shared.output_limited.load(.acquire);
    }

    /// Whether a storage error ended recording after successful startup.
    pub fn failed(self: *const Session) bool {
        return self.shared.failed.load(.acquire);
    }

    fn releaseTestWriter(self: *Session) void {
        self.shared.test_writer_gate.store(true, .release);
    }

    /// Terminal facts returned after every admitted chunk has been released.
    pub const StopReport = struct {
        complete: bool,
        failed: bool,
        output_limited: bool,
        drain_duration_ns: u64,
        omitted_events: u64,
    };

    /// Name the host-owned application outcome persisted at finalization.
    pub fn setApplicationOutcome(self: *Session, outcome: []const u8) void {
        self.shared.application_outcome = outcome;
    }

    pub fn stop(self: *Session) StopReport {
        // Shutdown may wait for the bounded writer, so use that opportunity to
        // turn tail loss into explicit rows instead of stranding it in memory.
        const tail_cycle = self.shared.last_producer_cycle.load(.acquire);
        const tail_timestamp_ns = self.shared.last_producer_timestamp_ns.load(.acquire);
        while (!self.flushGaps(tail_cycle, tail_timestamp_ns)) {
            if (!self.shared.accepting.load(.acquire)) break;
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        self.shared.shutdown_started_ms.store(recorderWallTimeMs(), .release);
        self.shared.accepting.store(false, .release);
        self.shared.stop.store(true, .release);
        self.thread.join();
        const report = StopReport{
            .complete = self.shared.finalized.load(.acquire) and !self.shared.failed.load(.acquire) and !self.shared.output_limited.load(.acquire),
            .failed = self.shared.failed.load(.acquire),
            .output_limited = self.shared.output_limited.load(.acquire),
            .drain_duration_ns = self.shared.drain_duration_ns,
            .omitted_events = self.shared.pool.refusedTotal(),
        };
        const allocator = self.shared.allocator;
        allocator.free(self.shared.path);
        self.shared.pool.deinit();
        allocator.destroy(self.shared);
        self.* = undefined;
        return report;
    }
};

fn detailAdmits(detail: Detail, family: DetailFamily) bool {
    return switch (family) {
        .callback, .draw, .gpu => true,
        .allocation => detail == .full,
        .task, .effect, .queue, .resource, .latency => detail != .summary,
    };
}

test "summary standard and full have explicit family admission" {
    inline for (.{ DetailFamily.task, .effect, .queue, .resource, .latency }) |family| {
        try std.testing.expect(!detailAdmits(.summary, family));
        try std.testing.expect(detailAdmits(.standard, family));
        try std.testing.expect(detailAdmits(.full, family));
    }
    try std.testing.expect(!detailAdmits(.summary, .allocation));
    try std.testing.expect(!detailAdmits(.standard, .allocation));
    try std.testing.expect(detailAdmits(.full, .allocation));
    try std.testing.expect(detailAdmits(.summary, .callback));
    try std.testing.expect(detailAdmits(.summary, .draw));
    try std.testing.expect(detailAdmits(.summary, .gpu));
    try std.testing.expect(detailAdmits(.standard, .callback));
    try std.testing.expect(detailAdmits(.full, .callback));
}

fn restoreLoss(self: *Pool, family: Family, snapshot: LossSnapshot, snapshot_index: usize) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    const index = @intFromEnum(family);
    const current_count = self.losses[index];
    const current_last_cycle = self.loss_last_cycles[index];
    const current_ended_ns = self.loss_ended_ns[index];
    const current_producer = self.loss_producers[index];
    self.losses[index] +|= snapshot.counts[snapshot_index];
    self.loss_first_cycles[index] = snapshot.first_cycles[snapshot_index];
    self.loss_started_ns[index] = snapshot.started_ns[snapshot_index];
    if (current_count == 0) {
        self.loss_last_cycles[index] = snapshot.last_cycles[snapshot_index];
        self.loss_ended_ns[index] = snapshot.ended_ns[snapshot_index];
        self.loss_producers[index] = snapshot.producers[snapshot_index];
    } else {
        self.loss_last_cycles[index] = current_last_cycle;
        self.loss_ended_ns[index] = current_ended_ns;
        self.loss_producers[index] = if (current_producer == snapshot.producers[snapshot_index]) current_producer else .multiple;
    }
}

const schema_sql =
    \\PRAGMA foreign_keys=ON;
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA synchronous=NORMAL;
    \\CREATE TABLE runs(id INTEGER PRIMARY KEY CHECK(id=1));
    \\INSERT INTO runs VALUES(1);
    \\CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    \\CREATE TABLE measurement_status(name TEXT PRIMARY KEY, family INTEGER, required_detail TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('unfinalized','complete','partial','not_recorded','unavailable')), reason TEXT NOT NULL, rows_recorded INTEGER NOT NULL, omitted_events INTEGER NOT NULL);
    \\CREATE TABLE cycles(cycle INTEGER PRIMARY KEY, start_ns INTEGER NOT NULL, duration_ns INTEGER NOT NULL, update_ns INTEGER NOT NULL, render_callback_ns INTEGER NOT NULL, task_executor_ns INTEGER NOT NULL, host_other_ns INTEGER NOT NULL, alloc_bytes INTEGER NOT NULL, alloc_calls INTEGER NOT NULL, free_bytes INTEGER NOT NULL, free_calls INTEGER NOT NULL, live_bytes INTEGER NOT NULL, peak_live_bytes INTEGER NOT NULL, update_alloc_bytes INTEGER NOT NULL, update_alloc_calls INTEGER NOT NULL, task_events INTEGER NOT NULL, effect_calls INTEGER NOT NULL, draw_calls INTEGER NOT NULL, resource_events INTEGER NOT NULL, queue_events INTEGER NOT NULL, run_id INTEGER NOT NULL DEFAULT 1 REFERENCES runs(id));
    \\CREATE TABLE annotations(id INTEGER PRIMARY KEY, cycle INTEGER NOT NULL, timestamp_ns INTEGER NOT NULL, phase INTEGER NOT NULL, kind INTEGER NOT NULL, name TEXT NOT NULL, integer_value INTEGER, real_value REAL, unit INTEGER NOT NULL, wall_ns INTEGER NOT NULL, active_ns INTEGER NOT NULL, parked_ns INTEGER NOT NULL, run_id INTEGER NOT NULL DEFAULT 1 REFERENCES runs(id));
    \\CREATE TABLE recording_gaps(id INTEGER PRIMARY KEY, cycle INTEGER NOT NULL, timestamp_ns INTEGER NOT NULL, family INTEGER NOT NULL, lost_count INTEGER NOT NULL, first_cycle INTEGER NOT NULL, last_cycle INTEGER NOT NULL, started_ns INTEGER NOT NULL, ended_ns INTEGER NOT NULL, producer_track TEXT NOT NULL, run_id INTEGER NOT NULL DEFAULT 1 REFERENCES runs(id));
    \\CREATE TABLE recorder_health(id INTEGER PRIMARY KEY CHECK(id=1), transactions INTEGER NOT NULL, checkpoints INTEGER NOT NULL, queue_high_water INTEGER NOT NULL, output_bytes INTEGER NOT NULL, omitted_events INTEGER NOT NULL, rows_written INTEGER NOT NULL, writer_failed INTEGER NOT NULL, output_limited INTEGER NOT NULL, writer_active_wall_ns INTEGER NOT NULL, writer_idle_wall_ns INTEGER NOT NULL, writer_cpu_ns INTEGER);
    \\CREATE TABLE task_events(id INTEGER PRIMARY KEY, cycle INTEGER NOT NULL, timestamp_ns INTEGER NOT NULL, kind INTEGER NOT NULL, subject_id INTEGER NOT NULL, parent_id INTEGER NOT NULL, duration_ns INTEGER NOT NULL, value_a INTEGER NOT NULL, value_b INTEGER NOT NULL, name TEXT NOT NULL, run_id INTEGER NOT NULL DEFAULT 1 REFERENCES runs(id));
    \\CREATE TABLE hosted_effects(id INTEGER PRIMARY KEY, cycle INTEGER NOT NULL, timestamp_ns INTEGER NOT NULL, kind INTEGER NOT NULL, subject_id INTEGER NOT NULL, parent_id INTEGER NOT NULL, duration_ns INTEGER NOT NULL, value_a INTEGER NOT NULL, value_b INTEGER NOT NULL, name TEXT NOT NULL, outbound_copied_bytes INTEGER NOT NULL, ownership_transfer_bytes INTEGER NOT NULL, validation_ns INTEGER, conversion_ns INTEGER, worker_ns INTEGER, external_ns INTEGER, run_id INTEGER NOT NULL DEFAULT 1 REFERENCES runs(id));
    \\CREATE TABLE queue_pressure(id INTEGER PRIMARY KEY, cycle INTEGER NOT NULL, timestamp_ns INTEGER NOT NULL, kind INTEGER NOT NULL, subject_id INTEGER NOT NULL, parent_id INTEGER NOT NULL, duration_ns INTEGER NOT NULL, value_a INTEGER NOT NULL, value_b INTEGER NOT NULL, name TEXT NOT NULL, run_id INTEGER NOT NULL DEFAULT 1 REFERENCES runs(id));
    \\CREATE TABLE resource_lifecycle(id INTEGER PRIMARY KEY, cycle INTEGER NOT NULL, timestamp_ns INTEGER NOT NULL, kind INTEGER NOT NULL, subject_id INTEGER NOT NULL, parent_id INTEGER NOT NULL, duration_ns INTEGER NOT NULL, value_a INTEGER NOT NULL, value_b INTEGER NOT NULL, name TEXT NOT NULL, run_id INTEGER NOT NULL DEFAULT 1 REFERENCES runs(id));
    \\CREATE TABLE structural_latency(id INTEGER PRIMARY KEY, cycle INTEGER NOT NULL, timestamp_ns INTEGER NOT NULL, kind INTEGER NOT NULL, subject_id INTEGER NOT NULL, parent_id INTEGER NOT NULL, duration_ns INTEGER NOT NULL, value_a INTEGER NOT NULL, value_b INTEGER NOT NULL, name TEXT NOT NULL, run_id INTEGER NOT NULL DEFAULT 1 REFERENCES runs(id));
    \\CREATE TABLE draw_summaries(id INTEGER PRIMARY KEY, cycle INTEGER NOT NULL, timestamp_ns INTEGER NOT NULL, kind INTEGER NOT NULL, subject_id INTEGER NOT NULL, parent_id INTEGER NOT NULL, duration_ns INTEGER NOT NULL, value_a INTEGER NOT NULL, value_b INTEGER NOT NULL, name TEXT NOT NULL, run_id INTEGER NOT NULL DEFAULT 1 REFERENCES runs(id));
    \\CREATE TABLE allocation_events(id INTEGER PRIMARY KEY, cycle INTEGER NOT NULL, timestamp_ns INTEGER NOT NULL, kind INTEGER NOT NULL, subject_id INTEGER NOT NULL, parent_id INTEGER NOT NULL, duration_ns INTEGER NOT NULL, value_a INTEGER NOT NULL, value_b INTEGER NOT NULL, name TEXT NOT NULL, phase INTEGER NOT NULL, task_id INTEGER NOT NULL, zone_id INTEGER NOT NULL, bytes INTEGER NOT NULL, prior_bytes INTEGER NOT NULL, copied_bytes INTEGER NOT NULL, run_id INTEGER NOT NULL DEFAULT 1 REFERENCES runs(id));
    \\CREATE TABLE gpu_facts(id INTEGER PRIMARY KEY, cycle INTEGER NOT NULL, timestamp_ns INTEGER NOT NULL, kind INTEGER NOT NULL, subject_id INTEGER NOT NULL, parent_id INTEGER NOT NULL, duration_ns INTEGER NOT NULL, value_a INTEGER NOT NULL, value_b INTEGER NOT NULL, name TEXT NOT NULL, run_id INTEGER NOT NULL DEFAULT 1 REFERENCES runs(id));
    \\CREATE TABLE callback_summaries(id INTEGER PRIMARY KEY, cycle INTEGER NOT NULL, timestamp_ns INTEGER NOT NULL, phase INTEGER NOT NULL, subject_id INTEGER NOT NULL, parent_id INTEGER NOT NULL, duration_ns INTEGER NOT NULL, outcome INTEGER NOT NULL, reserved INTEGER NOT NULL, name TEXT NOT NULL, run_id INTEGER NOT NULL DEFAULT 1 REFERENCES runs(id));
    \\CREATE INDEX annotations_by_run_cycle_time ON annotations(run_id,cycle,timestamp_ns);
    \\CREATE INDEX gaps_by_run_cycle ON recording_gaps(run_id,first_cycle,last_cycle);
    \\CREATE INDEX cycles_by_run_duration ON cycles(run_id,duration_ns);
    \\CREATE INDEX task_events_by_run_cycle_time ON task_events(run_id,cycle,timestamp_ns);
    \\CREATE INDEX effects_by_run_cycle_time ON hosted_effects(run_id,cycle,timestamp_ns);
    \\CREATE INDEX resources_by_run_subject_time ON resource_lifecycle(run_id,subject_id,timestamp_ns);
    \\CREATE INDEX allocations_live_by_run_subject ON allocation_events(run_id,subject_id,kind);
    \\CREATE INDEX allocations_by_run_cycle_phase ON allocation_events(run_id,cycle,phase);
    \\INSERT INTO metadata VALUES('schema_version','11');
    \\INSERT INTO metadata VALUES('clean_shutdown','0');
    \\INSERT INTO metadata VALUES('final_state','recording');
    \\INSERT INTO measurement_status VALUES('cycle_summary',0,'summary','unfinalized','capture has not finalized',0,0);
    \\INSERT INTO measurement_status VALUES('allocation_counters',0,'summary','unfinalized','capture has not finalized',0,0);
    \\INSERT INTO measurement_status VALUES('annotations',1,'summary','unfinalized','capture has not finalized',0,0);
    \\INSERT INTO measurement_status VALUES('hosted_effects',2,'standard','unfinalized','capture has not finalized',0,0);
    \\INSERT INTO measurement_status VALUES('task_lifecycle',3,'standard','unfinalized','capture has not finalized',0,0);
    \\INSERT INTO measurement_status VALUES('allocation_lifecycle',4,'full','unfinalized','capture has not finalized',0,0);
    \\INSERT INTO measurement_status VALUES('resource_lifecycle',5,'standard','unfinalized','capture has not finalized',0,0);
    \\INSERT INTO measurement_status VALUES('queue_pressure',6,'standard','unfinalized','capture has not finalized',0,0);
    \\INSERT INTO measurement_status VALUES('draw_observations',7,'summary','unfinalized','capture has not finalized',0,0);
    \\INSERT INTO measurement_status VALUES('structural_latency',8,'standard','unfinalized','capture has not finalized',0,0);
    \\INSERT INTO measurement_status VALUES('backend_facts',9,'summary','unfinalized','capture has not finalized',0,0);
    \\INSERT INTO measurement_status VALUES('callback_summaries',10,'summary','unfinalized','capture has not finalized',0,0);
    \\INSERT INTO measurement_status VALUES('gpu_timing',NULL,'summary','unavailable','selected backends expose no honest non-stalling GPU timing',0,0);
;

fn writerMain(shared: *Shared) void {
    if (rocray_sqlite_init() != SQLITE_OK) return startupFailed(shared, error.SqliteUnavailable);
    // Refuse an existing destination before any write-capable connection can
    // change its journal or schema. EXCLUSIVE on the create below closes the
    // check/create race with another recorder.
    var existing: ?*anyopaque = null;
    if (rocray_sqlite_open(shared.path.ptr, 2, 0, &existing) == SQLITE_OK) {
        _ = rocray_sqlite_close(existing);
        return startupFailed(shared, error.AlreadyExists);
    }
    if (existing != null) _ = rocray_sqlite_close(existing);
    var db: ?*anyopaque = null;
    if (rocray_sqlite_open(shared.path.ptr, 3, 1000, &db) != SQLITE_OK) {
        if (db != null) _ = rocray_sqlite_close(db);
        return startupFailed(shared, error.OpenFailed);
    }
    defer _ = rocray_sqlite_close(db);
    if (rocray_sqlite_exec(db, schema_sql) != SQLITE_OK) return startupFailed(shared, error.SchemaFailed);
    if (!insertMetadata(db, "requested_detail", @tagName(shared.requested_detail)) or
        !insertMetadata(db, "effective_detail", @tagName(shared.effective_detail)) or
        !insertMetadata(db, "host_os", @tagName(builtin.os.tag)) or
        !insertMetadata(db, "host_arch", @tagName(builtin.cpu.arch)) or
        !insertMetadata(db, "rocray_version", shared.rocray_version) or
        !insertMetadata(db, "roc_compiler_pin", shared.roc_compiler_pin) or
        !insertMetadata(db, "target_profile", shared.target_profile) or
        !insertMetadata(db, "backend", shared.backend) or
        !insertMetadata(db, "executable_name", shared.executable_name) or
        !insertMetadata(db, "app_name", shared.app_name) or
        !insertMetadata(db, "clock_source", shared.clock_source) or
        !insertMetadataInt(db, "clock_resolution_ns", shared.clock_resolution_ns) or
        !insertMetadataInt(db, "utc_origin_unix_ns", shared.utc_origin_unix_ns) or
        !insertMetadata(db, "unavailable_sources", shared.unavailable_sources) or
        !insertMetadataInt(db, "chunk_bytes", chunk_bytes) or
        !insertMetadataInt(db, "chunk_count", shared.pool.chunks.len) or
        !insertMetadataInt(db, "summary_reserve", shared.pool.summary_reserve) or
        !insertMetadataInt(db, "transaction_chunks", shared.transaction_chunks) or
        !insertMetadataInt(db, "max_output_bytes", shared.max_output_bytes) or
        !insertMetadataInt(db, "terminal_reserve_bytes", terminalReserveBytes(shared.max_output_bytes)) or
        !insertMetadataInt(db, "output_admission_limit_bytes", shared.max_output_bytes -| terminalReserveBytes(shared.max_output_bytes)) or
        !insertMetadataInt(db, "benchmark_writer_delay_ms", shared.benchmark_writer_delay_ms) or
        !insertMetadataInt(db, "max_transaction_overshoot_bytes", maxTransactionOvershootBytes(shared.transaction_chunks)))
    {
        return startupFailed(shared, error.SchemaFailed);
    }

    const cycle_stmt = prepare(db, "INSERT INTO cycles(cycle,start_ns,duration_ns,update_ns,render_callback_ns,task_executor_ns,host_other_ns,alloc_bytes,alloc_calls,free_bytes,free_calls,live_bytes,peak_live_bytes,update_alloc_bytes,update_alloc_calls,task_events,effect_calls,draw_calls,resource_events,queue_events) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20)") orelse return startupFailed(shared, error.SchemaFailed);
    defer _ = rocray_sqlite_finalize(cycle_stmt);
    const annotation_stmt = prepare(db, "INSERT INTO annotations(cycle,timestamp_ns,phase,kind,name,integer_value,real_value,unit,wall_ns,active_ns,parked_ns) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)") orelse return startupFailed(shared, error.SchemaFailed);
    defer _ = rocray_sqlite_finalize(annotation_stmt);
    const gap_stmt = prepare(db, "INSERT INTO recording_gaps(cycle,timestamp_ns,family,lost_count,first_cycle,last_cycle,started_ns,ended_ns,producer_track) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,CASE ?9 WHEN 1 THEN 'frame_thread' WHEN 2 THEN 'host_worker' WHEN 3 THEN 'multiple' ELSE 'unknown' END)") orelse return startupFailed(shared, error.SchemaFailed);
    defer _ = rocray_sqlite_finalize(gap_stmt);
    var detail_stmts = [_]?*anyopaque{
        prepare(db, "INSERT INTO task_events(cycle,timestamp_ns,kind,subject_id,parent_id,duration_ns,value_a,value_b,name) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)"),
        prepare(db, "INSERT INTO hosted_effects(cycle,timestamp_ns,kind,subject_id,parent_id,duration_ns,value_a,value_b,name,outbound_copied_bytes,ownership_transfer_bytes,validation_ns,conversion_ns,worker_ns,external_ns) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)"),
        prepare(db, "INSERT INTO queue_pressure(cycle,timestamp_ns,kind,subject_id,parent_id,duration_ns,value_a,value_b,name) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)"),
        prepare(db, "INSERT INTO resource_lifecycle(cycle,timestamp_ns,kind,subject_id,parent_id,duration_ns,value_a,value_b,name) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)"),
        prepare(db, "INSERT INTO structural_latency(cycle,timestamp_ns,kind,subject_id,parent_id,duration_ns,value_a,value_b,name) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)"),
        prepare(db, "INSERT INTO draw_summaries(cycle,timestamp_ns,kind,subject_id,parent_id,duration_ns,value_a,value_b,name) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)"),
        prepare(db, "INSERT INTO allocation_events(cycle,timestamp_ns,kind,subject_id,parent_id,duration_ns,value_a,value_b,name,phase,task_id,zone_id,bytes,prior_bytes,copied_bytes) VALUES(?1,?2,(?3&15),?4,?5,?6,?7,?8,?9,(?3>>4),?5,?6,?7,?8,CASE WHEN (?3&15)=2 THEN min(?7,?8) ELSE 0 END)"),
        prepare(db, "INSERT INTO gpu_facts(cycle,timestamp_ns,kind,subject_id,parent_id,duration_ns,value_a,value_b,name) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)"),
        prepare(db, "INSERT INTO callback_summaries(cycle,timestamp_ns,phase,subject_id,parent_id,duration_ns,outcome,reserved,name) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)"),
    };
    for (detail_stmts) |stmt| if (stmt == null) return startupFailed(shared, error.SchemaFailed);
    defer {
        for (detail_stmts) |stmt| _ = rocray_sqlite_finalize(stmt);
    }

    shared.startup.store(1, .release);
    if (shared.test_fault == .block_after_start) {
        while (!shared.test_writer_gate.load(.acquire)) std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    while (!shared.stop.load(.acquire) or shared.pool.queued() != 0) {
        if (shared.pool.take()) |submitted| {
            const active_started_ms = recorderWallTimeMs();
            defer shared.writer_active_wall_ns +|= elapsedWallNs(active_started_ms);
            if (shared.benchmark_writer_delay_ms != 0) {
                _ = rocray_sqlite_sleep(@intCast(shared.benchmark_writer_delay_ms));
            }
            if (rocray_sqlite_exec(db, "BEGIN IMMEDIATE") != SQLITE_OK) {
                shared.failed.store(true, .release);
                shared.accepting.store(false, .release);
            }
            var count: usize = 0;
            var rows_in_transaction: u64 = 0;
            var current: ?Submitted = submitted;
            while (current) |item| {
                const writable = !shared.failed.load(.acquire) and !shared.output_limited.load(.acquire);
                if (writable) {
                    if (writeChunk(cycle_stmt, annotation_stmt, gap_stmt, &detail_stmts, item.chunk(&shared.pool).written())) |rows| {
                        rows_in_transaction +|= rows;
                    } else {
                        shared.failed.store(true, .release);
                        shared.accepting.store(false, .release);
                    }
                }
                shared.pool.release(item);
                count += 1;
                if (count == shared.transaction_chunks) break;
                current = shared.pool.take();
            }
            if (rocray_sqlite_exec(db, "COMMIT") != SQLITE_OK) {
                shared.failed.store(true, .release);
                shared.accepting.store(false, .release);
                _ = rocray_sqlite_exec(db, "ROLLBACK");
            } else {
                _ = shared.rows_written.fetchAdd(rows_in_transaction, .monotonic);
                const committed = shared.transactions.fetchAdd(1, .monotonic) + 1;
                if (committed == 1) switch (shared.test_fault) {
                    .none, .block_after_start => {},
                    .abrupt_after_first_commit => {
                        shared.accepting.store(false, .release);
                        return;
                    },
                    .fail_after_first_commit => {
                        shared.failed.store(true, .release);
                        shared.accepting.store(false, .release);
                    },
                    .unresolved_relationship => {},
                };
            }
            const admission_limit = shared.max_output_bytes -| terminalReserveBytes(shared.max_output_bytes);
            if (shared.max_output_bytes != 0 and databaseSize(db) >= admission_limit) {
                shared.output_limited.store(true, .release);
                shared.accepting.store(false, .release);
            }
        } else {
            // At most one millisecond of shutdown latency, without burning a
            // core while an application produces no recorder events.
            const idle_started_ms = recorderWallTimeMs();
            _ = rocray_sqlite_sleep(1);
            shared.writer_idle_wall_ns +|= elapsedWallNs(idle_started_ms);
        }
    }
    finalizeRecording(shared, db);
}

fn writeChunk(cycle_stmt: ?*anyopaque, annotation_stmt: ?*anyopaque, gap_stmt: ?*anyopaque, detail_stmts: *const [9]?*anyopaque, bytes: []const u8) ?u64 {
    var at: usize = 0;
    var rows: u64 = 0;
    while (at < bytes.len) {
        if (bytes.len - at < 2) return null;
        const len: usize = std.mem.readInt(u16, bytes[at..][0..2], .little);
        at += 2;
        if (len == 0 or len > bytes.len - at) return null;
        if (!writeEvent(cycle_stmt, annotation_stmt, gap_stmt, detail_stmts, bytes[at .. at + len])) return null;
        at += len;
        rows +|= 1;
    }
    return rows;
}

fn finalizeRecording(shared: *Shared, db: ?*anyopaque) void {
    defer shared.finalized.store(true, .release);
    shared.drain_duration_ns = elapsedWallNs(shared.shutdown_started_ms.load(.acquire));
    if (rocray_sqlite_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)") == SQLITE_OK) {
        _ = shared.checkpoints.fetchAdd(1, .monotonic);
    } else {
        shared.failed.store(true, .release);
    }

    if (shared.test_fault == .unresolved_relationship) {
        _ = rocray_sqlite_exec(db, "PRAGMA foreign_keys=OFF");
        _ = rocray_sqlite_exec(db, "INSERT INTO annotations(cycle,timestamp_ns,phase,kind,name,integer_value,real_value,unit,wall_ns,active_ns,parked_ns,run_id) VALUES(0,0,0,0,'injected-invalid-parent',NULL,NULL,0,0,0,0,999)");
        _ = rocray_sqlite_exec(db, "PRAGMA foreign_keys=ON");
    }
    // An orderly capture is only declared clean after SQLite has proven that
    // every declared relationship is structurally intact. SQLITE_DONE means
    // the diagnostic query produced no violation rows.
    if (!foreignKeysValid(db)) shared.failed.store(true, .release);

    const health = prepare(db, "INSERT INTO recorder_health VALUES(1,?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)") orelse {
        shared.failed.store(true, .release);
        writeFinalMetadata(shared, db);
        return;
    };
    defer _ = rocray_sqlite_finalize(health);
    const health_ok = bindU64(health, 1, shared.transactions.load(.acquire)) and
        // Includes the final checkpoint attempted after metadata below.
        bindU64(health, 2, shared.checkpoints.load(.acquire) +| 1) and
        bindU64(health, 3, shared.pool.queueHighWater()) and
        bindU64(health, 4, databaseSize(db)) and
        bindU64(health, 5, shared.pool.refusedTotal()) and
        bindU64(health, 6, shared.rows_written.load(.acquire)) and
        bindU64(health, 7, @intFromBool(shared.failed.load(.acquire))) and
        bindU64(health, 8, @intFromBool(shared.output_limited.load(.acquire))) and
        bindU64(health, 9, shared.writer_active_wall_ns) and
        bindU64(health, 10, shared.writer_idle_wall_ns) and
        // Portable per-thread CPU time is unavailable at this boundary. NULL
        // is distinct from a measured zero and metadata names the omission.
        rocray_sqlite_bind_null(health, 11) == SQLITE_OK and
        finishStatement(health);
    if (!health_ok) shared.failed.store(true, .release);
    if (rocray_sqlite_exec(db, finalize_measurements_sql) != SQLITE_OK) shared.failed.store(true, .release);
    writeFinalMetadata(shared, db);
    if (rocray_sqlite_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)") == SQLITE_OK) {
        _ = shared.checkpoints.fetchAdd(1, .monotonic);
    } else {
        shared.failed.store(true, .release);
        // Best effort disclosure, followed by one final attempt to make that
        // state part of the main database rather than leave it only in WAL.
        _ = insertMetadata(db, "final_state", "recorder_failed");
        _ = rocray_sqlite_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)");
    }
}

/// Final evidence status is written outside the bounded event stream so a
/// consumer never has to infer whether an empty table means measured zero.
/// The gap family numbers are the stable `Family` order above.
const finalize_measurements_sql =
    \\UPDATE measurement_status SET rows_recorded = CASE name
    \\ WHEN 'cycle_summary' THEN (SELECT count(*) FROM cycles)
    \\ WHEN 'allocation_counters' THEN (SELECT count(*) FROM cycles)
    \\ WHEN 'annotations' THEN (SELECT count(*) FROM annotations)
    \\ WHEN 'hosted_effects' THEN (SELECT count(*) FROM hosted_effects)
    \\ WHEN 'task_lifecycle' THEN (SELECT count(*) FROM task_events)
    \\ WHEN 'allocation_lifecycle' THEN (SELECT count(*) FROM allocation_events)
    \\ WHEN 'resource_lifecycle' THEN (SELECT count(*) FROM resource_lifecycle)
    \\ WHEN 'queue_pressure' THEN (SELECT count(*) FROM queue_pressure)
    \\ WHEN 'draw_observations' THEN (SELECT count(*) FROM draw_summaries)
    \\ WHEN 'structural_latency' THEN (SELECT count(*) FROM structural_latency)
    \\ WHEN 'backend_facts' THEN (SELECT count(*) FROM gpu_facts)
    \\ WHEN 'callback_summaries' THEN (SELECT count(*) FROM callback_summaries)
    \\ ELSE 0 END;
    \\UPDATE measurement_status SET omitted_events = coalesce((SELECT sum(lost_count) FROM recording_gaps WHERE recording_gaps.family=measurement_status.family),0) WHERE family IS NOT NULL;
    \\UPDATE measurement_status SET status = CASE
    \\ WHEN status='unavailable' THEN 'unavailable'
    \\ WHEN required_detail='full' AND (SELECT value FROM metadata WHERE key='effective_detail')<>'full' THEN 'not_recorded'
    \\ WHEN required_detail='standard' AND (SELECT value FROM metadata WHERE key='effective_detail')='summary' THEN 'not_recorded'
    \\ WHEN omitted_events<>0 THEN 'partial'
    \\ ELSE 'complete' END;
    \\UPDATE measurement_status SET reason = CASE status
    \\ WHEN 'complete' THEN 'complete evidence; zero rows means measured zero'
    \\ WHEN 'partial' THEN 'recorder omitted events for this measurement'
    \\ WHEN 'not_recorded' THEN 'selected detail level does not record this measurement'
    \\ ELSE reason END;
;

fn recorderWallTimeMs() u64 {
    return @intCast(@max(rocray_sqlite_wall_time_ms(), 0));
}

fn elapsedWallNs(start_ms: u64) u64 {
    const end_ms = recorderWallTimeMs();
    return (end_ms -| start_ms) *| std.time.ns_per_ms;
}

fn foreignKeysValid(db: ?*anyopaque) bool {
    const stmt = prepare(db, "PRAGMA foreign_key_check") orelse return false;
    defer _ = rocray_sqlite_finalize(stmt);
    return rocray_sqlite_step(stmt) == SQLITE_DONE;
}

fn writeFinalMetadata(shared: *Shared, db: ?*anyopaque) void {
    var ok = insertMetadataInt(db, "rows_written", shared.rows_written.load(.acquire));
    ok = insertMetadata(db, "journal_mode", "wal") and ok;
    ok = insertMetadata(db, "synchronous", "normal") and ok;
    ok = insertMetadataInt(db, "drain_duration_ns", shared.drain_duration_ns) and ok;
    ok = insertMetadata(db, "application_outcome", shared.application_outcome) and ok;
    if (ok and !shared.failed.load(.acquire)) {
        ok = rocray_sqlite_exec(db, "UPDATE metadata SET value='1' WHERE key='clean_shutdown'") == SQLITE_OK;
    }
    if (!ok) shared.failed.store(true, .release);
    // Written last so any preceding finalization failure is reflected in the
    // durable state whenever SQLite can still accept this disclosure.
    const state = if (shared.failed.load(.acquire))
        "recorder_failed"
    else if (shared.output_limited.load(.acquire))
        "output_limit"
    else
        "complete";
    if (!insertMetadata(db, "final_state", state)) shared.failed.store(true, .release);
}

fn startupFailed(shared: *Shared, err: StartError) void {
    shared.startup_error = err;
    shared.accepting.store(false, .release);
    shared.startup.store(2, .release);
}

fn prepare(db: ?*anyopaque, sql: [*:0]const u8) ?*anyopaque {
    var stmt: ?*anyopaque = null;
    var tail: c_int = 0;
    if (rocray_sqlite_prepare(db, sql, &stmt, &tail) != SQLITE_OK or tail != 0) return null;
    return stmt;
}

fn insertMetadata(db: ?*anyopaque, key: []const u8, value: []const u8) bool {
    const stmt = prepare(db, "INSERT OR REPLACE INTO metadata(key,value) VALUES(?1,?2)") orelse return false;
    defer _ = rocray_sqlite_finalize(stmt);
    if (rocray_sqlite_bind_text(stmt, 1, key.ptr, @intCast(key.len)) != SQLITE_OK) return false;
    if (rocray_sqlite_bind_text(stmt, 2, value.ptr, @intCast(value.len)) != SQLITE_OK) return false;
    return rocray_sqlite_step(stmt) == SQLITE_DONE;
}

fn insertMetadataInt(db: ?*anyopaque, key: []const u8, value: u64) bool {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return false;
    return insertMetadata(db, key, text);
}

fn finishStatement(stmt: ?*anyopaque) bool {
    const stepped = rocray_sqlite_step(stmt) == SQLITE_DONE;
    const cleared = rocray_sqlite_clear_bindings(stmt) == SQLITE_OK;
    const reset = rocray_sqlite_reset(stmt) == SQLITE_OK;
    return stepped and cleared and reset;
}

fn bindU64(stmt: ?*anyopaque, index: c_int, value: u64) bool {
    return rocray_sqlite_bind_int64(stmt, index, @bitCast(value)) == SQLITE_OK;
}

fn writeEvent(cycle_stmt: ?*anyopaque, annotation_stmt: ?*anyopaque, gap_stmt: ?*anyopaque, detail_stmts: *const [9]?*anyopaque, bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    switch (bytes[0]) {
        @intFromEnum(EventKind.cycle) => {
            if (bytes.len != 161) return false;
            for (1..21) |index| {
                if (!bindU64(cycle_stmt, @intCast(index), std.mem.readInt(u64, bytes[1 + (index - 1) * 8 ..][0..8], .little))) return false;
            }
            return finishStatement(cycle_stmt);
        },
        @intFromEnum(EventKind.annotation) => {
            if (bytes.len < 62) return false;
            if (bytes[18] > @intFromEnum(AnnotationKind.zone_abort)) return false;
            if (!bindU64(annotation_stmt, 1, std.mem.readInt(u64, bytes[1..9], .little))) return false;
            if (!bindU64(annotation_stmt, 2, std.mem.readInt(u64, bytes[9..17], .little))) return false;
            if (rocray_sqlite_bind_int64(annotation_stmt, 3, bytes[17]) != SQLITE_OK) return false;
            if (rocray_sqlite_bind_int64(annotation_stmt, 4, bytes[18]) != SQLITE_OK) return false;
            const name_len = std.mem.readInt(u16, bytes[28..30], .little);
            if (30 + name_len + 32 != bytes.len) return false;
            if (rocray_sqlite_bind_text(annotation_stmt, 5, bytes[30 .. 30 + name_len].ptr, name_len) != SQLITE_OK) return false;
            const annotation_kind: AnnotationKind = @enumFromInt(bytes[18]);
            if (annotation_kind == .sample_i64) {
                if (rocray_sqlite_bind_int64(annotation_stmt, 6, std.mem.readInt(i64, bytes[20..28], .little)) != SQLITE_OK) return false;
            } else {
                if (rocray_sqlite_bind_null(annotation_stmt, 6) != SQLITE_OK) return false;
            }
            if (annotation_kind == .sample_f64) {
                if (rocray_sqlite_bind_double(annotation_stmt, 7, @bitCast(std.mem.readInt(u64, bytes[30 + name_len ..][0..8], .little))) != SQLITE_OK) return false;
            } else {
                if (rocray_sqlite_bind_null(annotation_stmt, 7) != SQLITE_OK) return false;
            }
            if (rocray_sqlite_bind_int64(annotation_stmt, 8, bytes[19]) != SQLITE_OK) return false;
            for (0..3) |index| {
                if (!bindU64(annotation_stmt, @intCast(9 + index), std.mem.readInt(u64, bytes[38 + name_len + index * 8 ..][0..8], .little))) return false;
            }
            return finishStatement(annotation_stmt);
        },
        @intFromEnum(EventKind.gap) => {
            if (bytes.len != 59 or bytes[58] > @intFromEnum(Producer.multiple)) return false;
            if (!bindU64(gap_stmt, 1, std.mem.readInt(u64, bytes[1..9], .little))) return false;
            if (!bindU64(gap_stmt, 2, std.mem.readInt(u64, bytes[9..17], .little))) return false;
            if (rocray_sqlite_bind_int64(gap_stmt, 3, bytes[17]) != SQLITE_OK) return false;
            if (!bindU64(gap_stmt, 4, std.mem.readInt(u64, bytes[18..26], .little))) return false;
            for (0..4) |index| {
                if (!bindU64(gap_stmt, @intCast(5 + index), std.mem.readInt(u64, bytes[26 + index * 8 ..][0..8], .little))) return false;
            }
            if (rocray_sqlite_bind_int64(gap_stmt, 9, bytes[58]) != SQLITE_OK) return false;
            return finishStatement(gap_stmt);
        },
        @intFromEnum(EventKind.detail) => {
            if (bytes.len < 61 or bytes[1] > @intFromEnum(DetailFamily.callback)) return false;
            const name_len = std.mem.readInt(u16, bytes[59..61], .little);
            const is_effect = bytes[1] == @intFromEnum(DetailFamily.effect);
            const expected_len: usize = 61 + name_len + (if (is_effect) @as(usize, 56) else 0);
            if (expected_len != bytes.len) return false;
            const stmt = detail_stmts[bytes[1]];
            for (0..7) |index| {
                if (!bindU64(stmt, @intCast(index + 1), std.mem.readInt(u64, bytes[3 + index * 8 ..][0..8], .little))) return false;
            }
            if (rocray_sqlite_bind_int64(stmt, 3, bytes[2]) != SQLITE_OK) return false;
            // Rebind fields shifted by the table's explicit kind column.
            for (2..7) |index| {
                if (!bindU64(stmt, @intCast(index + 2), std.mem.readInt(u64, bytes[3 + index * 8 ..][0..8], .little))) return false;
            }
            if (rocray_sqlite_bind_text(stmt, 9, bytes[61..].ptr, name_len) != SQLITE_OK) return false;
            if (is_effect) {
                const extras = bytes[61 + name_len ..];
                if (!bindU64(stmt, 10, std.mem.readInt(u64, extras[0..8], .little)) or
                    !bindU64(stmt, 11, std.mem.readInt(u64, extras[8..16], .little))) return false;
                const mask = std.mem.readInt(u64, extras[48..56], .little);
                for (0..4) |index| {
                    const sql_index: c_int = @intCast(12 + index);
                    if (mask & (@as(u64, 1) << @intCast(index)) != 0) {
                        if (!bindU64(stmt, sql_index, std.mem.readInt(u64, extras[16 + index * 8 ..][0..8], .little))) return false;
                    } else if (rocray_sqlite_bind_null(stmt, sql_index) != SQLITE_OK) return false;
                }
            }
            return finishStatement(stmt);
        },
        else => return false,
    }
}

fn databaseSize(db: ?*anyopaque) u64 {
    return @intCast(@max(rocray_sqlite_storage_size(db), 0));
}

fn terminalReserveBytes(max_output_bytes: u64) u64 {
    return @min(max_output_bytes / 2, 1024 * 1024);
}

fn maxTransactionOvershootBytes(transaction_chunks: usize) u64 {
    return @as(u64, @intCast(transaction_chunks)) *| chunk_bytes +| 4096;
}

test "detail admission preserves summary capacity" {
    var pool = try Pool.init(std.testing.allocator, 4, 2);
    defer pool.deinit();

    const first = pool.reserve(.detail, .hosted_effect).?;
    const second = pool.reserve(.detail, .task_lifecycle).?;
    try std.testing.expect(pool.reserve(.detail, .draw_observation) == null);
    try std.testing.expectEqual(@as(usize, 2), pool.available());

    const summary_a = pool.reserve(.summary, .cycle_summary).?;
    const summary_b = pool.reserve(.summary, .cycle_summary).?;
    try std.testing.expect(pool.reserve(.summary, .cycle_summary) == null);

    pool.cancel(first);
    pool.cancel(second);
    pool.cancel(summary_a);
    pool.cancel(summary_b);
    try std.testing.expectEqual(@as(usize, 4), pool.available());
}

test "output admission reserves terminal space and bounds one transaction" {
    try std.testing.expectEqual(@as(u64, 1024 * 1024), terminalReserveBytes(64 * 1024 * 1024));
    try std.testing.expectEqual(@as(u64, 512 * 1024), terminalReserveBytes(1024 * 1024));
    try std.testing.expectEqual(@as(u64, 64 * chunk_bytes + 4096), maxTransactionOvershootBytes(64));
}

test "a blocked writer cannot make producer reservation wait or grow" {
    var pool = try Pool.init(std.testing.allocator, 4, 1);
    defer pool.deinit();

    var held: [3]Reservation = undefined;
    for (&held) |*reservation| {
        reservation.* = pool.reserve(.detail, .hosted_effect).?;
        pool.submit(reservation.*, 0);
    }
    try std.testing.expectEqual(@as(usize, 1), pool.available());
    const refused_before = pool.refusedTotal();
    // Model a writer retaining every submitted detail chunk. Each producer
    // attempt performs one bounded reserve and returns; no clock, allocator,
    // condition wait, or writer progress participates in this loop.
    for (0..100_000) |_| try std.testing.expect(pool.reserve(.detail, .hosted_effect) == null);
    try std.testing.expectEqual(@as(usize, 1), pool.available());
    try std.testing.expectEqual(refused_before + 100_000, pool.refusedTotal());
    for (held) |_| pool.release(pool.take().?);
}

test "submitted chunks are FIFO and require writer release" {
    var pool = try Pool.init(std.testing.allocator, 3, 1);
    defer pool.deinit();

    const a = pool.reserve(.summary, .cycle_summary).?;
    @memcpy(a.chunk(&pool).slice()[0..3], "one");
    pool.submit(a, 3);
    const b = pool.reserve(.detail, .annotation).?;
    @memcpy(b.chunk(&pool).slice()[0..3], "two");
    pool.submit(b, 3);

    try std.testing.expectEqual(@as(usize, 2), pool.queued());
    const got_a = pool.take().?;
    try std.testing.expectEqualStrings("one", got_a.chunk(&pool).written());
    const got_b = pool.take().?;
    try std.testing.expectEqualStrings("two", got_b.chunk(&pool).written());
    try std.testing.expect(pool.take() == null);
    try std.testing.expectEqual(@as(usize, 1), pool.available());

    pool.release(got_a);
    pool.release(got_b);
    try std.testing.expectEqual(@as(usize, 3), pool.available());
}

test "loss snapshots are per-family saturating and drain once" {
    var pool = try Pool.init(std.testing.allocator, 1, 1);
    defer pool.deinit();

    try std.testing.expect(pool.reserveAt(.detail, .allocation_lifecycle, .{ .cycle = 4, .timestamp_ns = 40, .producer = .frame_thread }) == null);
    try std.testing.expect(pool.reserveAt(.detail, .allocation_lifecycle, .{ .cycle = 7, .timestamp_ns = 90, .producer = .host_worker }) == null);
    const summary = pool.reserve(.summary, .cycle_summary).?;
    try std.testing.expect(pool.reserve(.summary, .cycle_summary) == null);

    const losses = pool.takeLosses();
    try std.testing.expectEqual(@as(u64, 2), losses.count(.allocation_lifecycle));
    try std.testing.expectEqual(@as(u64, 4), losses.first_cycles[@intFromEnum(Family.allocation_lifecycle)]);
    try std.testing.expectEqual(@as(u64, 7), losses.last_cycles[@intFromEnum(Family.allocation_lifecycle)]);
    try std.testing.expectEqual(@as(u64, 40), losses.started_ns[@intFromEnum(Family.allocation_lifecycle)]);
    try std.testing.expectEqual(@as(u64, 90), losses.ended_ns[@intFromEnum(Family.allocation_lifecycle)]);
    try std.testing.expectEqual(Producer.multiple, losses.producers[@intFromEnum(Family.allocation_lifecycle)]);
    try std.testing.expectEqual(@as(u64, 1), losses.count(.cycle_summary));
    try std.testing.expectEqual(@as(u64, 3), losses.total());
    try std.testing.expectEqual(@as(u64, 0), pool.takeLosses().total());

    pool.cancel(summary);
}

test "summary starvation restores gap counts until capacity returns" {
    const path = try std.testing.allocator.dupeZ(u8, "unused");
    defer std.testing.allocator.free(path);
    var shared = Shared{
        .allocator = std.testing.allocator,
        .pool = try Pool.init(std.testing.allocator, 2, 1),
        .path = path,
        .max_output_bytes = 1,
        .transaction_chunks = 1,
        .requested_detail = .standard,
        .effective_detail = .standard,
        .rocray_version = "unavailable",
        .roc_compiler_pin = "unavailable",
        .target_profile = "unavailable",
        .backend = "unavailable",
        .executable_name = "unavailable",
        .app_name = "unavailable",
        .unavailable_sources = "unavailable",
        .test_fault = .none,
    };
    defer shared.pool.deinit();
    var session = Session{ .shared = &shared, .thread = undefined };
    const occupied_a = shared.pool.reserve(.summary, .cycle_summary).?;
    const occupied_b = shared.pool.reserve(.summary, .cycle_summary).?;
    session.noteLoss(.draw_observation, 3);
    try std.testing.expect(!session.flushGaps(9, 10));
    // The failed attempt to reserve the gap row is itself disclosed, so the
    // restored count includes the three original omissions plus that refusal.
    try std.testing.expectEqual(@as(u64, 4), shared.pool.losses[@intFromEnum(Family.draw_observation)]);

    shared.pool.cancel(occupied_a);
    try std.testing.expect(session.flushGaps(9, 10));
    try std.testing.expectEqual(@as(u64, 0), shared.pool.losses[@intFromEnum(Family.draw_observation)]);
    const gap = shared.pool.take().?;
    const framed = gap.chunk(&shared.pool).written();
    const encoded_len: usize = std.mem.readInt(u16, framed[0..2], .little);
    const bytes = framed[2 .. 2 + encoded_len];
    try std.testing.expectEqual(@intFromEnum(EventKind.gap), bytes[0]);
    try std.testing.expectEqual(@as(u64, 4), std.mem.readInt(u64, bytes[18..26], .little));
    shared.pool.release(gap);
    shared.pool.cancel(occupied_b);
}

test "capacity validation rejects unusable pools" {
    try std.testing.expectError(error.InvalidCapacity, Pool.init(std.testing.allocator, 0, 0));
    try std.testing.expectError(error.InvalidCapacity, Pool.init(std.testing.allocator, 2, 3));
}

test "malformed event bytes are refused without interpreting an invalid tag" {
    const details = [_]?*anyopaque{null} ** 9;
    try std.testing.expect(!writeEvent(null, null, null, &details, &.{}));
    try std.testing.expect(!writeEvent(null, null, null, &details, &.{255}));
    try std.testing.expect(!writeEvent(null, null, null, &details, &.{@intFromEnum(EventKind.cycle)}));
    try std.testing.expect(!writeEvent(null, null, null, &details, &.{ @intFromEnum(EventKind.detail), 99 }));
    var truncated_cycle = [_]u8{0} ** 152;
    truncated_cycle[0] = @intFromEnum(EventKind.cycle);
    try std.testing.expect(!writeEvent(null, null, null, &details, &truncated_cycle));
    var truncated_annotation = [_]u8{0} ** 61;
    truncated_annotation[0] = @intFromEnum(EventKind.annotation);
    try std.testing.expect(!writeEvent(null, null, null, &details, &truncated_annotation));
    var truncated_gap = [_]u8{0} ** 65;
    truncated_gap[0] = @intFromEnum(EventKind.gap);
    try std.testing.expect(!writeEvent(null, null, null, &details, &truncated_gap));
    inline for (0..9) |family| {
        var truncated_detail = [_]u8{0} ** 60;
        truncated_detail[0] = @intFromEnum(EventKind.detail);
        truncated_detail[1] = family;
        try std.testing.expect(!writeEvent(null, null, null, &details, &truncated_detail));
    }
}

test "session writer creates and finalizes a queryable stage one database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/capture.rrstats", .{tmp.sub_path});

    var session = try Session.start(std.testing.allocator, .{
        .path = path,
        .chunk_count = 32,
        .summary_reserve = 4,
        .transaction_chunks = 2,
        .detail = .full,
        .rocray_version = "unavailable",
        .roc_compiler_pin = "nightly-test-pin",
        .target_profile = "native-headless",
        .backend = "headless_stub",
        .executable_name = "example-app",
        .app_name = "example-app",
        .clock_source = "test-monotonic",
        .clock_resolution_ns = 7,
        .utc_origin_unix_ns = 123456,
    });
    try std.testing.expect(session.recordCycle(.{
        .cycle = 7,
        .start_ns = 100,
        .duration_ns = 20,
        .update_ns = 8,
        .render_callback_ns = 9,
        .task_executor_ns = 3,
        .host_other_ns = 0,
        .alloc_bytes = 512,
        .alloc_calls = 4,
        .free_bytes = 128,
        .free_calls = 2,
        .live_bytes = 384,
        .peak_live_bytes = 640,
        .update_alloc_bytes = 256,
        .update_alloc_calls = 3,
        .task_events = 7,
        .effect_calls = 8,
        .draw_calls = 9,
        .resource_events = 10,
        .queue_events = 11,
    }));
    try std.testing.expect(session.recordAnnotation(.{
        .cycle = 7,
        .timestamp_ns = 108,
        .phase = 2,
        .kind = .mark,
        .name = "physics complete",
    }));
    try std.testing.expect(session.recordAnnotation(.{
        .cycle = 7,
        .timestamp_ns = 109,
        .phase = 4,
        .kind = .zone_end,
        .name = "load",
        .wall_ns = 30,
        .active_ns = 11,
        .parked_ns = 19,
    }));
    try std.testing.expect(session.recordTask(.{ .cycle = 7, .timestamp_ns = 109, .kind = 2, .subject_id = 4, .duration_ns = 6, .name = "park" }));
    try std.testing.expect(session.recordEffect(.{ .cycle = 7, .timestamp_ns = 110, .kind = 1, .effect_id = 12, .correlation_id = 4, .duration_ns = 5, .outcome = .success, .inbound_copied_bytes = 32, .outbound_copied_bytes = 48, .ownership_transfer_bytes = 64, .validation_ns = 2, .name = "Files.read_bytes!" }));
    try std.testing.expect(session.recordQueue(.{ .cycle = 7, .timestamp_ns = 111, .kind = 1, .value_a = 3, .value_b = 32, .name = "tasks" }));
    try std.testing.expect(session.recordResource(.{ .cycle = 7, .timestamp_ns = 112, .kind = 0, .subject_id = 9, .name = "texture" }));
    try std.testing.expect(session.recordLatency(.{ .cycle = 7, .timestamp_ns = 113, .kind = 0, .duration_ns = 11, .name = "input_to_present" }));
    try std.testing.expect(session.recordDraw(.{ .cycle = 7, .timestamp_ns = 114, .kind = 0, .value_a = 12, .value_b = 2, .name = "batch" }));
    try std.testing.expect(session.recordAllocation(.{ .cycle = 7, .timestamp_ns = 115, .kind = 2 | (4 << 4), .subject_id = 10, .parent_id = 17, .duration_ns = 99, .value_a = 128, .value_b = 64, .name = "realloc_move" }));
    try std.testing.expect(session.recordAllocation(.{ .cycle = 7, .timestamp_ns = 116, .kind = 3 | (2 << 4), .subject_id = 10, .value_a = 160, .value_b = 128, .name = "realloc_in_place" }));
    try std.testing.expect(session.recordGpu(.{ .cycle = 7, .timestamp_ns = 116, .kind = 3, .name = "gpu_timing_unavailable" }));
    try std.testing.expect(session.recordCallback(.{
        .cycle = 0,
        .timestamp_ns = 1,
        .kind = @intFromEnum(CallbackPhase.init),
        .duration_ns = 99,
        .value_a = @intFromEnum(CallbackOutcome.success),
        .name = "init!",
    }));
    _ = session.stop();

    const zpath = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(zpath);
    var db: ?*anyopaque = null;
    try std.testing.expectEqual(SQLITE_OK, rocray_sqlite_open(zpath.ptr, 2, 1000, &db));
    defer _ = rocray_sqlite_close(db);
    try std.testing.expect(foreignKeysValid(db));
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM cycles").?);
    try std.testing.expectEqual(@as(i64, 7), queryI64(db, "SELECT cycle FROM cycles").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM cycles WHERE free_bytes=128 AND free_calls=2 AND live_bytes=384 AND peak_live_bytes=640 AND update_alloc_bytes=256 AND update_alloc_calls=3 AND task_events=7 AND effect_calls=8 AND draw_calls=9 AND resource_events=10 AND queue_events=11").?);
    try std.testing.expectEqual(@as(i64, 2), queryI64(db, "SELECT count(*) FROM annotations").?);
    try std.testing.expectEqual(@as(i64, 30), queryI64(db, "SELECT wall_ns FROM annotations WHERE kind=2").?);
    try std.testing.expectEqual(@as(i64, 11), queryI64(db, "SELECT active_ns FROM annotations WHERE kind=2").?);
    try std.testing.expectEqual(@as(i64, 19), queryI64(db, "SELECT parked_ns FROM annotations WHERE kind=2").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM task_events").?);
    try std.testing.expectEqual(@as(i64, 4), queryI64(db, "SELECT subject_id FROM task_events").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM hosted_effects").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM hosted_effects WHERE subject_id=12 AND parent_id=4 AND value_a=32 AND value_b=0 AND outbound_copied_bytes=48 AND ownership_transfer_bytes=64 AND validation_ns=2 AND conversion_ns IS NULL AND worker_ns IS NULL AND external_ns IS NULL").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM queue_pressure").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM resource_lifecycle").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM structural_latency").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM draw_summaries").?);
    try std.testing.expectEqual(@as(i64, 2), queryI64(db, "SELECT count(*) FROM allocation_events").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM allocation_events WHERE kind=2 AND phase=4 AND task_id=17 AND zone_id=99 AND bytes=128 AND prior_bytes=64 AND copied_bytes=64").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM allocation_events WHERE kind=3 AND phase=2 AND bytes=160 AND prior_bytes=128 AND copied_bytes=0").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(DISTINCT a.subject_id) FROM allocation_events a WHERE kind IN (0,2,3) AND NOT EXISTS (SELECT 1 FROM allocation_events f WHERE f.subject_id=a.subject_id AND f.kind=1 AND f.timestamp_ns>=a.timestamp_ns)").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM gpu_facts").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM callback_summaries WHERE phase=0 AND outcome=0 AND duration_ns=99").?);
    try std.testing.expectEqual(@as(i64, 12), queryI64(db, "SELECT count(*) FROM measurement_status WHERE status='complete'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM measurement_status WHERE name='gpu_timing' AND status='unavailable'").?);
    try std.testing.expectEqual(@as(i64, 0), queryI64(db, "SELECT count(*) FROM measurement_status WHERE status IN ('unfinalized','partial','not_recorded')").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='clean_shutdown'").?);
    try std.testing.expectEqual(@as(i64, schema_version), queryI64(db, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='schema_version'").?);
    try std.testing.expectEqual(@as(i64, 3), queryI64(db, "SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN ('annotations_by_run_cycle_time','gaps_by_run_cycle','cycles_by_run_duration')").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM runs WHERE id=1").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='requested_detail' AND value='full'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='effective_detail' AND value='full'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='rocray_version' AND value='unavailable'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='unavailable_sources' AND value LIKE '%gpu_timing%' AND value LIKE '%zio_worker_queue_timing%' AND value LIKE '%writer_thread_cpu_time%'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='roc_compiler_pin' AND value='nightly-test-pin'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='target_profile' AND value='native-headless'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='backend' AND value='headless_stub'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='executable_name' AND value='example-app'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='app_name' AND value='example-app'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='clock_source' AND value='test-monotonic'").?);
    try std.testing.expectEqual(@as(i64, 7), queryI64(db, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='clock_resolution_ns'").?);
    try std.testing.expectEqual(@as(i64, 123456), queryI64(db, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='utc_origin_unix_ns'").?);
    try std.testing.expectEqual(@as(i64, 32), queryI64(db, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='chunk_count'").?);
    try std.testing.expectEqual(@as(i64, 4), queryI64(db, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='summary_reserve'").?);
    try std.testing.expectEqual(@as(i64, 2), queryI64(db, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='transaction_chunks'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='terminal_reserve_bytes'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='output_admission_limit_bytes'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='max_transaction_overshoot_bytes'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM runs WHERE id=1").?);
    try std.testing.expectEqual(@as(i64, 0), queryI64(db, "SELECT count(*) FROM pragma_foreign_key_check").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM recorder_health").?);
    try std.testing.expect(queryI64(db, "SELECT transactions FROM recorder_health").? >= 1);
    try std.testing.expectEqual(@as(i64, 0), queryI64(db, "SELECT omitted_events FROM recorder_health").?);
    try std.testing.expect(queryI64(db, "SELECT output_bytes FROM recorder_health").? > 0);
    try std.testing.expect(queryI64(db, "SELECT writer_active_wall_ns FROM recorder_health").? >= 0);
    try std.testing.expect(queryI64(db, "SELECT writer_idle_wall_ns FROM recorder_health").? >= 0);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT writer_cpu_ns IS NULL FROM recorder_health").?);
}

test "session refuses overwrite and an output limit still shuts down cleanly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/limited.rrstats", .{tmp.sub_path});

    var session = try Session.start(std.testing.allocator, .{
        .path = path,
        .chunk_count = 4,
        .summary_reserve = 1,
        .max_output_bytes = 1,
        .transaction_chunks = 1,
    });
    try std.testing.expect(session.recordCycle(.{
        .cycle = 1,
        .start_ns = 1,
        .duration_ns = 1,
        .update_ns = 1,
        .render_callback_ns = 0,
        .task_executor_ns = 0,
        .host_other_ns = 0,
    }));
    for (0..100_000) |_| {
        if (session.outputLimited()) break;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expect(session.outputLimited());
    _ = session.stop();

    const zpath = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(zpath);
    var db: ?*anyopaque = null;
    try std.testing.expectEqual(SQLITE_OK, rocray_sqlite_open(zpath.ptr, 2, 1000, &db));
    defer _ = rocray_sqlite_close(db);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='clean_shutdown'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='final_state' AND value='output_limit'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT output_limited FROM recorder_health").?);

    try std.testing.expectError(error.AlreadyExists, Session.start(std.testing.allocator, .{ .path = path }));
}

test "blocked writer saturation persists an explicit gap without borrowing summary reserve" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/saturation.rrstats", .{tmp.sub_path});
    var session = try Session.start(std.testing.allocator, .{
        .path = path,
        .chunk_count = 8,
        .summary_reserve = 2,
        .test_fault = .block_after_start,
    });

    const long_label = [_]u8{'x'} ** 255;
    var admitted: u64 = 0;
    while (admitted < 10_000) : (admitted += 1) {
        if (!session.recordAnnotation(.{
            .cycle = 6,
            .timestamp_ns = 6,
            .phase = 1,
            .kind = .mark,
            .name = long_label[0..],
        })) break;
    }
    try std.testing.expect(admitted > 6);
    try std.testing.expect(admitted < 10_000);
    try std.testing.expect(session.flushGaps(6, 6));
    try std.testing.expect(session.recordCycle(.{
        .cycle = 6,
        .start_ns = 6,
        .duration_ns = 1,
        .update_ns = 1,
        .render_callback_ns = 0,
        .task_executor_ns = 0,
        .host_other_ns = 0,
    }));
    session.releaseTestWriter();
    const report = session.stop();
    try std.testing.expect(report.complete);
    try std.testing.expectEqual(@as(u64, 1), report.omitted_events);

    const zpath = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(zpath);
    var db: ?*anyopaque = null;
    try std.testing.expectEqual(SQLITE_OK, rocray_sqlite_open(zpath.ptr, 2, 1000, &db));
    defer _ = rocray_sqlite_close(db);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT sum(lost_count) FROM recording_gaps").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM recording_gaps WHERE first_cycle=6 AND last_cycle=6 AND started_ns=6 AND ended_ns=6 AND producer_track='frame_thread'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT omitted_events FROM recorder_health").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM cycles WHERE cycle=6").?);
}

test "summary detail admits only summaries and rejects standard and full detail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/summary.rrstats", .{tmp.sub_path});

    var session = try Session.start(std.testing.allocator, .{
        .path = path,
        .detail = .summary,
        .chunk_count = 16,
        .summary_reserve = 2,
    });
    try std.testing.expect(!session.recordTask(.{ .cycle = 0, .timestamp_ns = 1, .kind = 0, .name = "task" }));
    try std.testing.expect(!session.recordEffect(.{ .cycle = 0, .timestamp_ns = 1, .kind = 0, .effect_id = 1, .correlation_id = 0, .duration_ns = 0, .outcome = .success, .name = "effect" }));
    try std.testing.expect(!session.recordQueue(.{ .cycle = 0, .timestamp_ns = 1, .kind = 0, .name = "queue" }));
    try std.testing.expect(!session.recordResource(.{ .cycle = 0, .timestamp_ns = 1, .kind = 0, .name = "resource" }));
    try std.testing.expect(!session.recordLatency(.{ .cycle = 0, .timestamp_ns = 1, .kind = 0, .name = "latency" }));
    try std.testing.expect(session.recordDraw(.{ .cycle = 0, .timestamp_ns = 1, .kind = 0, .name = "draw" }));
    try std.testing.expect(!session.recordAllocation(.{ .cycle = 0, .timestamp_ns = 1, .kind = 0, .name = "allocation" }));
    try std.testing.expect(session.recordGpu(.{ .cycle = 0, .timestamp_ns = 1, .kind = 0, .name = "gpu" }));
    try std.testing.expect(session.recordCallback(.{ .cycle = 0, .timestamp_ns = 1, .kind = 0, .name = "init!" }));
    _ = session.stop();

    const zpath = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(zpath);
    var db: ?*anyopaque = null;
    try std.testing.expectEqual(SQLITE_OK, rocray_sqlite_open(zpath.ptr, 2, 1000, &db));
    defer _ = rocray_sqlite_close(db);
    inline for (.{ "task_events", "hosted_effects", "queue_pressure", "resource_lifecycle", "structural_latency", "allocation_events" }) |table| {
        var sql_buffer: [96]u8 = undefined;
        const sql = try std.fmt.bufPrintZ(&sql_buffer, "SELECT count(*) FROM {s}", .{table});
        try std.testing.expectEqual(@as(i64, 0), queryI64(db, sql).?);
    }
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM draw_summaries").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM gpu_facts").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM callback_summaries").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='requested_detail' AND value='summary'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='effective_detail' AND value='summary'").?);
}

test "abrupt shutdown leaves a queryable committed prefix marked unclean" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/abrupt.rrstats", .{tmp.sub_path});
    var session = try Session.start(std.testing.allocator, .{
        .path = path,
        .chunk_count = 4,
        .summary_reserve = 1,
        .transaction_chunks = 1,
        .test_fault = .abrupt_after_first_commit,
    });
    try std.testing.expect(session.recordCycle(.{ .cycle = 41, .start_ns = 1, .duration_ns = 2, .update_ns = 1, .render_callback_ns = 1, .task_executor_ns = 0, .host_other_ns = 0 }));
    while (session.shared.accepting.load(.acquire)) std.Thread.yield() catch std.atomic.spinLoopHint();
    _ = session.stop();

    const zpath = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(zpath);
    var db: ?*anyopaque = null;
    try std.testing.expectEqual(SQLITE_OK, rocray_sqlite_open(zpath.ptr, 2, 1000, &db));
    defer _ = rocray_sqlite_close(db);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM cycles WHERE cycle=41").?);
    try std.testing.expectEqual(@as(i64, 0), queryI64(db, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='clean_shutdown'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='final_state' AND value='recording'").?);
}

test "post-start writer failure refuses recording without stopping the application" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/failed.rrstats", .{tmp.sub_path});
    var session = try Session.start(std.testing.allocator, .{
        .path = path,
        .chunk_count = 4,
        .summary_reserve = 1,
        .transaction_chunks = 1,
        .test_fault = .fail_after_first_commit,
    });
    try std.testing.expect(session.recordCycle(.{ .cycle = 1, .start_ns = 1, .duration_ns = 1, .update_ns = 1, .render_callback_ns = 0, .task_executor_ns = 0, .host_other_ns = 0 }));
    while (!session.failed()) std.Thread.yield() catch std.atomic.spinLoopHint();
    var application_progress: u32 = 0;
    application_progress += 1;
    try std.testing.expectEqual(@as(u32, 1), application_progress);
    try std.testing.expect(!session.recordCycle(.{ .cycle = 2, .start_ns = 2, .duration_ns = 1, .update_ns = 1, .render_callback_ns = 0, .task_executor_ns = 0, .host_other_ns = 0 }));
    _ = session.stop();

    const zpath = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(zpath);
    var db: ?*anyopaque = null;
    try std.testing.expectEqual(SQLITE_OK, rocray_sqlite_open(zpath.ptr, 2, 1000, &db));
    defer _ = rocray_sqlite_close(db);
    try std.testing.expectEqual(@as(i64, 0), queryI64(db, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='clean_shutdown'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='final_state' AND value='recorder_failed'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT writer_failed FROM recorder_health").?);
}

test "detail SQL preserves lifecycle saturation and structural semantics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/detail.rrstats", .{tmp.sub_path});
    var session = try Session.start(std.testing.allocator, .{ .path = path, .detail = .full, .chunk_count = 16, .summary_reserve = 2 });
    try std.testing.expect(session.recordResource(.{ .cycle = 3, .timestamp_ns = 10, .kind = 1, .subject_id = 44, .name = "texture" }));
    try std.testing.expect(session.recordResource(.{ .cycle = 4, .timestamp_ns = 25, .kind = 2, .subject_id = 44, .duration_ns = 15, .name = "texture" }));
    try std.testing.expect(session.recordAllocation(.{ .cycle = 3, .timestamp_ns = 11, .kind = 0, .subject_id = 70, .value_a = 64, .name = "alloc" }));
    try std.testing.expect(session.recordAllocation(.{ .cycle = 3, .timestamp_ns = 12, .kind = 2, .subject_id = 70, .value_a = 128, .value_b = 64, .name = "realloc_move" }));
    try std.testing.expect(session.recordAllocation(.{ .cycle = 4, .timestamp_ns = 26, .kind = 1, .subject_id = 70, .value_a = 128, .name = "free" }));
    try std.testing.expect(session.recordQueue(.{ .cycle = 3, .timestamp_ns = 13, .kind = 2, .subject_id = 8, .parent_id = 8, .duration_ns = 9, .value_a = 8, .value_b = 1, .name = "cmd children" }));
    try std.testing.expect(session.recordLatency(.{ .cycle = 4, .timestamp_ns = 30, .kind = 1, .subject_id = 91, .duration_ns = 20, .name = "input_to_presentation" }));
    _ = session.stop();

    const zpath = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(zpath);
    var db: ?*anyopaque = null;
    try std.testing.expectEqual(SQLITE_OK, rocray_sqlite_open(zpath.ptr, 2, 1000, &db));
    defer _ = rocray_sqlite_close(db);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM resource_lifecycle a JOIN resource_lifecycle b USING(subject_id) WHERE a.kind=1 AND b.kind=2 AND b.duration_ns=15").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM allocation_events a JOIN allocation_events r USING(subject_id) JOIN allocation_events f USING(subject_id) WHERE a.kind=0 AND r.kind=2 AND f.kind=1 AND a.value_a=64 AND r.value_a=128 AND r.value_b=64 AND f.value_a=128").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM queue_pressure WHERE kind=2 AND value_a=parent_id AND duration_ns=9").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM structural_latency WHERE kind=1 AND subject_id=91 AND duration_ns=20 AND name='input_to_presentation'").?);
}

test "stop flushes tail loss and returns persisted terminal facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/tail-gap.rrstats", .{tmp.sub_path});
    var session = try Session.start(std.testing.allocator, .{
        .path = path,
        .chunk_count = 8,
        .summary_reserve = 2,
    });
    session.noteLoss(.hosted_effect, 3);
    session.setApplicationOutcome("success");
    const report = session.stop();
    try std.testing.expect(report.complete);
    try std.testing.expect(!report.failed);
    try std.testing.expect(!report.output_limited);
    try std.testing.expectEqual(@as(u64, 3), report.omitted_events);

    const zpath = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(zpath);
    var db: ?*anyopaque = null;
    try std.testing.expectEqual(SQLITE_OK, rocray_sqlite_open(zpath.ptr, 2, 1000, &db));
    defer _ = rocray_sqlite_close(db);
    try std.testing.expectEqual(@as(i64, 3), queryI64(db, "SELECT lost_count FROM recording_gaps WHERE family=2").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM recording_gaps WHERE first_cycle=last_cycle AND started_ns=ended_ns AND producer_track='frame_thread'").?);
    try std.testing.expectEqual(@as(i64, 3), queryI64(db, "SELECT omitted_events FROM recorder_health").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='application_outcome' AND value='success'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='drain_duration_ns'").?);
}

test "unresolved run relationship prevents a clean finalization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/invalid-parent.rrstats", .{tmp.sub_path});
    var session = try Session.start(std.testing.allocator, .{
        .path = path,
        .chunk_count = 8,
        .summary_reserve = 2,
        .test_fault = .unresolved_relationship,
    });
    try std.testing.expect(session.recordCycle(.{ .cycle = 0, .start_ns = 0, .duration_ns = 1, .update_ns = 1, .render_callback_ns = 0, .task_executor_ns = 0, .host_other_ns = 0 }));
    const report = session.stop();
    try std.testing.expect(report.failed);
    try std.testing.expect(!report.complete);

    const zpath = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(zpath);
    var db: ?*anyopaque = null;
    try std.testing.expectEqual(SQLITE_OK, rocray_sqlite_open(zpath.ptr, 2, 1000, &db));
    defer _ = rocray_sqlite_close(db);
    try std.testing.expect(!foreignKeysValid(db));
    try std.testing.expectEqual(@as(i64, 0), queryI64(db, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='clean_shutdown'").?);
    try std.testing.expectEqual(@as(i64, 1), queryI64(db, "SELECT count(*) FROM metadata WHERE key='final_state' AND value='recorder_failed'").?);
}

fn queryI64(db: ?*anyopaque, sql: [*:0]const u8) ?i64 {
    const stmt = prepare(db, sql) orelse return null;
    defer _ = rocray_sqlite_finalize(stmt);
    if (rocray_sqlite_step(stmt) != 100) return null; // SQLITE_ROW
    return rocray_sqlite_column_int64(stmt, 0);
}
