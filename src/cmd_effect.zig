//! The `Cmd.run!` effect: one child process, run to its end off the frame thread.
//!
//! `host_native.zig` owns the phase guard, the admission bound and the Roc
//! entry point; this file owns the child and the deadline. Nothing here
//! touches raylib or a Roc value: `run` is handed plain byte slices and hands
//! back plain host allocations, so it is the part that may execute on zio's
//! blocking pool.
//!
//! ## Why the blocking pool
//!
//! Spawning and reaping a child is one of the operations the runtime's own
//! file backend does not implement on every target, so this runs through
//! `std.Io.Threaded` on zio's blocking pool for exactly the reason
//! `writeFileWaiting` does. The pool parks the calling coroutine the way the
//! event loop would, so the frame loop keeps drawing while a child runs.
//!
//! ## Bounds
//!
//! Three, all mandatory. `timeout_ms` bounds how long the host will read the
//! child's output before killing it. `stdout_limit_bytes` and
//! `stderr_limit_bytes` bound each captured stream on its own, clamped to
//! `max_output_bytes`, and exceeding one is a refusal rather than a
//! truncation. `max_live_children` bounds how many children exist at once;
//! that reservation is taken on the frame thread before anything is started,
//! so a `Busy` means precisely that no process was created.
//!
//! ## Shutdown
//!
//! Every live child is registered in `live_children` for as long as it exists.
//! `killLiveChildren` terminates all of them and refuses further
//! registrations, so a task parked in `run!` at shutdown is interrupted
//! through this facility's own mechanism -- the child dies, the pipes reach
//! end of stream, the worker returns -- rather than by the task runtime
//! waiting out a deadline it cannot cancel.

const std = @import("std");
const builtin = @import("builtin");

/// The child ran to its own end. `exit_code` is whatever it exited with,
/// including non-zero: an exit status is data, not a failure.
pub const ERR_OK: u8 = 0;

/// No such executable on `PATH`, or at the path given.
pub const ERR_COMMAND_NOT_FOUND: u8 = 1;

/// The child could not be started, or could not be run to its end, for a
/// reason with no better name. Shares the generic-failure code `Files` uses.
pub const ERR_SPAWN_FAILED: u8 = 2;

/// `max_live_children` children are already running. Nothing was started.
/// Numbered as `Files` numbers its own `Busy`.
pub const ERR_BUSY: u8 = 3;

/// The app is shutting down. Numbered as `Files` numbers its own.
pub const ERR_UNAVAILABLE: u8 = 4;

/// The deadline expired and the host killed the child. The captured bytes
/// still cross; `exit_code` is `-1`.
pub const ERR_TIMED_OUT: u8 = 5;

/// The child wrote more to standard output than the command allowed.
pub const ERR_STDOUT_LIMIT: u8 = 6;

/// The child wrote more to standard error than the command allowed.
pub const ERR_STDERR_LIMIT: u8 = 7;

/// The executable is there and this process may not start it. Shares the
/// permission code `Files` uses for a write.
pub const ERR_PERMISSION_DENIED: u8 = 8;

/// How many children may exist at once.
///
/// Each one costs two pipes, a process table entry and a blocking-pool thread
/// for as long as it runs, and the pool is shared with every other waiting
/// effect. Eight is enough for the pipelines this is for -- a fan-out over a
/// handful of files -- and small enough that a runaway spawn loop cannot take
/// the pool away from reads and writes. Past it `run!` answers `Busy` rather
/// than queueing: unlike a task, a command carries a deadline the app chose,
/// and a queued command would spend it waiting to start.
pub const max_live_children: usize = 8;

/// The host's own ceiling on either captured stream, whatever the command
/// asked for. Four times the file-read ceiling, because a command's output is
/// the whole answer rather than one of many files an app loads.
pub const max_output_bytes: u64 = 64 * 1024 * 1024;

/// Bytes of headroom asked for on each refill. One pipe buffer's worth, so a
/// chatty child is read back in whole buffers rather than in fragments.
const refill_bytes: usize = 64 * 1024;

/// One environment variable, as the child will see it.
pub const EnvPair = struct {
    name: []const u8,
    value: []const u8,
};

