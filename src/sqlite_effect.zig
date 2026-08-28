//! The `Sqlite` effects: connections, prepared statements, and one query at a
//! time per connection.
//!
//! `host_native.zig` owns the phase guard and the Roc entry points; this file
//! owns the connections, the statement heap, the encoding of a result, and the
//! blocking work. Nothing here touches raylib.
//!
//! ## Threads
//!
//! SQLite itself runs on zio's blocking pool, never on the frame thread. The
//! calling coroutine parks in `join()`, so inside `Task.spawn!` the frame loop
//! keeps drawing while a query runs, and inside `init!` the frame thread waits.
//! The worker sees only host-owned bytes: bindings and SQL are copied out of
//! their Roc values before the job is spawned, and rows are encoded into plain
//! host buffers that become Roc values back on the frame thread. No Roc
//! allocator is ever reachable from a worker.
//!
//! One connection admits one operation at a time, through its own mutex. A
//! second task asking the same connection for work waits for the first to
//! finish -- delayed, never refused -- which is also what makes `close!` safe
//! against a query already in flight.
//!
//! ## Shutdown
//!
//! zio's `cancel` on a blocking task only sets a flag, and `join()` shields the
//! wait, so a query already running cannot be cancelled by the runtime: without
//! help, shutdown would block until it finished. `interruptAll` is that help.
//! It calls `sqlite3_interrupt` on every connection with an operation in
//! flight, which is safe from another thread and makes the step loop return
//! `SQLITE_INTERRUPT` promptly. The worker unwinds, the task resumes on the
//! cancelled path, and its result is dropped.
//!
//! ## Limits
//!
//! Eight connections and sixty-four statements, both fixed-capacity typed ARC
//! heaps. One result may hold a million cells and, by default, sixteen
//! megabytes of text and blob payload; the payload cap belongs to the
//! connection and is set when it is opened. Both caps are refusals rather than
//! truncations, because a result cut short decodes into wrong data instead of
//! into an error.

const std = @import("std");
const zio = @import("zio");

const abi = @import("roc_platform_abi.zig");
const host_resource = @import("host_resource.zig");

const RocHost = abi.RocHost;

/// Connections open at once. A `Db` costs a file descriptor and a page cache,
/// so this is deliberately small; an app that wants more should share one.
pub const max_connections: usize = 8;

/// Prepared statements alive at once, across every connection.
pub const max_statements: usize = 64;

/// Cells one query may return. Guards the `cells` list, which is the part of a
/// result proportional to rows times columns rather than to payload bytes.
pub const max_result_cells: u64 = 1_000_000;

/// SQLite result codes this file needs by name. From sqlite3.h, whose numbering
/// is a compatibility guarantee.
const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;
const SQLITE_MISUSE: c_int = 21;
const SQLITE_RANGE: c_int = 25;

/// Column types, as SQLite numbers them. Mirrored by `cell_*` in
/// `platform/Sqlite.roc`.
const COLUMN_INTEGER: c_int = 1;
const COLUMN_FLOAT: c_int = 2;
const COLUMN_TEXT: c_int = 3;
const COLUMN_BLOB: c_int = 4;
const COLUMN_NULL: c_int = 5;

/// Refusals the host makes on its own behalf. Negative because SQLite's own
/// result codes never are, so one number never means two things across the
/// boundary. Mirrored by `err_*` in `platform/Sqlite.roc`.
pub const ERR_TOO_MANY_CONNECTIONS: i64 = -1;

/// Every statement slot is taken.
pub const ERR_TOO_MANY_STATEMENTS: i64 = -2;

/// The result passed a cell or payload cap, and was discarded rather than cut.
pub const ERR_RESULT_TOO_LARGE: i64 = -3;

/// One query string held more than one statement.
pub const ERR_MULTIPLE_STATEMENTS: i64 = -4;

extern fn rocray_sqlite_init() c_int;
extern fn rocray_sqlite_shutdown() void;
extern fn rocray_sqlite_open(path: [*:0]const u8, mode: c_int, busy_timeout_ms: c_int, out_db: *?*anyopaque) c_int;
extern fn rocray_sqlite_close(db: ?*anyopaque) c_int;
extern fn rocray_sqlite_interrupt(db: ?*anyopaque) void;
extern fn rocray_sqlite_errmsg(db: ?*anyopaque) ?[*:0]const u8;
extern fn rocray_sqlite_extended_errcode(db: ?*anyopaque) c_int;
extern fn rocray_sqlite_changes(db: ?*anyopaque) i64;
extern fn rocray_sqlite_last_insert_rowid(db: ?*anyopaque) i64;
extern fn rocray_sqlite_prepare(db: ?*anyopaque, sql: [*:0]const u8, out_stmt: *?*anyopaque, out_tail_used: *c_int) c_int;
extern fn rocray_sqlite_finalize(stmt: ?*anyopaque) c_int;
extern fn rocray_sqlite_reset(stmt: ?*anyopaque) c_int;
extern fn rocray_sqlite_clear_bindings(stmt: ?*anyopaque) c_int;
extern fn rocray_sqlite_bind_index(stmt: ?*anyopaque, name: [*:0]const u8) c_int;
extern fn rocray_sqlite_bind_null(stmt: ?*anyopaque, index: c_int) c_int;
extern fn rocray_sqlite_bind_int64(stmt: ?*anyopaque, index: c_int, value: i64) c_int;
extern fn rocray_sqlite_bind_double(stmt: ?*anyopaque, index: c_int, value: f64) c_int;
extern fn rocray_sqlite_bind_text(stmt: ?*anyopaque, index: c_int, bytes: [*]const u8, len: i64) c_int;
extern fn rocray_sqlite_bind_blob(stmt: ?*anyopaque, index: c_int, bytes: *const anyopaque, len: i64) c_int;
extern fn rocray_sqlite_step(stmt: ?*anyopaque) c_int;
extern fn rocray_sqlite_column_count(stmt: ?*anyopaque) c_int;
extern fn rocray_sqlite_column_name(stmt: ?*anyopaque, index: c_int) ?[*:0]const u8;
extern fn rocray_sqlite_column_type(stmt: ?*anyopaque, index: c_int) c_int;
extern fn rocray_sqlite_column_int64(stmt: ?*anyopaque, index: c_int) i64;
extern fn rocray_sqlite_column_double(stmt: ?*anyopaque, index: c_int) f64;
extern fn rocray_sqlite_column_blob(stmt: ?*anyopaque, index: c_int) ?*const anyopaque;
extern fn rocray_sqlite_column_text(stmt: ?*anyopaque, index: c_int) ?*const anyopaque;
extern fn rocray_sqlite_column_bytes(stmt: ?*anyopaque, index: c_int) c_int;
extern fn rocray_sqlite_exec(db: ?*anyopaque, sql: [*:0]const u8) c_int;

