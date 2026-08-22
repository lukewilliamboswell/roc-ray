//! Coroutine-backed app tasks (spike; see COROUTINE_DESIGN_PROPOSAL.md).
//!
//! One zio executor, on the frame thread, runs every task. A task is a boxed
//! Roc closure `() => Msg` handed over by the `Task.spawn!` effect; it runs on
//! its own coroutine stack, parks on the host when it waits, and its message is
//! collected by the frame loop in completion order. No Roc value ever runs on
//! another thread.
const std = @import("std");
const zio = @import("zio");
const abi = @import("roc_platform_abi.zig");


/// A finished task's message, wrapped in the erased thunk Roc calls to unwrap
/// it. The host only moves it; only `receive_task_results` ever calls it.
pub const TaskResult = abi.RocErasedCallable;

/// How many tasks may be running at once.
///
/// Past this, `Task.spawn!` queues the closure and starts it when a slot
/// frees. It never refuses: a refusal would need an error type on every
/// spawn, and an app that wanted two hundred files read would have to write
/// the pacing that this queue already is. Each live task owns a coroutine
/// stack, which is what the cap is really bounding.
pub const max_live_tasks: usize = 32;

/// Behaviour the host supplies: the Roc entry points and the phase guard.
pub fn Tasks(comptime Hooks: type) type {
    return struct {
        const Self = @This();

        const Live = struct {
            id: u64,
            started_cycle: u64,
            handle: zio.JoinHandle(void),
        };

        pub const Finished = struct { id: u64, result: TaskResult };

        /// A spawn that arrived while every slot was taken.
        const Queued = struct { id: u64, run: abi.RocErasedCallable };

        allocator: std.mem.Allocator,
        rt: ?*zio.Runtime = null,
        live: std.ArrayListUnmanaged(Live) = .empty,
        /// Closures waiting for a live slot, oldest first.
        queued: std.ArrayListUnmanaged(Queued) = .empty,
        finished: std.ArrayListUnmanaged(Finished) = .empty,
        next_id: u64 = 1,
        cycle: u64 = 0,
        trace: bool = false,
        /// Count of tasks abandoned (cancelled and dropped) at shutdown.
        abandoned: u64 = 0,
        /// Nanoseconds the last pump took, for the per-frame overhead number.
        last_pump_ns: u64 = 0,
        /// Totals over the run, reported at shutdown when tracing.
        pump_count: u64 = 0,
        pump_total_ns: u64 = 0,
        /// Pumps that took no task work at all (the idle cost of the scheme).
        idle_pump_count: u64 = 0,
        idle_pump_total_ns: u64 = 0,

        /// Pointer to the live registry, for the task body and the sleep effect.
        var current: ?*Self = null;

        pub fn init(allocator: std.mem.Allocator, trace: bool) !Self {
            const rt = try zio.Runtime.init(allocator, .{
                .executors = .exact(1),
                .enable_main_executor = true,
            });
            return Self{ .allocator = allocator, .rt = rt, .trace = trace };
        }

        pub fn activate(self: *Self) void {
            current = self;
        }

        /// The runtime a waiting effect performs its IO through, or null when
        /// no app is running (unit tests, or a runtime that would not start).
        pub fn currentRuntime() ?*zio.Runtime {
            const self = current orelse return null;
            return self.rt;
        }

        pub fn liveCount(self: *const Self) usize {
            return self.live.items.len;
        }

        /// Spawns waiting for a slot. Non-zero means the cap is binding.
        pub fn queuedCount(self: *const Self) usize {
            return self.queued.items.len;
        }

        /// Spawn one erased closure on the active registry (`Task.spawn!`).
        /// Without a runtime the closure is released and nothing runs.
        pub fn spawnCurrent(roc_host: *abi.RocHost, run: abi.RocErasedCallable) void {
            const self = current orelse {
                abi.decrefErasedCallable(run, roc_host);
                return;
            };
            self.spawn(roc_host, run);
        }

        fn spawn(self: *Self, roc_host: *abi.RocHost, run: abi.RocErasedCallable) void {
            if (self.rt == null) {
                abi.decrefErasedCallable(run, roc_host);
                return;
            }
            const id = self.next_id;
            self.next_id += 1;
            if (self.trace) std.log.info("[TASK {d}] spawned on cycle {d}", .{ id, self.cycle });

            // Past the cap the closure waits its turn rather than being
            // refused. `drainQueued` starts it as soon as a slot frees.
            if (self.live.items.len >= max_live_tasks) {
                self.queued.append(self.allocator, .{ .id = id, .run = run }) catch {
                    std.log.err("roc-ray: out of memory queueing task {d}; dropping it", .{id});
                    abi.decrefErasedCallable(run, roc_host);
                    return;
                };
                if (self.trace) std.log.info("[TASK {d}] queued behind {d} live task(s)", .{ id, self.live.items.len });
                return;
            }
            self.start(roc_host, id, run);
        }

        /// Put one closure on its own coroutine, with a slot known to be free.
        fn start(self: *Self, roc_host: *abi.RocHost, id: u64, run: abi.RocErasedCallable) void {
            const rt = self.rt orelse {
                abi.decrefErasedCallable(run, roc_host);
                return;
            };
            self.live.ensureUnusedCapacity(self.allocator, 1) catch @panic("roc-ray: out of memory spawning a task");
            const handle = rt.spawn(body, .{ id, run }) catch |err| {
                std.log.err("roc-ray: could not spawn task {d}: {s}", .{ id, @errorName(err) });
                abi.decrefErasedCallable(run, roc_host);
                return;
            };
            self.live.appendAssumeCapacity(.{ .id = id, .started_cycle = self.cycle, .handle = handle });
        }

        /// Start as many queued closures as there are free slots, oldest first.
        ///
        /// FIFO, and that is a guarantee: a queued task runs after every task
        /// queued before it, so the order tasks are spawned in is the order
        /// they are started in.
        fn drainQueued(self: *Self, roc_host: *abi.RocHost) void {
            var started: usize = 0;
            while (started < self.queued.items.len and self.live.items.len < max_live_tasks) : (started += 1) {
                const item = self.queued.items[started];
                if (self.trace) std.log.info("[TASK {d}] dequeued on cycle {d}", .{ item.id, self.cycle });
                self.start(roc_host, item.id, item.run);
            }
            if (started != 0) {
                std.mem.copyForwards(Queued, self.queued.items[0 .. self.queued.items.len - started], self.queued.items[started..]);
                self.queued.shrinkRetainingCapacity(self.queued.items.len - started);
            }
        }

        /// The coroutine body: run the Roc closure to completion on this stack.
        fn body(id: u64, run: abi.RocErasedCallable) void {
            const self = current orelse unreachable;
            if (self.trace) std.log.info("[TASK {d}] started on cycle {d}", .{ id, self.cycle });
            Hooks.enterTaskPhase();
            const result = Hooks.runTask(run);
            Hooks.leaveTaskPhase();
            if (self.trace) std.log.info("[TASK {d}] finished on cycle {d}", .{ id, self.cycle });
            self.finished.append(self.allocator, .{ .id = id, .result = result }) catch {
                std.log.err("roc-ray: out of memory storing task {d}'s result; dropping it", .{id});
                Hooks.dropResult(result);
            };
        }

        /// Called from inside a waiting effect on a task coroutine, around the park.
        pub fn tracePark(id_hint: []const u8, millis: u64) void {
            const self = current orelse return;
            if (self.trace) std.log.info("[TASK] {s} parking {d} ms on cycle {d}", .{ id_hint, millis, self.cycle });
        }

        pub fn traceResume(id_hint: []const u8) void {
            const self = current orelse return;
            if (self.trace) std.log.info("[TASK] {s} resumed on cycle {d}", .{ id_hint, self.cycle });
        }

        /// Give the executor one turn: run every ready task until it parks or
        /// finishes, and poll the event loop so parked tasks can wake.
        pub const PumpMode = union(enum) {
            /// Yield from the frame loop's main task and return as soon as it
            /// is ready again.
            yield,
            /// Block the frame loop for this long, running tasks and the event
            /// loop meanwhile (headless pacing).
            sleep_ns: u64,
        };

        pub fn pump(self: *Self, cycle: u64, mode: PumpMode) void {
            self.cycle = cycle;
            if (self.rt == null) return;
            var stopwatch = zio.Stopwatch.start();
            switch (mode) {
                .yield => zio.yield() catch {},
                .sleep_ns => |ns| zio.sleep(.fromNanoseconds(@intCast(ns))) catch {},
            }
            self.last_pump_ns = @intCast(stopwatch.read().toNanoseconds());
            self.pump_count += 1;
            self.pump_total_ns += self.last_pump_ns;
            if (self.live.items.len == 0 and mode == .yield) {
                self.idle_pump_count += 1;
                self.idle_pump_total_ns += self.last_pump_ns;
            }
            self.reap();
            if (self.queued.items.len != 0) {
                self.drainQueued(Hooks.host());
                // The tasks just started have not run at all yet. Give them
                // their turn now rather than a frame from now.
                zio.yield() catch {};
                self.reap();
            }
        }

        /// Release the join handles of tasks that have finished.
        fn reap(self: *Self) void {
            var index: usize = 0;
            while (index < self.live.items.len) {
                if (self.live.items[index].handle.hasResult()) {
                    var removed = self.live.swapRemove(index);
                    removed.handle.join();
                } else {
                    index += 1;
                }
            }
        }

        /// The finished tasks' results in completion order, for the host to
        /// stage as responses. Ownership moves to the caller; the list is
        /// emptied.
        pub fn takeFinished(self: *Self) []const Finished {
            if (self.trace and self.finished.items.len != 0) {
                std.log.info("[TASK] delivering {d} result(s) as messages on cycle {d}", .{ self.finished.items.len, self.cycle });
            }
            const items = self.finished.items;
            self.finished = .empty;
            return items;
        }

        /// Release a slice returned by `takeFinished` once its items are moved.
        pub fn releaseTaken(self: *Self, taken: []const Finished) void {
            self.allocator.free(taken);
        }

        /// Cancel every live task, run each to completion on the cancelled
        /// path, drop any undelivered results, then tear the runtime down.
        pub fn deinit(self: *Self) void {
            // Queued closures never started, so nothing owns them but this
            // list. Drop them before the runtime goes away.
            for (self.queued.items) |item| Hooks.dropResult(item.run);
            self.queued.clearRetainingCapacity();
            if (self.rt) |rt| {
                for (self.live.items) |*item| {
                    if (self.trace) std.log.info("[TASK {d}] cancelling at shutdown", .{item.id});
                    item.handle.cancel();
                    self.abandoned += 1;
                }
                self.live.clearRetainingCapacity();
                for (self.finished.items) |item| Hooks.dropResult(item.result);
                self.finished.clearRetainingCapacity();
                if (self.abandoned != 0) std.log.warn("roc-ray: {d} task(s) abandoned at shutdown", .{self.abandoned});
                if (self.trace and self.pump_count != 0) {
                    std.log.info("[TASK] {d} pumps, mean {d} ns; {d} idle pumps, mean {d} ns", .{
                        self.pump_count,
                        self.pump_total_ns / self.pump_count,
                        self.idle_pump_count,
                        if (self.idle_pump_count == 0) 0 else self.idle_pump_total_ns / self.idle_pump_count,
                    });
                }
                rt.deinit();
                self.rt = null;
            }
            self.live.deinit(self.allocator);
            self.queued.deinit(self.allocator);
            self.finished.deinit(self.allocator);
            if (current == self) current = null;
        }
    };
}