/// A command, flattened out of the Roc record by the caller.
///
/// Every slice is host-owned storage the caller copied the Roc values into,
/// and is borrowed for the length of the call. Nothing here points at a Roc
/// allocation, which is what lets this run on a worker thread.
pub const Spec = struct {
    program: []const u8,
    args: []const []const u8,
    envs: []const EnvPair,
    clear_envs: bool,
    /// Empty means the child inherits this process's working directory.
    working_dir: []const u8,
    timeout_ms: u64,
    stdout_limit_bytes: u64,
    stderr_limit_bytes: u64,
};

/// What a finished (or refused) run produced. The two slices are owned by the
/// caller and freed with `deinit`.
pub const Outcome = struct {
    err: u8,
    exit_code: i64,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: Outcome, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn failure(code: u8) Outcome {
    return .{ .err = code, .exit_code = 0, .stdout = &.{}, .stderr = &.{} };
}

/// Children that exist right now, so shutdown can end them.
///
/// A fixed array rather than a list: `max_live_children` is the bound, and a
/// registry that allocated could fail exactly when a child is already running
/// and has nowhere to be recorded. `stopping` closes the race between a worker
/// spawning a child and the frame thread tearing the app down -- a
/// registration refused after shutdown began kills its own child instead.
const LiveChildren = struct {
    const Slot = struct { used: bool = false, id: std.process.Child.Id = undefined };

    /// A spin lock rather than `std.Io.Mutex`, for the reason `sqlite_effect`'s
    /// `ConnectionLock` is one: locking an `Io` mutex needs an `Io`, and one of
    /// the two threads here is a blocking-pool worker outside any coroutine.
    /// Every critical section is a scan of eight slots with no syscall in it,
    /// so nothing waits long enough for the spin to matter.
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

    mutex: Lock = .{},
    slots: [max_live_children]Slot = @splat(.{}),
    stopping: bool = false,

    /// Record a running child, or refuse because shutdown has begun.
    fn register(self: *LiveChildren, id: std.process.Child.Id) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping) return null;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.used) continue;
            slot.* = .{ .used = true, .id = id };
            return index;
        }
        return null;
    }

    /// Forget a child that has been reaped.
    ///
    /// Called immediately after the wait that reaped it, so the window in
    /// which `killLiveChildren` could signal an identifier the operating
    /// system has already handed back is the few instructions in between. On
    /// Windows there is no window at all: the identifier is a handle this
    /// process holds open, not a number that can be reused.
    fn release(self: *LiveChildren, index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.slots[index] = .{};
    }

    fn liveCount(self: *LiveChildren) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.slots) |slot| {
            if (slot.used) count += 1;
        }
        return count;
    }
};

var live_children: LiveChildren = .{};

/// Slots promised to runs that have been admitted but have not started a child
/// yet, plus the children already running.
///
/// Only the frame thread reserves and releases, so this is deliberately just a
/// count with nothing to synchronize -- the same shape, and for the same
/// reason, as the byte-list delivery reservations in `host_native.zig`.
var admitted: usize = 0;
var admitted_high_water: usize = 0;
var oldest_admitted_at: u64 = 0;

/// Scalar-only observation of the bounded child-process admission queue.
pub const QueueObservation = struct {
    operation: enum(u8) { reserve, release, saturation },
    current: usize,
    high_water: usize,
    capacity: usize,
    oldest_at: u64,
};

/// Optional host observer. It returns the current recorder timestamp, retained
/// when the queue changes from empty to non-empty for oldest-item age.
pub const QueueObserver = *const fn (QueueObservation) u64;
var queue_observer: ?QueueObserver = null;

/// Install or remove queue-pressure observation for the active host run.
pub fn setQueueObserver(next: ?QueueObserver) void {
    queue_observer = next;
}

fn observeQueue(event: QueueObservation) u64 {
    return if (queue_observer) |callback| callback(event) else 0;
}

/// Take a child slot, or report that every one is taken.
pub fn reserve() bool {
    std.debug.assert(admitted <= max_live_children);
    if (admitted == max_live_children) {
        _ = observeQueue(.{
            .operation = .saturation,
            .current = admitted,
            .high_water = admitted_high_water,
            .capacity = max_live_children,
            .oldest_at = oldest_admitted_at,
        });
        return false;
    }
    admitted += 1;
    admitted_high_water = @max(admitted_high_water, admitted);
    const now = observeQueue(.{
        .operation = .reserve,
        .current = admitted,
        .high_water = admitted_high_water,
        .capacity = max_live_children,
        .oldest_at = oldest_admitted_at,
    });
    if (admitted == 1) oldest_admitted_at = now;
    return true;
}