/// Admits one operation per connection at a time.
///
/// Not `std.Io.Mutex`: locking one needs an `Io`, and a worker on the blocking
/// pool is an ordinary OS thread outside any coroutine, with no business
/// touching zio's. Yield-spinning is the honest cost of that -- a second task
/// querying the same connection occupies a pool thread until the first
/// finishes. Contention on one connection is the uncommon case, the pool has
/// other threads, and the frame thread is never the one spinning.
///
/// It is needed even though serialized threading mode already serializes
/// SQLite's own state: two threads sharing one statement would still interleave
/// their bindings and steps into each other's results, and `sqlite3_close_v2`
/// must not run while another thread is inside `sqlite3_step`.
const ConnectionLock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(self: *ConnectionLock) void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *ConnectionLock) void {
        self.held.store(false, .release);
    }
};

/// One open connection.
///
/// `mutex` admits one operation at a time; `in_flight` is what shutdown reads
/// to decide whether this connection needs interrupting. `db` becomes null
/// after an explicit `close!`, so a later call through the same handle is a
/// misuse rather than a call into freed memory.
pub const DbResource = struct {
    db: ?*anyopaque,
    mutex: ConnectionLock,
    in_flight: bool,
    max_result_bytes: u64,
};

/// One prepared statement, and the connection it belongs to.
///
/// The token rather than a pointer: if the connection's slot has been reused
/// the generation will not match, so the statement resolves to nothing instead
/// of reaching a different database.
pub const StmtResource = struct {
    stmt: ?*anyopaque,
    db_token: u64,
};

fn writeU64Token(payload: *u64, token: u64) void {
    payload.* = token;
}

fn readU64Token(payload: *const u64) u64 {
    return payload.*;
}

fn destroyDb(resource: *DbResource) void {
    if (resource.db) |db| {
        _ = rocray_sqlite_close(db);
        resource.db = null;
    }
}

fn destroyStmt(resource: *StmtResource) void {
    if (resource.stmt) |stmt| {
        _ = rocray_sqlite_finalize(stmt);
        resource.stmt = null;
    }
}

/// The connection heap's type. Its capacity is the connection bound.
pub const DbHeap = host_resource.HostResourceHeap(u64, DbResource, max_connections, .sqlite_db, writeU64Token, readU64Token, destroyDb);
/// The statement heap's type. Its capacity is the statement bound.
pub const StmtHeap = host_resource.HostResourceHeap(u64, StmtResource, max_statements, .sqlite_stmt, writeU64Token, readU64Token, destroyStmt);

/// Every open connection. Registered with `host_native.zig`'s dealloc routing,
/// retirement drain, and shutdown.
pub var db_heap: DbHeap = .{};

/// Every prepared statement, drained before connections so a connection does
/// not linger as a zombie waiting on one.
pub var stmt_heap: StmtHeap = .{};

/// Set once, so a second `sqlite3_initialize` is not paid per connection.
var initialized: bool = false;

/// Bring SQLite up. Idempotent, and cheap after the first call.
pub fn initialize() bool {
    if (initialized) return true;
    if (rocray_sqlite_init() != SQLITE_OK) return false;
    initialized = true;
    return true;
}

/// Release SQLite's own global state, after every connection is closed.
pub fn shutdown() void {
    if (!initialized) return;
    rocray_sqlite_shutdown();
    initialized = false;
}

/// Interrupt every query still running, so shutdown does not wait on one.
///
/// Safe to call from the frame thread while workers are inside SQLite: this is
/// exactly the use `sqlite3_interrupt` is documented for, and serialized
/// threading mode is what makes it safe without further argument.
pub fn interruptAll() void {
    const Interrupter = struct {
        fn call(resource: *DbResource) void {
            if (resource.in_flight) {
                if (resource.db) |db| rocray_sqlite_interrupt(db);
            }
        }
    };
    db_heap.forEach(Interrupter.call);
}

/// One binding, copied out of Roc memory so a worker can read it.
const BindingBytes = struct {
    name: [:0]const u8,
    kind: u8,
    integer: i64,
    real: f64,
    bytes: []const u8,
};

/// One encoded cell. Field-for-field the record `Sqlite` decodes.
const Cell = abi.HostABISqlite_run_stmtCells;

/// What a worker filled in, and what the frame thread turns into Roc values.
const Result = struct {
    allocator: std.mem.Allocator,
    err: i64 = 0,
    message: std.ArrayList(u8),
    names: std.ArrayList(u8),
    cells: std.ArrayList(Cell),
    payload: std.ArrayList(u8),
    ncols: u64 = 0,
    row_count: u64 = 0,
    changes: i64 = 0,
    last_insert_rowid: i64 = 0,

    fn init(allocator: std.mem.Allocator) Result {
        return .{
            .allocator = allocator,
            .message = .empty,
            .names = .empty,
            .cells = .empty,
            .payload = .empty,
        };
    }

    fn deinit(self: *Result) void {
        self.message.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.cells.deinit(self.allocator);
        self.payload.deinit(self.allocator);
    }

    /// Record a failure, discarding whatever partial rows were collected.
    ///
    /// Partial rows are dropped rather than delivered because a result cut
    /// short is wrong data, not an error an app can see.
    fn fail(self: *Result, code: i64, db: ?*anyopaque) void {
        self.err = code;
        self.names.clearRetainingCapacity();
        self.cells.clearRetainingCapacity();
        self.payload.clearRetainingCapacity();
        self.ncols = 0;
        self.row_count = 0;
        if (db) |handle| {
            if (rocray_sqlite_errmsg(handle)) |text| {
                self.message.appendSlice(self.allocator, std.mem.span(text)) catch {};
            }
        }
    }

    fn failWith(self: *Result, code: i64, text: []const u8) void {
        self.err = code;
        self.names.clearRetainingCapacity();
        self.cells.clearRetainingCapacity();
        self.payload.clearRetainingCapacity();
        self.ncols = 0;
        self.row_count = 0;
        self.message.clearRetainingCapacity();
        self.message.appendSlice(self.allocator, text) catch {};
    }
};

/// Everything one blocking job needs, and everything it produced.
const Job = struct {
    resource: *DbResource,
    /// Set for `run_stmt!`: an already-compiled statement the job must not
    /// finalize, only reset.
    borrowed_stmt: ?*anyopaque,
    /// Set for `run_once!` and `exec_script!`: SQL the job compiles itself.
    sql: ?[:0]const u8,
    bindings: []const BindingBytes,
    script: bool,
    result: *Result,
};

/// Run one job on a blocking-pool thread.
fn runBlocking(job: *Job) void {
    const resource = job.resource;
    resource.mutex.lock();
    defer resource.mutex.unlock();

    const db = resource.db orelse {
        job.result.failWith(@intCast(SQLITE_MISUSE), "database handle is closed");
        return;
    };

    resource.in_flight = true;
    defer resource.in_flight = false;

    if (job.script) {
        const sql = job.sql.?;
        if (rocray_sqlite_exec(db, sql.ptr) != SQLITE_OK) {
            job.result.fail(@intCast(rocray_sqlite_extended_errcode(db)), db);
        }
        return;
    }

    var owned_stmt: ?*anyopaque = null;
    defer if (owned_stmt) |stmt| {
        _ = rocray_sqlite_finalize(stmt);
    };

    const stmt = job.borrowed_stmt orelse blk: {
        const sql = job.sql.?;
        var compiled: ?*anyopaque = null;
        var tail_used: c_int = 0;
        if (rocray_sqlite_prepare(db, sql.ptr, &compiled, &tail_used) != SQLITE_OK) {
            job.result.fail(@intCast(rocray_sqlite_extended_errcode(db)), db);
            if (compiled) |partial| _ = rocray_sqlite_finalize(partial);
            return;
        }
        if (compiled == null) {
            // An empty or comment-only statement compiles to nothing. Treat it
            // as a query that returned no rows rather than as an error.
            return;
        }
        if (tail_used != 0) {
            _ = rocray_sqlite_finalize(compiled);
            job.result.failWith(ERR_MULTIPLE_STATEMENTS, "more than one statement in this query");
            return;
        }
        owned_stmt = compiled;
        break :blk compiled;
    };

    // A borrowed statement carries whatever the previous run left bound, so
    // clear it: a binding list that names fewer parameters this time must not
    // silently reuse the last run's values.
    if (job.borrowed_stmt != null) {
        _ = rocray_sqlite_clear_bindings(stmt);
        _ = rocray_sqlite_reset(stmt);
    }
    defer if (job.borrowed_stmt != null) {
        _ = rocray_sqlite_reset(stmt);
    };

    if (!bindAll(job, stmt, db)) return;
    collectRows(job, stmt, db);
}

/// Bind every parameter, refusing a name the statement does not have.
///
/// A name that binds nothing is `SQLITE_RANGE` rather than a no-op: a typo in a
/// parameter name would otherwise run the query against a NULL nobody asked
/// for, which reads as an empty result instead of as a mistake.
fn bindAll(job: *Job, stmt: ?*anyopaque, db: ?*anyopaque) bool {
    for (job.bindings) |binding| {
        const index = rocray_sqlite_bind_index(stmt, binding.name.ptr);
        if (index == 0) {
            job.result.failWith(@intCast(SQLITE_RANGE), "no such parameter in this statement");
            return false;
        }
        const rc = switch (binding.kind) {
            1 => rocray_sqlite_bind_int64(stmt, index, binding.integer),
            2 => rocray_sqlite_bind_double(stmt, index, binding.real),
            3 => rocray_sqlite_bind_text(stmt, index, binding.bytes.ptr, @intCast(binding.bytes.len)),
            4 => if (binding.bytes.len == 0)
                rocray_sqlite_bind_blob(stmt, index, @ptrCast(&empty_blob), 0)
            else
                rocray_sqlite_bind_blob(stmt, index, @ptrCast(binding.bytes.ptr), @intCast(binding.bytes.len)),
            else => rocray_sqlite_bind_null(stmt, index),
        };
        if (rc != SQLITE_OK) {
            job.result.fail(@intCast(rocray_sqlite_extended_errcode(db)), db);
            return false;
        }
    }
    return true;
}

/// A zero-length blob still needs a non-null pointer to bind.
var empty_blob: u8 = 0;