/// Give a child slot back, once the child it stood for has been reaped.
pub fn release() void {
    std.debug.assert(admitted != 0);
    admitted -= 1;
    _ = observeQueue(.{
        .operation = .release,
        .current = admitted,
        .high_water = admitted_high_water,
        .capacity = max_live_children,
        .oldest_at = oldest_admitted_at,
    });
    if (admitted == 0) oldest_admitted_at = 0;
}

/// Slots taken right now. Shutdown asserts this is zero.
pub fn admittedCount() usize {
    return admitted;
}

/// End every child this host started, and refuse to start more.
///
/// Shutdown calls this before the task runtime is torn down. A worker parked
/// in a child's output sees the pipes close and returns, so the runtime's own
/// teardown does not have to wait out a deadline the app chose.
pub fn killLiveChildren() void {
    live_children.mutex.lock();
    defer live_children.mutex.unlock();
    live_children.stopping = true;
    for (live_children.slots) |slot| {
        if (slot.used) terminate(slot.id);
    }
}

/// Forget every promise and re-open the registry for the next app lifetime.
///
/// Every task that could have been running a child has been cancelled by the
/// time this is called, so the counts they would have released are gone with
/// them.
pub fn clearAfterWorkStops() void {
    admitted = 0;
    admitted_high_water = 0;
    oldest_admitted_at = 0;
    live_children.mutex.lock();
    defer live_children.mutex.unlock();
    live_children.stopping = false;
    live_children.slots = @splat(.{});
}

/// Kill one child, from any thread.
///
/// Deliberately not `Child.kill`: that one closes the child's pipes and clears
/// its identifier, which only the thread that owns the `Child` may do. This
/// signals and returns, leaving the owning worker to notice the streams end
/// and reap it as it would have anyway.
///
/// On POSIX the signal goes to the child's process group rather than to the
/// child alone, because the child is the leader of a group of its own (see
/// `pgid` at the spawn). A shell told to run a program starts it as a further
/// child, and signalling only the shell would leave that one running with the
/// host's pipe still open -- the deadline would expire and the work would
/// carry on. Windows has no equivalent that `std.process` exposes, so there
/// only the process the host started is terminated.
fn terminate(id: std.process.Child.Id) void {
    if (comptime builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1));
    } else {
        std.posix.kill(-id, .KILL) catch {};
    }
}

/// Run one command to completion on the calling thread.
///
/// `environ` is this process's own environment: it supplies `PATH` for
/// resolving a bare program name, and it is what the child inherits unless the
/// command replaces it.
pub fn run(gpa: std.mem.Allocator, environ: std.process.Environ, spec: Spec) Outcome {
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = environ });
    defer threaded.deinit();
    return runIn(gpa, threaded.io(), environ, spec);
}

/// `run` against an explicit `Io`. `run` differs only in standing up the
/// threaded implementation the child is spawned and read through.
fn runIn(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, spec: Spec) Outcome {
    const argv = gpa.alloc([]const u8, spec.args.len + 1) catch return failure(ERR_SPAWN_FAILED);
    defer gpa.free(argv);
    argv[0] = spec.program;
    for (spec.args, argv[1..]) |arg, *slot| slot.* = arg;

    var env_code: u8 = ERR_OK;
    var env_map = buildEnvMap(gpa, environ, spec, &env_code);
    defer if (env_map) |*map| map.deinit();
    if (env_code != ERR_OK) return failure(env_code);

    // A working directory that is not there would otherwise come back from the
    // spawn as `FileNotFound`, which is the code for a missing *program*.
    // Checking it first keeps one code from meaning two things.
    if (spec.working_dir.len != 0) {
        const stat = std.Io.Dir.cwd().statFile(io, spec.working_dir, .{ .follow_symlinks = true }) catch
            return failure(ERR_SPAWN_FAILED);
        if (stat.kind != .directory) return failure(ERR_SPAWN_FAILED);
    }

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (spec.working_dir.len == 0)
            .inherit
        else
            .{ .path = spec.working_dir },
        .environ_map = if (env_map) |*map| map else null,
        // Ignored rather than inherited: a child that read the app's standard
        // input would be competing with the app for the terminal, and a
        // graphics app has no use for that. It reads end of stream instead.
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // Its own process group, so `terminate` can end everything the command
        // started rather than only its first process. It also keeps a terminal
        // interrupt aimed at the application from reaching a child that the
        // application, not the user, asked for.
        .pgid = if (builtin.os.tag == .windows) null else 0,
    }) catch |err| return failure(spawnErrorCode(err));

    const registration = live_children.register(child.id.?) orelse {
        // Shutdown began between the reservation and the spawn. End the child
        // now rather than leaving one behind that nothing will ever kill.
        child.kill(io);
        return failure(ERR_UNAVAILABLE);
    };

    const id = child.id.?;
    var reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(gpa, io, reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });

    const outcome = collect(gpa, io, &reader, &child, id, spec);
    // In this order on purpose. A run that ended early leaves reads
    // outstanding on the child's pipes, and cancelling them needs the handles
    // those reads name to still be open -- closing them first leaves a
    // Windows cancellation waiting for a completion that can no longer
    // arrive. `kill` is idempotent and a no-op once `collect` has reaped the
    // child itself, so it is also what ends one whose output could not be
    // read at all.
    reader.deinit();
    child.kill(io);
    live_children.release(registration);
    return outcome;
}