/// Step the statement to completion, encoding every row.
fn collectRows(job: *Job, stmt: ?*anyopaque, db: ?*anyopaque) void {
    const result = job.result;
    const ncols: usize = @intCast(@max(rocray_sqlite_column_count(stmt), 0));
    result.ncols = ncols;

    var wrote_names = false;
    while (true) {
        const rc = rocray_sqlite_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) {
            result.fail(@intCast(rocray_sqlite_extended_errcode(db)), db);
            return;
        }

        // Column names come from the first row rather than from the prepared
        // statement, so a query whose result set is empty carries no names and
        // costs nothing.
        if (!wrote_names) {
            var column: usize = 0;
            while (column < ncols) : (column += 1) {
                const name = rocray_sqlite_column_name(stmt, @intCast(column));
                const text = if (name) |ptr| std.mem.span(ptr) else "";
                result.names.appendSlice(result.allocator, text) catch return outOfMemory(result);
                result.names.append(result.allocator, 0) catch return outOfMemory(result);
            }
            wrote_names = true;
        }

        if (result.cells.items.len + ncols > max_result_cells) {
            result.failWith(ERR_RESULT_TOO_LARGE, "query returned more cells than the platform will deliver");
            return;
        }

        var column: usize = 0;
        while (column < ncols) : (column += 1) {
            const cell = encodeCell(result, stmt, @intCast(column), job.resource.max_result_bytes) orelse return;
            result.cells.append(result.allocator, cell) catch return outOfMemory(result);
        }
        result.row_count += 1;
    }

    result.changes = rocray_sqlite_changes(db);
    result.last_insert_rowid = rocray_sqlite_last_insert_rowid(db);
}

/// Encode one column, copying text and blob bytes into the shared payload.
///
/// Returns null when the payload cap is reached, having already recorded the
/// refusal.
fn encodeCell(result: *Result, stmt: ?*anyopaque, column: c_int, max_payload: u64) ?Cell {
    const kind = rocray_sqlite_column_type(stmt, column);
    return switch (kind) {
        COLUMN_INTEGER => .{
            .kind = 1,
            .integer = rocray_sqlite_column_int64(stmt, column),
            .real = 0,
            .start = 0,
            .len = 0,
        },
        COLUMN_FLOAT => .{
            .kind = 2,
            .integer = 0,
            .real = rocray_sqlite_column_double(stmt, column),
            .start = 0,
            .len = 0,
        },
        COLUMN_TEXT, COLUMN_BLOB => blk: {
            const raw = if (kind == COLUMN_TEXT)
                rocray_sqlite_column_text(stmt, column)
            else
                rocray_sqlite_column_blob(stmt, column);
            const size: usize = @intCast(@max(rocray_sqlite_column_bytes(stmt, column), 0));
            if (max_payload != 0 and result.payload.items.len + size > max_payload) {
                result.failWith(ERR_RESULT_TOO_LARGE, "query returned more text and blob bytes than this connection will deliver");
                break :blk null;
            }
            const start = result.payload.items.len;
            if (size != 0) {
                const bytes: [*]const u8 = @ptrCast(raw.?);
                result.payload.appendSlice(result.allocator, bytes[0..size]) catch {
                    outOfMemory(result);
                    break :blk null;
                };
            }
            break :blk .{
                .kind = if (kind == COLUMN_TEXT) 3 else 4,
                .integer = 0,
                .real = 0,
                .start = start,
                .len = size,
            };
        },
        COLUMN_NULL => .{ .kind = 5, .integer = 0, .real = 0, .start = 0, .len = 0 },
        // SQLite defines no sixth type; answering NULL keeps this total.
        else => .{ .kind = 5, .integer = 0, .real = 0, .start = 0, .len = 0 },
    };
}

fn outOfMemory(result: *Result) void {
    result.failWith(ERR_RESULT_TOO_LARGE, "not enough memory to hold this result");
}

/// The allocator every worker buffer uses.
///
/// Deliberately not the Roc host's: that one may be wrapped in the allocation
/// meter, whose counters assume everything Roc allocates runs on the frame
/// thread. These buffers are host-owned, never become Roc allocations, and are
/// freed before the effect returns.
fn workerAllocator() std.mem.Allocator {
    return std.heap.smp_allocator;
}

/// Run a job, on the blocking pool when there is a runtime to spawn on.
fn dispatch(rt: ?*zio.Runtime, job: *Job) void {
    if (rt) |runtime| {
        var blocking = runtime.spawnBlocking(runBlocking, .{job}) catch {
            runBlocking(job);
            return;
        };
        blocking.join();
        return;
    }
    runBlocking(job);
}

/// The token handed back when there is no resource to hand back.
///
/// Roc still builds a `Db` or `Stmt` from it and later drops it, so it needs a
/// refcount word in front like any other handle. Token zero decodes to nothing,
/// which is what makes every call through it a misuse rather than a wild
/// pointer.
const InvalidHandleBox = extern struct {
    refcount: isize = 0,
    token: u64 = 0,
};

var invalid_handle_box: InvalidHandleBox = .{};

fn invalidHandle() *u64 {
    return &invalid_handle_box.token;
}

/// Copy a Roc string into a NUL-terminated host buffer.
///
/// SQLite's C interface wants a terminator a `Str` does not carry, and the copy
/// also means the worker is not reading Roc memory while the frame thread runs.
fn dupeZ(allocator: std.mem.Allocator, text: abi.RocStr) ?[:0]const u8 {
    return allocator.dupeZ(u8, text.asSlice()) catch null;
}

/// Copy every binding out of Roc memory, so a worker can read them.
fn copyBindings(
    allocator: std.mem.Allocator,
    list: abi.RocList(abi.HostABISqlite_run_stmtArg1),
) ?[]BindingBytes {
    const items = list.items();
    const copied = allocator.alloc(BindingBytes, items.len) catch return null;
    var filled: usize = 0;
    errdefer freeBindings(allocator, copied[0..filled]);
    for (items) |binding| {
        const name = allocator.dupeZ(u8, binding.name.asSlice()) catch {
            freeBindings(allocator, copied[0..filled]);
            allocator.free(copied);
            return null;
        };
        const payload: []const u8 = switch (binding.kind) {
            3 => binding.text.asSlice(),
            4 => binding.blob.items(),
            else => &.{},
        };
        const bytes = allocator.dupe(u8, payload) catch {
            allocator.free(name);
            freeBindings(allocator, copied[0..filled]);
            allocator.free(copied);
            return null;
        };
        copied[filled] = .{
            .name = name,
            .kind = binding.kind,
            .integer = binding.integer,
            .real = binding.real,
            .bytes = bytes,
        };
        filled += 1;
    }
    return copied;
}