/// Read both streams to their end, then reap the child.
fn collect(
    gpa: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.File.MultiReader,
    child: *std.process.Child,
    id: std.process.Child.Id,
    spec: Spec,
) Outcome {
    const stdout_limit = @min(spec.stdout_limit_bytes, max_output_bytes);
    const stderr_limit = @min(spec.stderr_limit_bytes, max_output_bytes);

    // An absolute instant, computed once. A duration handed to every refill
    // would restart the deadline on each one, so a child that dribbled a byte
    // out forever would never reach it.
    const deadline = millisFromNow(io, @intCast(@min(spec.timeout_ms, std.math.maxInt(i64))));

    var stopped: u8 = ERR_OK;
    while (reader.fill(refill_bytes, deadline)) |_| {
        if (reader.reader(0).buffered().len > stdout_limit) {
            stopped = ERR_STDOUT_LIMIT;
            break;
        }
        if (reader.reader(1).buffered().len > stderr_limit) {
            stopped = ERR_STDERR_LIMIT;
            break;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => stopped = ERR_TIMED_OUT,
        error.Canceled => stopped = ERR_UNAVAILABLE,
        else => stopped = ERR_SPAWN_FAILED,
    }

    // Every path that did not read both streams to their end kills the child
    // and leaves the reaping to `runIn`, which cancels the outstanding reads
    // first. Nothing below closes a pipe the reader still names.
    if (stopped == ERR_TIMED_OUT) {
        terminate(id);
        // Copied rather than taken. A read may still be outstanding on the
        // tail of each buffer -- the pipes reach end of stream only once
        // everything holding their write ends has gone -- and only the part
        // already filled is the host's to keep.
        const out = gpa.dupe(u8, reader.reader(0).buffered()) catch return failure(ERR_TIMED_OUT);
        const errors = gpa.dupe(u8, reader.reader(1).buffered()) catch {
            gpa.free(out);
            return failure(ERR_TIMED_OUT);
        };
        return .{ .err = ERR_TIMED_OUT, .exit_code = -1, .stdout = out, .stderr = errors };
    }

    // Over a limit, nothing is handed back: half a stream decodes into wrong
    // data rather than into an error, so the run is refused outright.
    if (stopped != ERR_OK) {
        terminate(id);
        return failure(stopped);
    }

    reader.checkAnyError() catch |err| {
        terminate(id);
        return failure(switch (err) {
            error.Canceled => ERR_UNAVAILABLE,
            else => ERR_SPAWN_FAILED,
        });
    };

    // Both streams ended, so no read is outstanding and reaping here -- which
    // closes the child's pipes -- cannot strand one.
    const term = child.wait(io) catch |err| return failure(switch (err) {
        error.Canceled => ERR_UNAVAILABLE,
        else => ERR_SPAWN_FAILED,
    });

    var taken = takeStreams(gpa, reader) orelse return failure(ERR_SPAWN_FAILED);
    taken.err = ERR_OK;
    taken.exit_code = exitCode(term);
    return taken;
}

/// An absolute deadline this many milliseconds from now, on the monotonic
/// clock, so a system clock the user or NTP moves cannot lengthen or shorten a
/// command's timeout.
fn millisFromNow(io: std.Io, millis: i64) std.Io.Timeout {
    return .{ .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(millis), .clock = .awake }) };
}