fn freeBindings(allocator: std.mem.Allocator, bindings: []const BindingBytes) void {
    for (bindings) |binding| {
        allocator.free(binding.name);
        allocator.free(binding.bytes);
    }
}

/// Turn a worker's buffers into the Roc record the effect answers with.
///
/// Every list is copied into a fresh Roc allocation rather than moved: the
/// worker's buffers belong to the worker allocator, and a result is bounded, so
/// the copy is paid once against a cap the app already agreed to.
fn toRocQuery(comptime Record: type, roc_host: *RocHost, result: *const Result) Record {
    return .{
        .err = result.err,
        .message = abi.RocStr.fromSlice(result.message.items, roc_host),
        .names = abi.RocListWith(u8, false).fromSlice(result.names.items, roc_host),
        .ncols = result.ncols,
        .row_count = result.row_count,
        .cells = abi.RocListWith(Cell, false).fromSlice(result.cells.items, roc_host),
        .payload = abi.RocListWith(u8, false).fromSlice(result.payload.items, roc_host),
        .changes = result.changes,
        .last_insert_rowid = result.last_insert_rowid,
    };
}

fn toRocStatus(comptime Record: type, roc_host: *RocHost, result: *const Result) Record {
    return .{
        .err = result.err,
        .message = abi.RocStr.fromSlice(result.message.items, roc_host),
    };
}

/// A result that failed before any work was dispatched.
fn immediateQuery(comptime Record: type, roc_host: *RocHost, code: i64, text: []const u8) Record {
    return .{
        .err = code,
        .message = abi.RocStr.fromSlice(text, roc_host),
        .names = abi.RocListWith(u8, false).empty(),
        .ncols = 0,
        .row_count = 0,
        .cells = abi.RocListWith(Cell, false).empty(),
        .payload = abi.RocListWith(u8, false).empty(),
        .changes = 0,
        .last_insert_rowid = 0,
    };
}

/// `Sqlite.Db.open_with!`: open or create a database.
pub fn open(
    roc_host: *RocHost,
    rt: ?*zio.Runtime,
    path_arg: abi.RocStr,
    mode: u8,
    busy_timeout_ms: u64,
    max_result_bytes: u64,
) abi.HostABISqlite_open {
    _ = rt;
    const allocator = workerAllocator();

    if (!initialize()) {
        return .{
            .err = @intCast(SQLITE_MISUSE),
            .message = abi.RocStr.fromSlice("SQLite could not be initialized", roc_host),
            .db = invalidHandle(),
        };
    }

    const path = dupeZ(allocator, path_arg) orelse return .{
        .err = @intCast(SQLITE_MISUSE),
        .message = abi.RocStr.fromSlice("not enough memory to open this database", roc_host),
        .db = invalidHandle(),
    };
    defer allocator.free(path);

    var handle: ?*anyopaque = null;
    const rc = rocray_sqlite_open(path.ptr, @intCast(mode), @intCast(@min(busy_timeout_ms, std.math.maxInt(c_int))), &handle);
    if (rc != SQLITE_OK) {
        var message = abi.RocStr.empty();
        if (rocray_sqlite_errmsg(handle)) |text| {
            message = abi.RocStr.fromSlice(std.mem.span(text), roc_host);
        }
        // sqlite3_open_v2 hands back a handle even when it failed, so the
        // message could be read off it; it still has to be closed.
        if (handle) |failed| _ = rocray_sqlite_close(failed);
        return .{ .err = @intCast(rc), .message = message, .db = invalidHandle() };
    }

    const stored = db_heap.insert(0, .{
        .db = handle,
        .mutex = .{},
        .in_flight = false,
        .max_result_bytes = max_result_bytes,
    }) orelse {
        _ = rocray_sqlite_close(handle);
        return .{
            .err = ERR_TOO_MANY_CONNECTIONS,
            .message = abi.RocStr.fromSlice("too many open database connections", roc_host),
            .db = invalidHandle(),
        };
    };

    return .{ .err = 0, .message = abi.RocStr.empty(), .db = stored };
}

/// `Sqlite.Db.close!`: close now rather than at the final handle release.
pub fn close(
    roc_host: *RocHost,
    rt: ?*zio.Runtime,
    db_arg: *u64,
) abi.HostABISqlite_close {
    const resource = db_heap.get(db_arg.*) orelse return .{
        .err = @intCast(SQLITE_MISUSE),
        .message = abi.RocStr.fromSlice("database handle is closed", roc_host),
    };

    var result = Result.init(workerAllocator());
    defer result.deinit();

    // Closing takes the connection's mutex like any other operation, so a
    // query already in flight finishes first rather than having its database
    // freed underneath it. That wait belongs on the pool, not on the frame.
    var job = Job{
        .resource = resource,
        .borrowed_stmt = null,
        .sql = null,
        .bindings = &.{},
        .script = false,
        .result = &result,
    };
    const Closer = struct {
        fn run(inner: *Job) void {
            inner.resource.mutex.lock();
            defer inner.resource.mutex.unlock();
            const db = inner.resource.db orelse return;
            const rc = rocray_sqlite_close(db);
            inner.resource.db = null;
            if (rc != SQLITE_OK) inner.result.err = @intCast(rc);
        }
    };
    if (rt) |runtime| {
        var blocking = runtime.spawnBlocking(Closer.run, .{&job}) catch {
            Closer.run(&job);
            return toRocStatus(abi.HostABISqlite_close, roc_host, &result);
        };
        blocking.join();
    } else {
        Closer.run(&job);
    }

    return toRocStatus(abi.HostABISqlite_close, roc_host, &result);
}