/// Move both buffered streams out of the reader as owned allocations.
fn takeStreams(gpa: std.mem.Allocator, reader: *std.Io.File.MultiReader) ?Outcome {
    const out = reader.toOwnedSlice(0) catch return null;
    const err_stream = reader.toOwnedSlice(1) catch {
        gpa.free(out);
        return null;
    };
    return .{ .err = ERR_OK, .exit_code = 0, .stdout = out, .stderr = err_stream };
}

/// The environment the child gets, or null when it inherits this process's.
fn buildEnvMap(
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    spec: Spec,
    out_err: *u8,
) ?std.process.Environ.Map {
    if (!spec.clear_envs and spec.envs.len == 0) return null;

    var map = if (spec.clear_envs)
        std.process.Environ.Map.init(gpa)
    else
        environ.createMap(gpa) catch {
            out_err.* = ERR_SPAWN_FAILED;
            return null;
        };

    for (spec.envs) |pair| {
        // `Map.put` asserts a representable name, and the name came from the
        // app. Refuse the run instead of tripping the assertion.
        if (!validEnvName(pair.name) or std.mem.indexOfScalar(u8, pair.value, 0) != null) {
            map.deinit();
            out_err.* = ERR_SPAWN_FAILED;
            return null;
        }
        map.put(pair.name, pair.value) catch {
            map.deinit();
            out_err.* = ERR_SPAWN_FAILED;
            return null;
        };
    }
    return map;
}

/// Whether an operating system can hold a variable under this name.
///
/// The block is `NAME=VALUE` entries terminated by NUL on every target this
/// platform builds for, so a name that is empty, holds a NUL, or holds the
/// separator has no representation at all.
pub fn validEnvName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, name, '=') != null) return false;
    if (comptime builtin.os.tag == .windows) {
        if (!std.unicode.wtf8ValidateSlice(name)) return false;
    }
    return true;
}

/// Name a failed spawn in the app's vocabulary.
pub fn spawnErrorCode(err: anyerror) u8 {
    return switch (err) {
        error.FileNotFound, error.BadPathName, error.NameTooLong, error.InvalidName => ERR_COMMAND_NOT_FOUND,
        error.AccessDenied, error.PermissionDenied => ERR_PERMISSION_DENIED,
        error.Canceled => ERR_UNAVAILABLE,
        else => ERR_SPAWN_FAILED,
    };
}

/// Flatten a terminated child's status into one number.
///
/// A signalled child reports the negated signal number, so a segmentation
/// fault is `-11` and cannot be read as the exit code `11` a program chose.
/// The deadline's own kill never reaches here; it reports `-1`.
pub fn exitCode(term: std.process.Child.Term) i64 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => |sig| -@as(i64, @intCast(@intFromEnum(sig))),
        .stopped => |sig| -@as(i64, @intCast(@intFromEnum(sig))),
        .unknown => |status| @intCast(status),
    };
}

test "an environment name has to be representable" {
    try std.testing.expect(validEnvName("PATH"));
    try std.testing.expect(!validEnvName(""));
    try std.testing.expect(!validEnvName("A=B"));
    try std.testing.expect(!validEnvName("A\x00B"));
}

test "a spawn failure is named in the app's vocabulary" {
    try std.testing.expectEqual(ERR_COMMAND_NOT_FOUND, spawnErrorCode(error.FileNotFound));
    try std.testing.expectEqual(ERR_PERMISSION_DENIED, spawnErrorCode(error.AccessDenied));
    try std.testing.expectEqual(ERR_PERMISSION_DENIED, spawnErrorCode(error.PermissionDenied));
    try std.testing.expectEqual(ERR_UNAVAILABLE, spawnErrorCode(error.Canceled));
    try std.testing.expectEqual(ERR_SPAWN_FAILED, spawnErrorCode(error.InvalidExe));
}

test "a signalled child is not confused with one that chose an exit code" {
    try std.testing.expectEqual(@as(i64, 0), exitCode(.{ .exited = 0 }));
    try std.testing.expectEqual(@as(i64, 7), exitCode(.{ .exited = 7 }));
    try std.testing.expect(exitCode(.{ .signal = @enumFromInt(9) }) < 0);
}

test "the child bound admits exactly its own number of runs" {
    clearAfterWorkStops();
    defer clearAfterWorkStops();

    var taken: usize = 0;
    while (reserve()) : (taken += 1) {}
    try std.testing.expectEqual(max_live_children, taken);
    try std.testing.expect(!reserve());

    release();
    try std.testing.expect(reserve());
}