/// `Sqlite.prepare!`: compile one statement for reuse.
pub fn prepare(
    roc_host: *RocHost,
    rt: ?*zio.Runtime,
    db_arg: *u64,
    sql_arg: abi.RocStr,
) abi.HostABISqlite_prepare {
    _ = rt;
    const allocator = workerAllocator();

    const resource = db_heap.get(db_arg.*) orelse return .{
        .err = @intCast(SQLITE_MISUSE),
        .message = abi.RocStr.fromSlice("database handle is closed", roc_host),
        .stmt = invalidHandle(),
    };
    const db = resource.db orelse return .{
        .err = @intCast(SQLITE_MISUSE),
        .message = abi.RocStr.fromSlice("database handle is closed", roc_host),
        .stmt = invalidHandle(),
    };

    const sql = dupeZ(allocator, sql_arg) orelse return .{
        .err = @intCast(SQLITE_MISUSE),
        .message = abi.RocStr.fromSlice("not enough memory to prepare this statement", roc_host),
        .stmt = invalidHandle(),
    };
    defer allocator.free(sql);

    // Compiling parses SQL and reads the schema; it does not run the statement,
    // so it stays on the calling thread under the connection's mutex rather
    // than paying for a pool round trip.
    resource.mutex.lock();
    defer resource.mutex.unlock();

    var compiled: ?*anyopaque = null;
    var tail_used: c_int = 0;
    const rc = rocray_sqlite_prepare(db, sql.ptr, &compiled, &tail_used);
    if (rc != SQLITE_OK) {
        var message = abi.RocStr.empty();
        if (rocray_sqlite_errmsg(db)) |text| {
            message = abi.RocStr.fromSlice(std.mem.span(text), roc_host);
        }
        if (compiled) |partial| _ = rocray_sqlite_finalize(partial);
        return .{ .err = @intCast(rocray_sqlite_extended_errcode(db)), .message = message, .stmt = invalidHandle() };
    }
    if (tail_used != 0) {
        if (compiled) |extra| _ = rocray_sqlite_finalize(extra);
        return .{
            .err = ERR_MULTIPLE_STATEMENTS,
            .message = abi.RocStr.fromSlice("more than one statement in this query", roc_host),
            .stmt = invalidHandle(),
        };
    }

    const stored = stmt_heap.insert(0, .{ .stmt = compiled, .db_token = db_arg.* }) orelse {
        if (compiled) |rejected| _ = rocray_sqlite_finalize(rejected);
        return .{
            .err = ERR_TOO_MANY_STATEMENTS,
            .message = abi.RocStr.fromSlice("too many prepared statements", roc_host),
            .stmt = invalidHandle(),
        };
    };

    return .{ .err = 0, .message = abi.RocStr.empty(), .stmt = stored };
}

/// `Stmt.execute!` / `Stmt.query!`: run an already-compiled statement.
pub fn runStmt(
    roc_host: *RocHost,
    rt: ?*zio.Runtime,
    stmt_arg: *u64,
    bindings_arg: abi.RocList(abi.HostABISqlite_run_stmtArg1),
) abi.HostABISqlite_run_stmt {
    const Record = abi.HostABISqlite_run_stmt;
    const allocator = workerAllocator();

    const stmt_resource = stmt_heap.get(stmt_arg.*) orelse
        return immediateQuery(Record, roc_host, @intCast(SQLITE_MISUSE), "statement handle is closed");
    const stmt = stmt_resource.stmt orelse
        return immediateQuery(Record, roc_host, @intCast(SQLITE_MISUSE), "statement handle is closed");
    const resource = db_heap.get(stmt_resource.db_token) orelse
        return immediateQuery(Record, roc_host, @intCast(SQLITE_MISUSE), "database handle is closed");

    const bindings = copyBindings(allocator, bindings_arg) orelse
        return immediateQuery(Record, roc_host, @intCast(SQLITE_MISUSE), "not enough memory to bind this statement");
    defer {
        freeBindings(allocator, bindings);
        allocator.free(bindings);
    }

    var result = Result.init(allocator);
    defer result.deinit();
    var job = Job{
        .resource = resource,
        .borrowed_stmt = stmt,
        .sql = null,
        .bindings = bindings,
        .script = false,
        .result = &result,
    };
    dispatch(rt, &job);
    return toRocQuery(Record, roc_host, &result);
}

/// `Sqlite.execute!` / `Sqlite.query!`: compile, run and finalize in one call.
pub fn runOnce(
    roc_host: *RocHost,
    rt: ?*zio.Runtime,
    db_arg: *u64,
    sql_arg: abi.RocStr,
    bindings_arg: abi.RocList(abi.HostABISqlite_run_stmtArg1),
) abi.HostABISqlite_run_once {
    const Record = abi.HostABISqlite_run_once;
    const allocator = workerAllocator();

    const resource = db_heap.get(db_arg.*) orelse
        return immediateQuery(Record, roc_host, @intCast(SQLITE_MISUSE), "database handle is closed");

    const sql = dupeZ(allocator, sql_arg) orelse
        return immediateQuery(Record, roc_host, @intCast(SQLITE_MISUSE), "not enough memory to run this query");
    defer allocator.free(sql);

    const bindings = copyBindings(allocator, bindings_arg) orelse
        return immediateQuery(Record, roc_host, @intCast(SQLITE_MISUSE), "not enough memory to bind this query");
    defer {
        freeBindings(allocator, bindings);
        allocator.free(bindings);
    }

    var result = Result.init(allocator);
    defer result.deinit();
    var job = Job{
        .resource = resource,
        .borrowed_stmt = null,
        .sql = sql,
        .bindings = bindings,
        .script = false,
        .result = &result,
    };
    dispatch(rt, &job);
    return toRocQuery(Record, roc_host, &result);
}

/// `Sqlite.exec_script!`: run every statement in a script.
pub fn execScript(
    roc_host: *RocHost,
    rt: ?*zio.Runtime,
    db_arg: *u64,
    sql_arg: abi.RocStr,
) abi.HostABISqlite_exec_script {
    const Record = abi.HostABISqlite_exec_script;
    const allocator = workerAllocator();

    const resource = db_heap.get(db_arg.*) orelse return .{
        .err = @intCast(SQLITE_MISUSE),
        .message = abi.RocStr.fromSlice("database handle is closed", roc_host),
    };

    const sql = dupeZ(allocator, sql_arg) orelse return .{
        .err = @intCast(SQLITE_MISUSE),
        .message = abi.RocStr.fromSlice("not enough memory to run this script", roc_host),
    };
    defer allocator.free(sql);

    var result = Result.init(allocator);
    defer result.deinit();
    var job = Job{
        .resource = resource,
        .borrowed_stmt = null,
        .sql = sql,
        .bindings = &.{},
        .script = true,
        .result = &result,
    };
    dispatch(rt, &job);
    return toRocStatus(Record, roc_host, &result);
}