test "queue observer reports reserve saturation release and oldest stamp" {
    const Probe = struct {
        var events: [max_live_children + 2]QueueObservation = undefined;
        var count: usize = 0;
        fn callback(event: QueueObservation) u64 {
            events[count] = event;
            count += 1;
            return 77;
        }
    };
    clearAfterWorkStops();
    defer clearAfterWorkStops();
    Probe.count = 0;
    setQueueObserver(Probe.callback);
    defer setQueueObserver(null);

    for (0..max_live_children) |_| try std.testing.expect(reserve());
    try std.testing.expect(!reserve());
    release();

    try std.testing.expectEqual(.reserve, Probe.events[0].operation);
    try std.testing.expectEqual(max_live_children, Probe.events[max_live_children - 1].high_water);
    try std.testing.expectEqual(.saturation, Probe.events[max_live_children].operation);
    try std.testing.expectEqual(@as(u64, 77), Probe.events[max_live_children].oldest_at);
    try std.testing.expectEqual(.release, Probe.events[max_live_children + 1].operation);
    try std.testing.expectEqual(max_live_children - 1, Probe.events[max_live_children + 1].current);
}

// Shutdown must not leave a registration behind that would make the next app
// lifetime start a child into an occupied slot.
test "shutdown closes the registry and reopens it for the next lifetime" {
    clearAfterWorkStops();
    defer clearAfterWorkStops();

    const fake: std.process.Child.Id = if (builtin.os.tag == .windows)
        @ptrFromInt(@alignOf(usize))
    else
        std.math.maxInt(std.posix.pid_t);
    const slot = live_children.register(fake);
    try std.testing.expect(slot != null);
    try std.testing.expectEqual(@as(usize, 1), live_children.liveCount());

    // Nothing is signalled here: the identifier is a stand-in, and
    // `killLiveChildren` is what a real teardown calls. Closing the registry
    // by hand is the part under test.
    live_children.mutex.lock();
    live_children.stopping = true;
    live_children.mutex.unlock();
    try std.testing.expect(live_children.register(fake) == null);

    clearAfterWorkStops();
    try std.testing.expectEqual(@as(usize, 0), live_children.liveCount());
    try std.testing.expect(live_children.register(fake) != null);
}

/// The environment a test's children run under.
///
/// The test binary links libc and never runs `platform_main`, so nothing
/// captured `envp` off the process stack; the C runtime's own global is the
/// only place `PATH` is to be found here.
fn testEnviron() std.process.Environ {
    if (comptime builtin.os.tag == .windows) return .{ .block = .global };
    var count: usize = 0;
    while (std.c.environ[count] != null) : (count += 1) {}
    const entries: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    return .{ .block = .{ .slice = entries[0..count :null] } };
}

/// A command that runs one shell line, for the tests below.
///
/// POSIX only. `zig build test` runs on the native target, and CI runs it on
/// Linux and macOS; the Windows job builds the host and exercises the whole
/// path through `test/cmd` instead, where an app picks `cmd.exe` for itself.
fn shellSpec(script: []const []const u8) Spec {
    return .{
        .program = "/bin/sh",
        .args = script,
        .envs = &.{},
        .clear_envs = false,
        .working_dir = "",
        .timeout_ms = 10_000,
        .stdout_limit_bytes = max_output_bytes,
        .stderr_limit_bytes = max_output_bytes,
    };
}

test "a program that is not there is named rather than reported as a failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var spec = shellSpec(&.{});
    spec.program = "roc-ray-definitely-not-a-program";
    const outcome = run(std.testing.allocator, testEnviron(), spec);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqual(ERR_COMMAND_NOT_FOUND, outcome.err);
}

test "both streams come back separately, and a non-zero exit is not an error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const outcome = run(
        std.testing.allocator,
        testEnviron(),
        shellSpec(&.{ "-c", "printf out; printf err 1>&2; exit 3" }),
    );
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(ERR_OK, outcome.err);
    try std.testing.expectEqual(@as(i64, 3), outcome.exit_code);
    try std.testing.expectEqualStrings("out", outcome.stdout);
    try std.testing.expectEqualStrings("err", outcome.stderr);
}

test "a directory that is not there is not reported as a missing program" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var spec = shellSpec(&.{ "-c", "exit 0" });
    spec.working_dir = "roc-ray-definitely-not-a-directory";
    const outcome = run(std.testing.allocator, testEnviron(), spec);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqual(ERR_SPAWN_FAILED, outcome.err);
}

test "the working directory moves the child and not this process" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var spec = shellSpec(&.{ "-c", "pwd" });
    spec.working_dir = "/";
    const moved = run(std.testing.allocator, testEnviron(), spec);
    defer moved.deinit(std.testing.allocator);
    try std.testing.expectEqual(ERR_OK, moved.err);
    try std.testing.expectEqualStrings("/\n", moved.stdout);

    // The next command asks for nothing, so it reports this process's own
    // directory. The suite runs from the repository root, so a first command
    // that had changed the directory process-wide would show up here.
    const inherited = run(std.testing.allocator, testEnviron(), shellSpec(&.{ "-c", "pwd" }));
    defer inherited.deinit(std.testing.allocator);
    try std.testing.expectEqual(ERR_OK, inherited.err);
    try std.testing.expect(!std.mem.eql(u8, moved.stdout, inherited.stdout));
}

test "a cleared environment gives the child only what the command named" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var spec = shellSpec(&.{ "-c", "printf %s \"$ROC_RAY_PROBE\"" });
    spec.clear_envs = true;
    spec.envs = &.{.{ .name = "ROC_RAY_PROBE", .value = "set" }};
    const outcome = run(std.testing.allocator, testEnviron(), spec);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqual(ERR_OK, outcome.err);
    try std.testing.expectEqualStrings("set", outcome.stdout);
}

test "an environment name no operating system can hold refuses the run" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var spec = shellSpec(&.{ "-c", "exit 0" });
    spec.envs = &.{.{ .name = "BAD=NAME", .value = "x" }};
    const outcome = run(std.testing.allocator, testEnviron(), spec);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqual(ERR_SPAWN_FAILED, outcome.err);
}

test "more output than the command allowed is refused rather than truncated" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var spec = shellSpec(&.{ "-c", "printf 0123456789" });
    spec.stdout_limit_bytes = 4;
    const over = run(std.testing.allocator, testEnviron(), spec);
    defer over.deinit(std.testing.allocator);
    try std.testing.expectEqual(ERR_STDOUT_LIMIT, over.err);
    try std.testing.expectEqual(@as(usize, 0), over.stdout.len);

    spec.stdout_limit_bytes = 10;
    const fits = run(std.testing.allocator, testEnviron(), spec);
    defer fits.deinit(std.testing.allocator);
    try std.testing.expectEqual(ERR_OK, fits.err);
    try std.testing.expectEqualStrings("0123456789", fits.stdout);
}

test "each stream is bounded on its own" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var spec = shellSpec(&.{ "-c", "printf 0123456789 1>&2" });
    spec.stderr_limit_bytes = 4;
    const outcome = run(std.testing.allocator, testEnviron(), spec);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqual(ERR_STDERR_LIMIT, outcome.err);
}

// The deadline has to end the child rather than merely stop reading it: a
// timeout that left the process running would leak one process per expired
// command, and the app would never know.
test "the deadline kills the child and keeps what it had already written" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var spec = shellSpec(&.{ "-c", "printf started; sleep 30" });
    spec.timeout_ms = 300;

    const started = std.Io.Clock.awake.now(std.testing.io);
    const outcome = run(std.testing.allocator, testEnviron(), spec);
    defer outcome.deinit(std.testing.allocator);
    const elapsed_ms = started.untilNow(std.testing.io, .awake).toMilliseconds();

    try std.testing.expectEqual(ERR_TIMED_OUT, outcome.err);
    try std.testing.expectEqual(@as(i64, -1), outcome.exit_code);
    try std.testing.expectEqualStrings("started", outcome.stdout);
    // The child was told to sleep for thirty seconds. Returning in anything
    // like the deadline is the evidence that it was killed, not waited for.
    try std.testing.expect(elapsed_ms < 10_000);
}

// Every run must give its registration back, whatever it ended as. One that
// leaked would make the ninth command after it fail forever.
test "a finished run leaves no registration behind" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    clearAfterWorkStops();
    defer clearAfterWorkStops();

    for (0..max_live_children + 2) |_| {
        const outcome = run(std.testing.allocator, testEnviron(), shellSpec(&.{ "-c", "exit 0" }));
        defer outcome.deinit(std.testing.allocator);
        try std.testing.expectEqual(ERR_OK, outcome.err);
        try std.testing.expectEqual(@as(usize, 0), live_children.liveCount());
    }
}