/// Open a scratch in-memory database for a test, straight through the heaps.
///
/// Real slots and a real SQLite, not a zeroed stand-in: a heap test built on
/// `std.mem.zeroes` makes every incref and decref a no-op, so it cannot fail
/// when a refcount is wrong, which is the only thing worth testing here.
fn testOpenMemory() !*u64 {
    try std.testing.expect(initialize());
    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(SQLITE_OK, rocray_sqlite_open(":memory:", 0, 1000, &handle));
    return db_heap.insert(0, .{
        .db = handle,
        .mutex = .{},
        .in_flight = false,
        .max_result_bytes = 1024 * 1024,
    }) orelse return error.HeapFull;
}

fn testPrepare(db_token: u64, sql: [*:0]const u8) !*u64 {
    const resource = db_heap.get(db_token).?;
    var compiled: ?*anyopaque = null;
    var tail: c_int = 0;
    try std.testing.expectEqual(SQLITE_OK, rocray_sqlite_prepare(resource.db, sql, &compiled, &tail));
    return stmt_heap.insert(0, .{ .stmt = compiled, .db_token = db_token }) orelse return error.HeapFull;
}

test "a connection and its statement are destroyed in either release order" {
    defer {
        stmt_heap.deinitAll();
        db_heap.deinitAll();
    }

    // Statement released first, then the connection.
    {
        const db = try testOpenMemory();
        const stmt = try testPrepare(db.*, "SELECT 1");
        const stmt_resource = stmt_heap.get(stmt.*).?;
        const db_resource = db_heap.get(db.*).?;

        stmt_heap.deinitAll();
        try std.testing.expect(stmt_resource.stmt == null);
        try std.testing.expect(db_resource.db != null);

        db_heap.deinitAll();
        try std.testing.expect(db_resource.db == null);
    }

    // Connection released first. close_v2 leaves it a zombie until the
    // statement goes, so this must not crash and must still finalize.
    {
        const db = try testOpenMemory();
        const stmt = try testPrepare(db.*, "SELECT 1");
        const stmt_resource = stmt_heap.get(stmt.*).?;
        const db_resource = db_heap.get(db.*).?;

        db_heap.deinitAll();
        try std.testing.expect(db_resource.db == null);

        stmt_heap.deinitAll();
        try std.testing.expect(stmt_resource.stmt == null);
    }
}

test "a statement token does not resolve in the connection heap" {
    defer {
        stmt_heap.deinitAll();
        db_heap.deinitAll();
    }
    const db = try testOpenMemory();
    const stmt = try testPrepare(db.*, "SELECT 1");

    // Kinds 10 and 11 are distinct, so neither token is meaningful in the
    // other's heap even though both are plain u64s.
    try std.testing.expect(db_heap.get(stmt.*) == null);
    try std.testing.expect(stmt_heap.get(db.*) == null);
    try std.testing.expect(db_heap.get(0) == null);
    try std.testing.expect(stmt_heap.get(0) == null);
}

test "a released connection token stops resolving" {
    defer db_heap.deinitAll();
    const db = try testOpenMemory();
    const token = db.*;
    try std.testing.expect(db_heap.get(token) != null);
    db_heap.deinitAll();
    try std.testing.expect(db_heap.get(token) == null);
}

test "the connection heap saturates at its capacity" {
    defer db_heap.deinitAll();
    var opened: usize = 0;
    while (opened < max_connections) : (opened += 1) {
        _ = try testOpenMemory();
    }
    try std.testing.expectEqual(max_connections, db_heap.active());

    try std.testing.expect(initialize());
    var extra: ?*anyopaque = null;
    try std.testing.expectEqual(SQLITE_OK, rocray_sqlite_open(":memory:", 0, 1000, &extra));
    defer _ = rocray_sqlite_close(extra);
    try std.testing.expect(db_heap.insert(0, .{
        .db = extra,
        .mutex = .{},
        .in_flight = false,
        .max_result_bytes = 0,
    }) == null);
}

test "the statement heap saturates at its capacity" {
    defer {
        stmt_heap.deinitAll();
        db_heap.deinitAll();
    }
    const db = try testOpenMemory();
    var prepared: usize = 0;
    while (prepared < max_statements) : (prepared += 1) {
        _ = try testPrepare(db.*, "SELECT 1");
    }
    try std.testing.expectEqual(max_statements, stmt_heap.active());

    const resource = db_heap.get(db.*).?;
    var compiled: ?*anyopaque = null;
    var tail: c_int = 0;
    try std.testing.expectEqual(SQLITE_OK, rocray_sqlite_prepare(resource.db, "SELECT 1", &compiled, &tail));
    defer _ = rocray_sqlite_finalize(compiled);
    try std.testing.expect(stmt_heap.insert(0, .{ .stmt = compiled, .db_token = db.* }) == null);
}

test "a query encodes every column type into cells and one payload" {
    defer db_heap.deinitAll();
    const db = try testOpenMemory();
    const resource = db_heap.get(db.*).?;

    var setup = Result.init(std.testing.allocator);
    defer setup.deinit();
    var setup_job = Job{
        .resource = resource,
        .borrowed_stmt = null,
        .sql = "CREATE TABLE t(i INTEGER, r REAL, s TEXT, b BLOB, n); INSERT INTO t VALUES (7, 1.5, 'hi', x'0102', NULL)",
        .bindings = &.{},
        .script = true,
        .result = &setup,
    };
    runBlocking(&setup_job);
    try std.testing.expectEqual(@as(i64, 0), setup.err);

    var result = Result.init(std.testing.allocator);
    defer result.deinit();
    var job = Job{
        .resource = resource,
        .borrowed_stmt = null,
        .sql = "SELECT i, r, s, b, n FROM t",
        .bindings = &.{},
        .script = false,
        .result = &result,
    };
    runBlocking(&job);

    try std.testing.expectEqual(@as(i64, 0), result.err);
    try std.testing.expectEqual(@as(u64, 1), result.row_count);
    try std.testing.expectEqual(@as(u64, 5), result.ncols);
    try std.testing.expectEqualStrings("i\x00r\x00s\x00b\x00n\x00", result.names.items);
    try std.testing.expectEqual(@as(usize, 5), result.cells.items.len);

    try std.testing.expectEqual(@as(u8, 1), result.cells.items[0].kind);
    try std.testing.expectEqual(@as(i64, 7), result.cells.items[0].integer);
    try std.testing.expectEqual(@as(u8, 2), result.cells.items[1].kind);
    try std.testing.expectEqual(@as(f64, 1.5), result.cells.items[2 - 1].real);
    try std.testing.expectEqual(@as(u8, 3), result.cells.items[2].kind);
    try std.testing.expectEqual(@as(u8, 4), result.cells.items[3].kind);
    try std.testing.expectEqual(@as(u8, 5), result.cells.items[4].kind);

    // Text and blob share one payload buffer, each cell naming its own slice.
    const text = result.payload.items[result.cells.items[2].start..][0..result.cells.items[2].len];
    try std.testing.expectEqualStrings("hi", text);
    const blob = result.payload.items[result.cells.items[3].start..][0..result.cells.items[3].len];
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, blob);
}

test "a payload cap refuses the result rather than truncating it" {
    defer db_heap.deinitAll();
    const db = try testOpenMemory();
    const resource = db_heap.get(db.*).?;
    // Room for the first row's text and not the second's.
    resource.max_result_bytes = 3;

    var result = Result.init(std.testing.allocator);
    defer result.deinit();
    var job = Job{
        .resource = resource,
        .borrowed_stmt = null,
        .sql = "SELECT 'aa' UNION ALL SELECT 'bbbb'",
        .bindings = &.{},
        .script = false,
        .result = &result,
    };
    runBlocking(&job);

    try std.testing.expectEqual(ERR_RESULT_TOO_LARGE, result.err);
    // Nothing partial survives: a result cut short would decode into wrong
    // data rather than into an error.
    try std.testing.expectEqual(@as(u64, 0), result.row_count);
    try std.testing.expectEqual(@as(usize, 0), result.cells.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.payload.items.len);
}

test "a multi-statement query is refused rather than half run" {
    defer db_heap.deinitAll();
    const db = try testOpenMemory();
    const resource = db_heap.get(db.*).?;

    var result = Result.init(std.testing.allocator);
    defer result.deinit();
    var job = Job{
        .resource = resource,
        .borrowed_stmt = null,
        .sql = "SELECT 1; SELECT 2",
        .bindings = &.{},
        .script = false,
        .result = &result,
    };
    runBlocking(&job);
    try std.testing.expectEqual(ERR_MULTIPLE_STATEMENTS, result.err);
}

test "a binding that names no parameter is refused" {
    defer db_heap.deinitAll();
    const db = try testOpenMemory();
    const resource = db_heap.get(db.*).?;

    var result = Result.init(std.testing.allocator);
    defer result.deinit();
    const bindings = [_]BindingBytes{.{
        .name = ":nope",
        .kind = 1,
        .integer = 1,
        .real = 0,
        .bytes = &.{},
    }};
    var job = Job{
        .resource = resource,
        .borrowed_stmt = null,
        .sql = "SELECT :real_one",
        .bindings = &bindings,
        .script = false,
        .result = &result,
    };
    runBlocking(&job);
    // A typo in a parameter name reads as an empty result if it is ignored, so
    // it is an error instead.
    try std.testing.expectEqual(@as(i64, SQLITE_RANGE), result.err);
}

test "a closed connection answers misuse rather than reaching freed memory" {
    defer db_heap.deinitAll();
    const db = try testOpenMemory();
    const resource = db_heap.get(db.*).?;
    _ = rocray_sqlite_close(resource.db);
    resource.db = null;

    var result = Result.init(std.testing.allocator);
    defer result.deinit();
    var job = Job{
        .resource = resource,
        .borrowed_stmt = null,
        .sql = "SELECT 1",
        .bindings = &.{},
        .script = false,
        .result = &result,
    };
    runBlocking(&job);
    try std.testing.expectEqual(@as(i64, SQLITE_MISUSE), result.err);
}

test "interrupting a connection with nothing in flight is harmless" {
    defer db_heap.deinitAll();
    _ = try testOpenMemory();
    interruptAll();
}

test "a prepared statement can be run twice with different bindings" {
    defer {
        stmt_heap.deinitAll();
        db_heap.deinitAll();
    }
    const db = try testOpenMemory();
    const resource = db_heap.get(db.*).?;
    const stmt = try testPrepare(db.*, "SELECT :n + 1 AS answer");
    const stmt_resource = stmt_heap.get(stmt.*).?;

    for ([_]i64{ 1, 41 }) |input| {
        var result = Result.init(std.testing.allocator);
        defer result.deinit();
        const bindings = [_]BindingBytes{.{
            .name = ":n",
            .kind = 1,
            .integer = input,
            .real = 0,
            .bytes = &.{},
        }};
        var job = Job{
            .resource = resource,
            .borrowed_stmt = stmt_resource.stmt,
            .sql = null,
            .bindings = &bindings,
            .script = false,
            .result = &result,
        };
        runBlocking(&job);
        try std.testing.expectEqual(@as(i64, 0), result.err);
        try std.testing.expectEqual(@as(u64, 1), result.row_count);
        try std.testing.expectEqual(input + 1, result.cells.items[0].integer);
    }
}
